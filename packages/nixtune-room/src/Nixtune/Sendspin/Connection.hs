-- | One connection from the room's server to one player: the websocket
-- out to the player's host, the cleartext init exchange, Noise KKpsk2,
-- hello and activation, then a sending thread and a receiving thread
-- until either side ends it.
--
-- The sending thread owns the sending cipher and the receiving thread
-- the receiving one, so neither is shared. The sending thread takes from
-- two queues, control before audio: the spec requires server/command,
-- server/state and group/update to go ahead of audio not yet started,
-- and server/time answers should not wait behind audio either.
module Nixtune.Sendspin.Connection
  ( Credentials (..)
  , Out (..)
  , PlayerConn (..)
  , ConnState (..)
  , newPlayerConn
  , Events (..)
  , runPlayer
  , nowMicros
  )
where

import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Control.Monad (unless, when)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket (Socket)
import Network.WebSockets qualified as WS
import Nixtune.Net (websocketOver)
import Nixtune.Room.Name (RoomName, roomNameText)
import Nixtune.Sendspin.Audio (Outstanding, StreamFormat, admit, choosePcm, noOutstanding)
import Nixtune.Sendspin.Message
import Nixtune.Sendspin.Noise
import Nixtune.Sendspin.PskId (Psk, pskId, sentinelPsk)
import System.Timeout (timeout)

-- | CLOCK_MONOTONIC in microseconds: the server's clock.
nowMicros :: IO Int64
nowMicros = fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec

data Credentials = Credentials
  { credServer :: StaticKey
  , credServerId :: Text
  , credPlayerId :: Text
  , credPlayerKey :: PublicKey
  , credPsk :: Psk
  }

data Out
  = -- | A JSON message, built from its transmit time; True when it
    -- resets the player's buffer accounting (stream/clear, stream/end).
    OutJson Bool (Int64 -> Value)
  | -- | An audio chunk: timestamp, duration, samples.
    OutChunk Int64 Int64 ByteString
  | OutClose

data ConnState = ConnState
  { csFormat :: Maybe PcmFormat
  , csCapacity :: Int
  , csActivated :: Bool
  , csAvailable :: Bool
  , csPlayer :: Maybe PlayerState
  , csStreaming :: Bool
  , csReleased :: Bool
  }

data PlayerConn = PlayerConn
  { pcId :: Int
  , pcRoom :: RoomName
  , pcOwn :: Bool
  , pcControl :: TQueue Out
  , pcAudio :: TBQueue Out
  , pcState :: TVar ConnState
  , pcEnded :: TMVar ()
  -- ^ Filled when the connection has ended, for whoever waits on it.
  }

newPlayerConn :: Int -> RoomName -> Bool -> IO PlayerConn
newPlayerConn n r own =
  PlayerConn n r own
    <$> newTQueueIO
    -- About a second of 20 ms chunks; a player that falls further behind
    -- than that misses chunks rather than holding up the others.
    <*> newTBQueueIO 50
    <*> newTVarIO (ConnState Nothing 0 False False Nothing False False)
    <*> newEmptyTMVarIO

data Events = Events
  { evLog :: Text -> IO ()
  , evPlaying :: IO Bool
  -- ^ Whether audio is flowing now, for the first group/update.
  , evState :: PlayerConn -> Bool -> Maybe PlayerState -> IO ()
  -- ^ A client/state arrived: available, and the player object if any.
  }

