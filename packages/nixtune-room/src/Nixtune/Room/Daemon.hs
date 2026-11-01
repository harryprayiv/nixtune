-- | The shell around the pure coordinator. One thread owns the room's
-- state and is the only caller of 'step'; everything else (websocket and
-- control-socket clients, MPD's idle connection, the clock, peer calls
-- that take a while) turns what it sees into an 'Event' on one queue.
--
-- Effects run in the order 'step' returns them, each finished before the
-- next starts, except peer calls whose answer arrives later as an event
-- (AskHold, Probe): those run on their own thread so the coordinator
-- never waits on another room (HooksAnswerFast, AnswersFromMemory).
module Nixtune.Room.Daemon
  ( Daemon
  , start
  , run
  , postEvent
  , currentStatus
  , monotonicNow
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (bracket, catch, finally)
import Control.Monad (forever, void, when)
import Data.ByteString.Char8 qualified as Char8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Network.WebSockets qualified as WS
import Nixtune.Mpd.Client qualified as Mpd
import Nixtune.Mpd.Protocol (Output (..), PlayState (..), Response (..), outputNamed, parseOutputs, playState)
import Nixtune.Room.Clock (Instant (..))
import Nixtune.Room.Config
import Nixtune.Room.Coordinator (Effect (..), Event (..), step)
import Nixtune.Room.Coordinator qualified as Coordinator
import Nixtune.Room.Name (RoomName, roomNameText)
import Nixtune.Room.Outputs (Action (..))
import Nixtune.Room.Peer qualified as Peer
import Nixtune.Room.Protocol (Refusal (..), ReplyTo (..), Request (..))
import Nixtune.Room.Server (SendspinServer (..))
import Nixtune.Room.State (RoomState, initialState)
import Nixtune.Room.Status (peerView, statusOf)
import Nixtune.Room.Sync (catchSync, describe, trySync)
import Nixtune.Room.Wire
import System.Directory (doesPathExist, removeFile)
import System.Timeout (timeout)
import System.Posix.Files (setFileMode)

data Daemon = Daemon
  { config :: RoomConfig
  , coordinator :: Coordinator.Config
  , events :: TQueue Event
  , status :: TVar WireStatus
  , replies :: TVar (Map Int (Text -> IO ()))
  , subscribers :: TVar (Map Int (Text -> IO ()))
  , nextId :: TVar Int
  , mpdCommands :: Mpd.Connection
  , server :: SendspinServer
  , say :: Text -> IO ()
  -- ^ Where log lines go: stderr under systemd, nowhere in the tests.
  }

monotonicNow :: IO Instant
monotonicNow = Instant . fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec

postEvent :: Daemon -> Event -> IO ()
postEvent d = atomically . writeTQueue (events d)

currentStatus :: Daemon -> IO WireStatus
currentStatus = readTVarIO . status

fresh :: Daemon -> STM Int
fresh d = do
  n <- readTVar (nextId d)
  writeTVar (nextId d) (n + 1)
  pure n

-- | Connect to MPD, retrying while it starts, then put the outputs where
-- RoomBoots says they are: ALSA enabled, multiroom disabled.
start :: (Text -> IO ()) -> RoomConfig -> ((Event -> IO ()) -> IO SendspinServer) -> IO Daemon
start logTo cfg makeServer = do
  q <- newTQueueIO
  conn <- connectMpd cfg
  let st0 = initialState (room cfg)
  d <-
    Daemon cfg (coordinatorConfig cfg) q
      <$> newTVarIO (statusOf st0)
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO 1
      <*> pure conn
      <*> makeServer (atomically . writeTQueue q)
      <*> pure logTo
  setOutput d (alsaOutput (mpd cfg)) True
  setOutput d (fifoOutput (mpd cfg)) False
  playing <- mpdPlaying d
  postEvent d (MpdPlaying playing)
  pure d

connectMpd :: RoomConfig -> IO Mpd.Connection
connectMpd cfg = go (30 :: Int)
  where
    m = mpd cfg
    go n = do
      r <- trySync (Mpd.connect (mpdHost m) (mpdPort m))
      case r of
        Right c -> pure c
        Left e
          | n > 0 -> threadDelay 1000000 >> go (n - 1)
          | otherwise -> fail ("cannot reach MPD: " <> describe e)

run :: Daemon -> IO ()
run d =
  mapConcurrently_
    id
    [ coordinatorLoop d (initialState (room (config d)))
    , ticker d
    , mpdWatcher d
    , websocketServer d
    , controlServer d
    ]

coordinatorLoop :: Daemon -> RoomState -> IO ()
coordinatorLoop d = go
  where
    go st = do
      ev <- atomically (readTQueue (events d))
      now <- monotonicNow
      let (st', effects) = step (coordinator d) now ev st
      atomically (writeTVar (status d) (statusOf st'))
      mapM_ (\e -> runEffect d e `catchSync` \x -> say d ("effect " <> Text.pack (show e) <> " failed: " <> Text.pack (describe x))) effects
      go st'

ticker :: Daemon -> IO ()
ticker d = forever $ do
  threadDelay (fromIntegral (reconcileIntervalMs (timing (config d))) * 1000)
  postEvent d Tick

mpdPlaying :: Daemon -> IO Bool
mpdPlaying d = do
  r <- Mpd.command (mpdCommands d) "status"
  pure $ case r of
    Done kv -> playState kv == Just Playing
    Failed _ -> False

-- | A second MPD connection that only idles, so the command connection is
-- never blocked behind it.
mpdWatcher :: Daemon -> IO ()
mpdWatcher d = do
  idleConn <- connectMpd (config d)
  Mpd.idleLoop idleConn ["player"] $ do
    playing <- mpdPlaying d
    postEvent d (MpdPlaying playing)

setOutput :: Daemon -> Text -> Bool -> IO ()
setOutput d name enabled = do
  r <- Mpd.command (mpdCommands d) "outputs"
  case r of
    Failed e -> say d ("outputs failed: " <> e)
    Done kv -> case outputNamed name (parseOutputs kv) of
      Nothing -> say d ("MPD has no output named " <> name)
      Just o -> do
        let verb = if enabled then "enableoutput " else "disableoutput "
        res <- Mpd.command (mpdCommands d) (verb <> Text.pack (show (outputId o)))
        case res of
          Failed e -> say d (verb <> name <> " failed: " <> e)
          Done _ -> pure ()

self' :: Daemon -> RoomName
self' = room . config

peerTimeout :: Daemon -> Integer
peerTimeout = fromIntegral . peerTimeoutMs . timing . config

-- | Ask a peer and wait. Used for release and suspend, which the next
-- action in the plan depends on and which a peer answers at once.
askNow :: Daemon -> RoomName -> Request -> IO ()
askNow d r req = case peerOf (config d) r of
  Nothing -> say d ("no peer named " <> roomNameText r)
  Just p -> do
    result <- Peer.ask (fromIntegral (peerTimeout d)) p req
    case result of
      Right (Right ()) -> pure ()
      Right (Left why) -> say d (roomNameText r <> " refused " <> renderRequest req <> ": " <> refusalWord why)
      Left e -> say d (roomNameText r <> " did not answer " <> renderRequest req <> ": " <> Peer.describePeerError e)

runAction :: Daemon -> Action -> IO ()
runAction d = \case
  EnableAlsa -> setOutput d (alsaOutput (mpd (config d))) True
  DisableAlsa -> setOutput d (alsaOutput (mpd (config d))) False
  EnableFifo -> setOutput d (fifoOutput (mpd (config d))) True
  DisableFifo -> setOutput d (fifoOutput (mpd (config d))) False
  HoldOwnPlayer -> serverHoldOwn (server d)
  ReleaseOwnPlayer -> serverReleaseOwn (server d)
  AskRelease r -> askNow d r (ReqRelease (self' d))
  AskSuspend r -> askNow d r (ReqSuspend (self' d))
  AskHold r -> void . forkIO $ do
    answer <- case peerOf (config d) r of
      Nothing -> pure (Left UnknownRoom)
      Just p -> do
        result <- Peer.ask (fromIntegral (peerTimeout d)) p (ReqHold (self' d))
        pure $ case result of
          Right a -> a
          Left _ -> Left SourceUnreachable
    postEvent d (HoldAnswered r answer)

runEffect :: Daemon -> Effect -> IO ()
runEffect d = \case
  Act a -> runAction d a
  Reply (ReplyTo n) x -> do
    sink <- atomically $ do
      m <- readTVar (replies d)
      writeTVar (replies d) (Map.delete n m)
      pure (Map.lookup n m)
    maybe (pure ()) ($ renderReply x) sink
  PauseMpd -> void (Mpd.command (mpdCommands d) "pause 1")
  ResumeMpd -> void (Mpd.command (mpdCommands d) "pause 0")
  FlushAndSeekBack -> serverFlushAndSeekBack (server d)
  ServerHold r -> serverHold (server d) r
  ServerRelease r -> serverRelease (server d) r
  SendDelays m -> serverSetDelays (server d) m
  Probe r -> void . forkIO $ do
    view <- case peerOf (config d) r of
      Nothing -> pure Nothing
      Just p -> either (const Nothing) (Just . peerView) <$> Peer.askStatus (fromIntegral (peerTimeout d)) p
    postEvent d (PeerProbed r view)
  StatusChanged -> do
    line <- renderStatus <$> readTVarIO (status d)
    sinks <- Map.elems <$> readTVarIO (subscribers d)
    mapM_ ($ line) sinks

-- | Handle one line from any client. 'send' writes a line back to it;
-- 'onSubscribe' registers it for pushed status lines.
handleLine :: Daemon -> (Text -> IO ()) -> (Int -> IO ()) -> Text -> IO ()
handleLine d send onSubscribe line = case parseCommand line of
  Left e -> send ("error " <> e)
  Right CmdStatus -> send . renderStatus =<< currentStatus d
  Right CmdSubscribe -> do
    n <- atomically $ do
      n <- fresh d
      modifyTVar' (subscribers d) (Map.insert n send)
      pure n
    send . renderStatus =<< currentStatus d
    onSubscribe n
  Right (CmdRequest req) -> do
    n <- atomically $ do
      n <- fresh d
      modifyTVar' (replies d) (Map.insert n send)
      pure n
    postEvent d (Requested (ReplyTo n) req)

-- | A send that never throws into the coordinator thread: a client that
-- has gone away just stops receiving.
safeSend :: (Text -> IO ()) -> Text -> IO ()
safeSend f t = f t `catchSync` \_ -> pure ()

websocketServer :: Daemon -> IO ()
websocketServer d =
  WS.runServer (Text.unpack (websocketHost l)) (websocketPort l) $ \pending -> do
    conn <- WS.acceptRequest pending
    lock <- newMVar ()
    subs <- newTVarIO []
    let send t = safeSend (\x -> withMVar lock (\_ -> WS.sendTextData conn x)) t
        unsubscribe = do
          ns <- readTVarIO subs
          atomically (modifyTVar' (subscribers d) (\m -> foldr Map.delete m ns))
        loop = forever $ do
          msg <- WS.receiveData conn
          mapM_ (handleLine d send (\n -> atomically (modifyTVar' subs (n :)))) (filter (not . Text.null) (Text.lines msg))
    WS.withPingThread conn 30 (pure ()) (loop `catch` \(_ :: WS.ConnectionException) -> pure ())
      `finally` unsubscribe
  where
    l = listen (config d)

-- | The control socket: one line in, one line out, then closed. This is
-- what the AirPlay hooks and `nixtune-room ctl` use.
controlServer :: Daemon -> IO ()
controlServer d = do
  let path = controlSocket (listen (config d))
  exists <- doesPathExist path
  when exists (removeFile path)
  bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \s -> do
    Socket.bind s (Socket.SockAddrUnix path)
    setFileMode path 0o660
    Socket.listen s 16
    forever $ do
      (c, _) <- Socket.accept s
      void . forkIO $ serveControl c `finally` Socket.close c
  where
    serveControl c = do
      line <- readControlLine c
      done <- newEmptyTMVarIO
      let send t = safeSend (\x -> SocketBS.sendAll c (encodeUtf8 x <> "\n")) t >> atomically (void (tryPutTMVar done ()))
      if line == "subscribe"
        then send "error subscribe is for websocket clients"
        else handleLine d send (\_ -> pure ()) line
      -- A request's reply may come from the coordinator thread. Every
      -- request is answered within the peer timeout or the player-ready
      -- deadline, so this wait ends; the timeout is a second guard.
      void . timeout ((fromIntegral (peerTimeout d) + 5000) * 1000) . atomically $ takeTMVar done
    readControlLine c = go mempty
      where
        go acc = do
          chunk <- SocketBS.recv c 4096
          let acc' = acc <> chunk
          if Char8.null chunk || Char8.elem '\n' acc'
            then pure (Text.strip (decodeUtf8Lenient (Char8.takeWhile (/= '\n') acc')))
            else go acc'