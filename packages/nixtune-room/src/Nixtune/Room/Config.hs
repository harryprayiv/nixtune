-- | room.json: everything nixtune-room needs, written by the NixOS module
-- from services.nixtune.multiroom.* and read once at start. Unknown keys
-- are an error, so a typo in the module shows up as a refusal to start.
module Nixtune.Room.Config
  ( RoomConfig (..)
  , PeerConfig (..)
  , Timing (..)
  , Listen (..)
  , MpdConfig (..)
  , Secrets (..)
  , SendspinConfig (..)
  , loadConfig
  , decodeConfig
  , coordinatorConfig
  , peerOf
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as Lazy
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nixtune.Room.Clock (Millis (..), milliseconds)
import Nixtune.Room.Coordinator (Config (..))
import Nixtune.Room.Name (RoomName, mkRoomName)
import Nixtune.Sendspin.Audio (StreamFormat, parseStreamFormat)

data PeerConfig = PeerConfig
  { peerHost :: Text
  , peerPort :: Int
  , peerPath :: Text
  , peerOutputDelay :: Millis
  , peerServerKey :: Text
  -- ^ base64url Curve25519 public key: the Sendspin server_id.
  , peerPlayerKey :: Text
  -- ^ base64url Curve25519 public key: the Sendspin client_id.
  }
  deriving stock (Eq, Show)

data Timing = Timing
  { audienceGraceMs :: Int64
  , orphanTimeoutMs :: Int64
  , playerReadyTimeoutMs :: Int64
  , maxSuspensionMs :: Int64
  , reconcileIntervalMs :: Int64
  , peerTimeoutMs :: Int64
  }
  deriving stock (Eq, Show)

data Listen = Listen
  { websocketHost :: Text
  , websocketPort :: Int
  , controlSocket :: FilePath
  }
  deriving stock (Eq, Show)

data MpdConfig = MpdConfig
  { mpdHost :: Text
  , mpdPort :: Int
  , alsaOutput :: Text
  -- ^ The name of MPD's ALSA output.
  , fifoOutput :: Text
  -- ^ The name of MPD's multiroom fifo output.
  }
  deriving stock (Eq, Show)

-- | Paths to sops-nix secret files. Each holds one base64url value.
data Secrets = Secrets
  { serverKeyFile :: FilePath
  , playerKeyFile :: FilePath
  , serverPskFiles :: Map RoomName FilePath
  -- ^ For each player room: the PSK this room's server shares with it.
  , playerPskFiles :: Map RoomName FilePath
  -- ^ For each server room: the PSK this room's player shares with it.
  }
  deriving stock (Eq, Show)

-- | The room's Sendspin server: where it finds players and MPD's
-- multiroom fifo, and the format MPD writes there.
data SendspinConfig = SendspinConfig
  { playerPort :: Int
  , playerPath :: Text
  , fifoPath :: FilePath
  , streamFormat :: StreamFormat
  }
  deriving stock (Eq, Show)

data RoomConfig = RoomConfig
  { room :: RoomName
  , peerConfigs :: Map RoomName PeerConfig
  , acousticsMs :: Map RoomName (Map RoomName Millis)
  , timing :: Timing
  , listen :: Listen
  , mpd :: MpdConfig
  , secrets :: Secrets
  , sendspin :: SendspinConfig
  }
  deriving stock (Eq, Show)

strict :: [Key] -> Object -> Parser ()
strict allowed o = case filter (`notElem` allowed) (KeyMap.keys o) of
  [] -> pure ()
  extra -> fail ("unknown keys: " <> show (map Key.toString extra))

roomKey :: Text -> Parser RoomName
roomKey t = maybe (fail ("bad room name: " <> Text.unpack t)) pure (mkRoomName t)

roomMap :: (Value -> Parser a) -> Value -> Parser (Map RoomName a)
roomMap p = withObject "rooms" $ \o ->
  Map.fromList <$> traverse (\(k, v) -> (,) <$> roomKey (Key.toText k) <*> p v) (KeyMap.toList o)

instance FromJSON PeerConfig where
  parseJSON = withObject "peer" $ \o -> do
    strict ["host", "port", "path", "outputDelayMs", "serverKey", "playerKey"] o
    PeerConfig
      <$> o .: "host"
      <*> o .: "port"
      <*> o .: "path"
      <*> (Millis <$> o .: "outputDelayMs")
      <*> o .: "serverKey"
      <*> o .: "playerKey"

instance FromJSON Timing where
  parseJSON = withObject "timing" $ \o -> do
    strict ["audienceGraceMs", "orphanTimeoutMs", "playerReadyTimeoutMs", "maxSuspensionMs", "reconcileIntervalMs", "peerTimeoutMs"] o
    Timing
      <$> o .: "audienceGraceMs"
      <*> o .: "orphanTimeoutMs"
      <*> o .: "playerReadyTimeoutMs"
      <*> o .: "maxSuspensionMs"
      <*> o .: "reconcileIntervalMs"
      <*> o .: "peerTimeoutMs"

instance FromJSON Listen where
  parseJSON = withObject "listen" $ \o -> do
    strict ["websocketHost", "websocketPort", "controlSocket"] o
    Listen <$> o .: "websocketHost" <*> o .: "websocketPort" <*> o .: "controlSocket"

instance FromJSON MpdConfig where
  parseJSON = withObject "mpd" $ \o -> do
    strict ["host", "port", "alsaOutput", "fifoOutput"] o
    MpdConfig <$> o .: "host" <*> o .: "port" <*> o .: "alsaOutput" <*> o .: "fifoOutput"

instance FromJSON Secrets where
  parseJSON = withObject "secrets" $ \o -> do
    strict ["serverKey", "playerKey", "serverPsks", "playerPsks"] o
    Secrets
      <$> o .: "serverKey"
      <*> o .: "playerKey"
      <*> (roomMap parseJSON =<< o .: "serverPsks")
      <*> (roomMap parseJSON =<< o .: "playerPsks")

instance FromJSON SendspinConfig where
  parseJSON = withObject "sendspin" $ \o -> do
    strict ["playerPort", "playerPath", "fifo", "format"] o
    fmt <- either fail pure . parseStreamFormat =<< o .: "format"
    SendspinConfig <$> o .: "playerPort" <*> o .: "playerPath" <*> o .: "fifo" <*> pure fmt

instance FromJSON RoomConfig where
  parseJSON = withObject "room.json" $ \o -> do
    strict ["room", "peers", "acoustics", "timing", "listen", "mpd", "secrets", "sendspin"] o
    r <- roomKey =<< o .: "room"
    ps <- roomMap parseJSON =<< o .: "peers"
    ac <- roomMap (roomMap (fmap Millis . parseJSON)) =<< o .: "acoustics"
    cfg <-
      RoomConfig r ps ac
        <$> o .: "timing"
        <*> o .: "listen"
        <*> o .: "mpd"
        <*> o .: "secrets"
        <*> o .: "sendspin"
    if Map.member r ps then pure cfg else fail "peers must include this room"

decodeConfig :: Lazy.ByteString -> Either String RoomConfig
decodeConfig = eitherDecode

loadConfig :: FilePath -> IO (Either String RoomConfig)
loadConfig path = decodeConfig <$> Lazy.readFile path

coordinatorConfig :: RoomConfig -> Config
coordinatorConfig c =
  Config
    { peers = Map.map peerOutputDelay (peerConfigs c)
    , acoustics = acousticsMs c
    , audienceGrace = milliseconds (audienceGraceMs t)
    , orphanTimeout = milliseconds (orphanTimeoutMs t)
    , playerReadyTimeout = milliseconds (playerReadyTimeoutMs t)
    , maxSuspension = milliseconds (maxSuspensionMs t)
    }
  where
    t = timing c

peerOf :: RoomConfig -> RoomName -> Maybe PeerConfig
peerOf c r = Map.lookup r (peerConfigs c)