-- | Runs over a socket already connected to the player's host until the
-- connection ends; throws when the websocket fails. It does not close the
-- socket.
runPlayer :: Events -> Text -> StreamFormat -> Socket -> Text -> Int -> Text -> Credentials -> PlayerConn -> IO ()
runPlayer ev serverName fmt sock host port path cr pc =
  websocketOver sock host port path $ \conn -> do
    r <- timeout 30000000 (bringUp conn)
    case r of
      Nothing -> say "no answer within 30 seconds during the handshake"
      Just (Left why) -> say why
      Just (Right (sendC, recvC, frags)) ->
        WS.withPingThread conn 10 (pure ()) $
          race_ (sendLoop conn sendC) (recvLoop conn recvC frags)
  where
    room = pcRoom pc
    say t = evLog ev (roomNameText room <> "'s player: " <> t)

    bringUp conn = do
      hs <- handshake conn
      case hs of
        Left why -> pure (Left why)
        Right tr -> do
          sendC <- newIORef (sending tr)
          recvC <- newIORef (receiving tr)
          frags <- newIORef noFragments
          sendPlain conn sendC (jsonFrame (serverHello serverName))
          hello <- receiveJson conn recvC frags
          case hello of
            Just (MsgHello h) -> activate conn sendC h >>= \case
              Left why -> pure (Left why)
              Right () -> pure (Right (sendC, recvC, frags))
            Just (MsgGoodbye why) -> pure (Left ("left before hello: " <> why))
            _ -> pure (Left "did not send client/hello")

    handshake conn = do
      m <- WS.receiveDataMessage conn
      case m of
        WS.Binary _ -> pure (Left "sent binary before client/init")
        WS.Text raw _ -> do
          let cinit = Lazy.toStrict raw
          case parseClientInit cinit of
            Left f -> do
              WS.sendTextData conn (renderServerError f)
              pure (Left ("client/init refused: " <> Text.pack (show f)))
            Right ci -> case parseSuite (clientSuite ci) of
              Nothing -> do
                WS.sendTextData conn (renderServerError UnsupportedSuite)
                pure (Left ("unknown suite " <> clientSuite ci))
              Just suite
                | clientId ci /= credPlayerId cr ->
                    -- Not the player declared for this room. Closed
                    -- without a word, as any handshake failure is.
                    pure (Left ("answered with client_id " <> clientId ci <> ", not the declared player key"))
                | otherwise -> do
                    let sinit = renderServerInit (credServerId cr)
                    WS.sendTextData conn sinit
                    e <- generateEphemeral
                    let payload = renderMessage1Payload (pskId (credPsk cr))
                        (m1, st) = writeMessage1 suite (credServer cr) (credPlayerKey cr) (cinit <> sinit) e payload
                    WS.sendTextData conn (renderNoiseHandshake m1)
                    reply <- WS.receiveDataMessage conn
                    pure $ case reply of
                      WS.Text raw2 _
                        | Just m2 <- parseNoiseHandshake (Lazy.toStrict raw2) -> case readMessage2 st (credPsk cr) m2 of
                            Just (p2, tr)
                              | isEmptyObject p2 -> Right tr
                              | otherwise -> Left "Noise message 2 carried something other than {}"
                            Nothing
                              | isJust (readMessage2 st sentinelPsk m2) ->
                                  Left "does not hold this server's PSK (it answered with the Sentinel); its pairing store needs provisioning"
                              | otherwise -> Left "Noise message 2 did not authenticate"
                      _ -> Left "did not answer with noise/handshake"

    activate conn sendC h
      | "player@v1" `notElem` helloRoles h = pure (Left "does not offer player@v1")
      | otherwise = case choosePcm fmt (helloFormats h) of
          Nothing -> pure (Left "lists no PCM format at the stream's rate and channels")
          Just f -> do
            atomically . modifyTVar' (pcState pc) $ \s ->
              s {csFormat = Just f, csCapacity = fromMaybe 0 (helloBufferCapacity h), csActivated = True}
            sendPlain conn sendC (jsonFrame serverActivate)
            playing <- evPlaying ev
            sendPlain conn sendC (jsonFrame (groupUpdate playing serverName))
            pure (Right ())

    sendPlain :: WS.Connection -> IORef CipherState -> ByteString -> IO ()
    sendPlain conn ref plain = do
      c <- readIORef ref
      let (sealed, c') = encrypt c plain
      writeIORef ref c'
      WS.sendBinaryData conn sealed

    -- The next complete message, decrypted and reassembled.
    receiveFrame :: WS.Connection -> IORef CipherState -> IORef Fragments -> IO (Int64, Incoming)
    receiveFrame conn ref frags = do
      m <- WS.receiveDataMessage conn
      t <- nowMicros
      case m of
        WS.Text _ _ -> pure (t, ProtocolError "cleartext after the handshake")
        WS.Binary sealed -> do
          c <- readIORef ref
          case decrypt c (Lazy.toStrict sealed) of
            Nothing -> pure (t, ProtocolError "a message did not authenticate")
            Just (plain, c') -> do
              writeIORef ref c'
              fs <- readIORef frags
              let (fs', incoming) = reassemble fs plain
              writeIORef frags fs'
              case incoming of
                Partial -> receiveFrame conn ref frags
                _ -> pure (t, incoming)

    receiveJson conn ref frags = do
      (_, incoming) <- receiveFrame conn ref frags
      pure $ case incoming of
        Complete 0 body -> parseClientMessage body
        _ -> Nothing

    sendLoop conn ref = do
      acct <- newIORef noOutstanding
      let loop = do
            item <- atomically (readTQueue (pcControl pc) `orElse` readTBQueue (pcAudio pc))
            case item of
              OutClose -> WS.sendClose conn ("released" :: Text)
              OutJson resets build -> do
                when resets (writeIORef acct noOutstanding)
                t <- nowMicros
                sendPlain conn ref (jsonFrame (build t))
                loop
              OutChunk ts dur samples -> do
                sendChunk conn ref acct ts dur samples
                loop
      loop

    sendChunk :: WS.Connection -> IORef CipherState -> IORef Outstanding -> Int64 -> Int64 -> ByteString -> IO ()
    sendChunk conn ref acct ts dur samples = do
      st <- readTVarIO (pcState pc)
      now <- nowMicros
      let delay = maybe 0 outputDelayMs (csPlayer st) * 1000
          size = 13 + ByteString.length samples
      a <- readIORef acct
      case admit (csCapacity st) now size (ts + dur - delay) a of
        Nothing -> say "buffer_capacity reached; a chunk was not sent"
        Just a' -> do
          writeIORef acct a'
          -- Stamped as late as possible: immediately before encryption.
          t <- nowMicros
          sendPlain conn ref (audioFrame ts (sendAheadField ts t) samples)

    recvLoop conn ref frags = do
      (t, incoming) <- receiveFrame conn ref frags
      case incoming of
        ProtocolError why -> say why
        Partial -> recvLoop conn ref frags
        Complete 0 body -> case parseClientMessage body of
          Nothing -> say "sent a message that is not a Sendspin JSON message"
          Just msg -> do
            continue <- handle t msg
            when continue (recvLoop conn ref frags)
        -- Binary messages of roles the server does not implement.
        Complete _ _ -> recvLoop conn ref frags

    handle t = \case
      MsgTime tx -> do
        atomically (writeTQueue (pcControl pc) (OutJson False (serverTime tx t)))
        pure True
      MsgState available player -> do
        evState ev pc available player
        pure True
      MsgGoodbye why -> do
        unless (why == "") (say ("said goodbye: " <> why))
        pure False
      MsgHello _ -> pure True
      MsgIgnored _ -> pure True