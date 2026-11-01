-- | The Sendspin messages nixtune's server sends and reads, as the spec
-- (README, "Core messages", and roles/player/v1.md) defines them. Only
-- the fields the spec defines are sent; unknown fields in what a client
-- sends are ignored, as the spec requires.
module Nixtune.Sendspin.Message
  ( -- * Cleartext, before Noise
    ClientInit (..)
  , InitFailure (..)
  , parseClientInit
  , renderServerInit
  , renderServerError
  , renderNoiseHandshake
  , parseNoiseHandshake
  , renderMessage1Payload
  , isEmptyObject

    -- * Encrypted JSON, message type 0
  , PcmFormat (..)
  , SupportedFormat (..)
  , ClientHello (..)
  , PlayerState (..)
  , ClientMessage (..)
  , parseClientMessage
  , serverHello
  , serverActivate
  , groupUpdate
  , serverTime
  , setOutputDelay
  , streamStartPcm
  , streamClear
  , streamEnd

    -- * Binary framing
  , jsonFrame
  , audioFrame
  , sendAheadField
  , Fragments
  , noFragments
  , Incoming (..)
  , reassemble
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Bits (shiftR)
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Word (Word32, Word8)

envelope :: Text -> [(Key, Value)] -> Value
envelope t fields = object ["type" .= t, "payload" .= object fields]

encodeStrict :: Value -> ByteString
encodeStrict = Lazy.toStrict . encode

-- | The type and payload of a JSON message, or Nothing when it is not a
-- JSON object with a type string and a payload object.
envelopeOf :: ByteString -> Maybe (Text, Object)
envelopeOf raw = do
  v <- decodeStrict raw
  parseMaybe (withObject "message" (\o -> (,) <$> o .: "type" <*> o .: "payload")) v

data ClientInit = ClientInit
  { clientId :: Text
  , clientSuite :: Text
  }
  deriving stock (Eq, Show)

data InitFailure = UnsupportedVersion | UnsupportedSuite | Malformed
  deriving stock (Eq, Show)

-- | client/init, checked as Failure Handling orders it: version first,
-- then suite, then the remaining fields. Whether the suite is one the
-- server implements is the caller's check.
parseClientInit :: ByteString -> Either InitFailure ClientInit
parseClientInit raw = case envelopeOf raw of
  Just ("client/init", p) -> case parseMaybe (.: "version") p :: Maybe Value of
    Just (Number 1) -> case parseMaybe (\o -> ClientInit <$> o .: "client_id" <*> o .: "suite") p of
      Just ci -> Right ci
      Nothing -> Left Malformed
    Just (Number n) | n == fromInteger (round n) -> Left UnsupportedVersion
    _ -> Left Malformed
  _ -> Left Malformed

renderServerInit :: Text -> ByteString
renderServerInit serverId = encodeStrict (envelope "server/init" ["server_id" .= serverId, "version" .= (1 :: Int)])

renderServerError :: InitFailure -> ByteString
renderServerError f =
  encodeStrict . envelope "server/error" . pure . ("reason" .=) $ case f of
    UnsupportedVersion -> "unsupported_version" :: Text
    UnsupportedSuite -> "unsupported_suite"
    Malformed -> "malformed"

renderNoiseHandshake :: ByteString -> ByteString
renderNoiseHandshake msg = encodeStrict (envelope "noise/handshake" ["data" .= decodeUtf8 (convertToBase Base64URLUnpadded msg)])

parseNoiseHandshake :: ByteString -> Maybe ByteString
parseNoiseHandshake raw = do
  ("noise/handshake", p) <- envelopeOf raw
  d <- parseMaybe (.: "data") p :: Maybe Text
  either (const Nothing) Just (convertFromBase Base64URLUnpadded (encodeUtf8 d))

-- | Noise message 1's payload: a long-term PSK, by its psk_id.
renderMessage1Payload :: Text -> ByteString
renderMessage1Payload pid = encodeStrict (object ["psk_id" .= pid, "psk_category" .= ("lt" :: Text)])

-- | Noise message 2's payload must be the empty JSON object.
isEmptyObject :: ByteString -> Bool
isEmptyObject raw = case decodeStrict raw :: Maybe Value of
  Just (Object o) -> null o
  _ -> False

data PcmFormat = PcmFormat
  { pcmRate :: Int
  , pcmBits :: Int
  , pcmChannels :: Int
  }
  deriving stock (Eq, Ord, Show)

data SupportedFormat = SupportedFormat
  { sfCodec :: Text
  , sfFormat :: PcmFormat
  }
  deriving stock (Eq, Show)

data ClientHello = ClientHello
  { helloName :: Text
  , helloRoles :: [Text]
  , helloFormats :: [SupportedFormat]
  , helloBufferCapacity :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | The player object of client/state, the fields the server uses.
data PlayerState = PlayerState
  { outputDelayMs :: Int64
  , minBufferMs :: Int64
  , requiredLeadTimeMs :: Int64
  , supportedCommands :: [Text]
  }
  deriving stock (Eq, Show)

data ClientMessage
  = MsgHello ClientHello
  | MsgTime Int64
  | MsgState Bool (Maybe PlayerState)
  | MsgGoodbye Text
  | -- | A recognised envelope the server does not act on, or one it does
    -- not recognise; both are ignored.
    MsgIgnored Text
  deriving stock (Eq, Show)

parseFormat :: Value -> Parser SupportedFormat
parseFormat = withObject "format" $ \o ->
  SupportedFormat
    <$> o .: "codec"
    <*> (PcmFormat <$> o .: "sample_rate" <*> o .: "bit_depth" <*> o .: "channels")

parseHello :: Object -> Parser ClientHello
parseHello o = do
  name <- o .: "name"
  roles <- o .: "supported_roles"
  support <- o .:? "player@v1_support"
  (formats, capacity) <- case support of
    Nothing -> pure ([], Nothing)
    Just s -> withObject "player@v1_support" (\p -> (,) <$> (mapM parseFormat =<< p .: "supported_formats") <*> (Just <$> p .: "buffer_capacity")) s
  pure (ClientHello name roles formats capacity)

parsePlayerState :: Value -> Parser PlayerState
parsePlayerState = withObject "player" $ \o ->
  PlayerState
    <$> o .: "output_delay_ms"
    <*> o .: "min_buffer_ms"
    <*> o .: "required_lead_time_ms"
    <*> o .: "supported_commands"

-- | A decrypted message of type 0. Nothing when the body is not a JSON
-- object with a type string and a payload object, which is a protocol
-- error; a recognised type with a payload the server cannot read is too.
parseClientMessage :: ByteString -> Maybe ClientMessage
parseClientMessage raw = do
  (t, p) <- envelopeOf raw
  case t of
    "client/hello" -> MsgHello <$> parseMaybe parseHello p
    "client/time" -> MsgTime <$> parseMaybe (.: "client_transmitted") p
    "client/state" ->
      parseMaybe (\o -> MsgState <$> o .: "available" <*> (traverse parsePlayerState =<< o .:? "player")) p
    "client/goodbye" -> Just (MsgGoodbye (fromMaybe "" (parseMaybe (.: "reason") p)))
    _ -> Just (MsgIgnored t)

serverHello :: Text -> Value
serverHello name = envelope "server/hello" ["name" .= name]

serverActivate :: Value
serverActivate =
  envelope "server/activate" ["activities" .= ["playback" :: Text], "active_roles" .= ["player@v1" :: Text]]

groupUpdate :: Bool -> Text -> Value
groupUpdate playing name =
  envelope
    "group/update"
    [ "playback_state" .= (if playing then "playing" else "stopped" :: Text)
    , "group_id" .= name
    , "group_name" .= name
    ]

serverTime :: Int64 -> Int64 -> Int64 -> Value
serverTime clientTx received transmitted =
  envelope
    "server/time"
    ["client_transmitted" .= clientTx, "server_received" .= received, "server_transmitted" .= transmitted]

setOutputDelay :: Int64 -> Value
setOutputDelay ms =
  envelope "server/command" ["player" .= object ["command" .= ("set_output_delay" :: Text), "output_delay_ms" .= ms]]

streamStartPcm :: PcmFormat -> Int64 -> Value
streamStartPcm f transmitted =
  envelope
    "stream/start"
    [ "server_transmitted" .= transmitted
    , "player"
        .= object
          [ "codec" .= ("pcm" :: Text)
          , "sample_rate" .= pcmRate f
          , "channels" .= pcmChannels f
          , "bit_depth" .= pcmBits f
          ]
    ]

streamClear :: Int64 -> Value
streamClear transmitted = envelope "stream/clear" ["server_transmitted" .= transmitted, "roles" .= ["player" :: Text]]

streamEnd :: Value
streamEnd = envelope "stream/end" ["roles" .= ["player" :: Text]]

-- | A JSON message as the plaintext of a binary message.
jsonFrame :: Value -> ByteString
jsonFrame v = ByteString.cons 0 (encodeStrict v)

be :: Int -> Integer -> [Word8]
be n x = [fromIntegral (x `shiftR` (8 * i)) | i <- [n - 1, n - 2 .. 0]]

-- | An audio chunk: type 4, the timestamp, the send-ahead, the samples.
audioFrame :: Int64 -> Word32 -> ByteString -> ByteString
audioFrame ts ahead samples =
  ByteString.pack (4 : be 8 (fromIntegral ts) <> be 4 (fromIntegral ahead)) <> samples

-- | send_ahead saturates: 0 when the chunk is sent at or after its
-- timestamp, the largest uint32 when the lead does not fit.
sendAheadField :: Int64 -> Int64 -> Word32
sendAheadField ts transmitted
  | lead <= 0 = 0
  | lead >= fromIntegral (maxBound :: Word32) = maxBound
  | otherwise = fromIntegral lead
  where
    lead = ts - transmitted

-- | The fragment reassembly state for one direction.
data Fragments = Fragments (Maybe (Word8, [ByteString]))

noFragments :: Fragments
noFragments = Fragments Nothing

data Incoming
  = Complete Word8 ByteString
  | Partial
  | ProtocolError Text
  deriving stock (Eq, Show)

-- | One decrypted binary message, through the spec's fragmentation rules.
reassemble :: Fragments -> ByteString -> (Fragments, Incoming)
reassemble fs@(Fragments inFlight) plain = case ByteString.uncons plain of
  Nothing -> (fs, ProtocolError "empty message")
  Just (1, rest) -> case ByteString.uncons rest of
    Nothing -> (fs, ProtocolError "fragment without flags")
    Just (flags, body)
      | flags > 3 -> (fs, ProtocolError "reserved fragment flags")
      | otherwise ->
          let first = flags >= 2
              final = odd flags
           in case (first, inFlight) of
                (True, Just _) -> (fs, ProtocolError "first fragment while one is in flight")
                (False, Nothing) -> (fs, ProtocolError "fragment with none in flight")
                (True, Nothing) -> case ByteString.uncons body of
                  Nothing -> (fs, ProtocolError "first fragment without its type")
                  Just (1, _) -> (fs, ProtocolError "fragment of a fragment")
                  Just (t, d) -> finish final t [d]
                (False, Just (t, ds)) -> finish final t (body : ds)
  Just (t, body) -> case inFlight of
    Just _ -> (fs, ProtocolError "message while a fragment is in flight")
    Nothing -> (fs, Complete t body)
  where
    finish final t ds
      | final = (noFragments, Complete t (ByteString.concat (reverse ds)))
      | otherwise = (Fragments (Just (t, ds)), Partial)
