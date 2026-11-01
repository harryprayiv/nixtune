-- | The room's Sendspin server (contract SendspinServer). It holds the
-- players the coordinator tells it to, reads MPD's multiroom fifo, and
-- sends every streaming player the same audio with the same timestamps.
--
-- Spec: github.com/Sendspin/spec at the commit 'specCommit' names.
-- Implemented: core messages version 1, Noise KKpsk2 with provisioned
-- long-term PSKs and both suites, the time responder, player@v1 with
-- PCM, send-ahead across the group, set_output_delay, stream start,
-- clear and end, buffer accounting and fragment reassembly. Deferred to
-- stage 5 (M19): FLAC, metadata@v1, the listener on 8927.
module Nixtune.Sendspin.Server
  ( start
  , specCommit
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket, evaluate, finally)
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (partitionEithers)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Network.Socket qualified as Socket
import Nixtune.Mpd.Client qualified as Mpd
import Nixtune.Mpd.Protocol (Response (..))
import Nixtune.Net (connectHost)
import Nixtune.Room.Clock (Millis (..))
import Nixtune.Room.Config
import Nixtune.Room.Coordinator (Event (..))
import Nixtune.Room.Keys (decodeBase64Url)
import Nixtune.Room.Name (RoomName, roomNameText)
import Nixtune.Room.Server (SendspinServer (..))
import Nixtune.Room.Sync (catchSync, describe, trySync)
import Nixtune.Sendspin.Audio
import Nixtune.Sendspin.Connection
import Nixtune.Sendspin.Message
import Nixtune.Sendspin.Noise (StaticKey, mkPublicKey, mkStaticKey, staticPublic)
import Nixtune.Sendspin.PskId (Psk, base64Url, mkPsk)
import Numeric (showFFloat)
import System.Directory (doesPathExist)
import System.IO (IOMode (ReadWriteMode), hClose, openBinaryFile)
import System.Posix.Files (createNamedPipe, getFileStatus, isNamedPipe)
import System.Timeout (timeout)

-- | The commit of github.com/Sendspin/spec this server implements.
specCommit :: Text
specCommit = "f417b498e294d34c2c788918724443b6898f972f"

data Env = Env
  { cfg :: RoomConfig
  , say :: Text -> IO ()
  , post :: Event -> IO ()
  , serverKey :: StaticKey
  , serverId :: Text
  , psks :: Map RoomName Psk
  , conns :: TVar (Map RoomName PlayerConn)
  , nextConn :: TVar Int
  , timeline :: TVar (Maybe Timeline)
  , flowing :: TVar Bool
  , draining :: TVar (Maybe (Int64, Int64))
  -- ^ After a pause: when the drain began, and the audio unheard so far.
  , delays :: TVar (Map RoomName Millis)
  }

fmt :: Env -> StreamFormat
fmt = streamFormat . sendspin . cfg

name :: Env -> Text
name = roomNameText . room . cfg

readSecretBytes :: FilePath -> IO (Either String ByteString)
readSecretBytes path = do
  r <- (Right <$> ByteString.readFile path) `catchSync` (pure . Left . describe)
  pure (either (Left . ((path <> ": ") <>)) (decodeBase64Url . decodeUtf8Lenient) r)

-- | Reads the server's key and its PSKs, checks the key against the
-- declaration, and starts the fifo reader.
start :: (Text -> IO ()) -> RoomConfig -> (Event -> IO ()) -> IO SendspinServer
start logTo c postEvent = do
  keyBytes <- readSecretBytes (serverKeyFile (secrets c))
  key <- either (fail . ("server key: " <>)) pure (keyBytes >>= maybe (Left "not a Curve25519 private key") Right . mkStaticKey)
  let sid = base64Url (staticPublic key)
  case peerOf c (room c) of
    Just p
      | peerServerKey p /= sid ->
          fail ("the server key's public half is " <> Text.unpack sid <> ", but this room is declared with " <> Text.unpack (peerServerKey p))
    _ -> pure ()
  read' <- traverse (\(r, path) -> fmap (\b -> (r, b >>= maybe (Left "not 32 bytes") Right . mkPsk)) (readSecretBytes path)) (Map.toList (serverPskFiles (secrets c)))
  let (bad, good) = partitionEithers [either (\e -> Left (roomNameText r <> ": " <> Text.pack e)) (Right . (r,)) v | (r, v) <- read']
  mapM_ (\e -> logTo ("PSK for " <> e)) bad
  env <-
    Env c logTo postEvent key sid (Map.fromList good)
      <$> newTVarIO Map.empty
      <*> newTVarIO 1
      <*> newTVarIO Nothing
      <*> newTVarIO False
      <*> newTVarIO Nothing
      <*> newTVarIO Map.empty
  logTo ("sendspin server " <> sid <> ", spec " <> specCommit)
  void (forkIO (fifoLoop env))
  pure
    SendspinServer
      { serverHold = hold env False
      , serverRelease = release env
      , serverHoldOwn = hold env True (room c)
      , serverReleaseOwn = release env (room c)
      , serverSetDelays = setDelays env
      , serverFlushAndSeekBack = flush env
      }

credentialsFor :: Env -> RoomName -> Either Text (PeerConfig, Credentials)
credentialsFor env r = do
  p <- maybe (Left "not declared") Right (peerOf (cfg env) r)
  pk <- either (const (Left "player key is not base64url")) Right (decodeBase64Url (peerPlayerKey p))
  key <- maybe (Left "player key is not a Curve25519 public key") Right (mkPublicKey pk)
  psk <- maybe (Left "no PSK provisioned for it") Right (Map.lookup r (psks env))
  pure (p, Credentials (serverKey env) (serverId env) (peerPlayerKey p) key psk)

-- | Connect to the room's player, unless already connected. A member's
-- connection that ends unasked is reported as PlayerGone; the room's own
-- player is reconnected instead, because the coordinator tracks no
-- membership for it (OwnPlayerIsNoMember).
hold :: Env -> Bool -> RoomName -> IO ()
hold env own r = do
  existing <- Map.lookup r <$> readTVarIO (conns env)
  live <- case existing of
    Just pc -> not . csReleased <$> readTVarIO (pcState pc)
    Nothing -> pure False
  case existing of
    Just pc | live -> do
      st <- readTVarIO (pcState pc)
      when (csStreaming st && not own) (post env (PlayerAvailable r))
    _ -> case credentialsFor env r of
      Left why -> do
        say env ("cannot hold " <> roomNameText r <> "'s player: " <> why)
        unless own (post env (PlayerGone r))
      Right (p, cr) -> do
        pc <- atomically $ do
          n <- readTVar (nextConn env)
          writeTVar (nextConn env) (n + 1)
          pure n
        conn <- newPlayerConn pc r own
        atomically (modifyTVar' (conns env) (Map.insert r conn))
        void . forkIO $ do
          let ss = sendspin (cfg env)
          connected <- connectWhileHeld env conn (peerHost p) (playerPort ss)
          forM_ connected $ \s ->
            (runPlayer (events env) (name env) (fmt env) s (peerHost p) (playerPort ss) (playerPath ss) cr conn `finally` Socket.close s)
              `catchSync` \e -> say env (roomNameText r <> "'s player: " <> Text.pack (describe e))
          ended env conn

-- | Connect to a held player, trying again every half second while
-- nothing listens there yet and the hold stands. A player listens only
-- once it has opened its device (KnownIssue
-- player_starts_only_with_dac_free), which can be after the hold: a
-- follower frees its DAC as it asks, and its player may be between
-- restarts then. A hold that never connects is ended by the coordinator
-- at the player-ready timeout, which releases it. Only the first failure
-- is logged.
connectWhileHeld :: Env -> PlayerConn -> Text -> Int -> IO (Maybe Socket.Socket)
connectWhileHeld env pc host port = go True
  where
    go firstTry = do
      released <- csReleased <$> readTVarIO (pcState pc)
      if released
        then pure Nothing
        else do
          r <- trySync (connectHost host port)
          case r of
            Right s -> pure (Just s)
            Left e -> do
              when firstTry $
                say env (roomNameText (pcRoom pc) <> "'s player: " <> Text.pack (describe e) <> "; trying again while it is held")
              threadDelay 500000
              go False

ended :: Env -> PlayerConn -> IO ()
ended env pc = do
  st <- atomically $ do
    modifyTVar' (conns env) (Map.update (\q -> if pcId q == pcId pc then Nothing else Just q) (pcRoom pc))
    void (tryPutTMVar (pcEnded pc) ())
    readTVar (pcState pc)
  unless (csReleased st) $
    if pcOwn pc
      then do
        threadDelay 2000000
        still <- Map.member (pcRoom pc) <$> readTVarIO (conns env)
        unless still (hold env True (pcRoom pc))
      else post env (PlayerGone (pcRoom pc))

-- | End the stream and close the connection, and return only once the
-- connection has ended, or after two seconds. The caller's next action
-- usually opens the DAC (MPD's ALSA output, or AirPlay), and the player
-- closes its output on its own worker thread after stream/end, with no
-- acknowledgement in the protocol; waiting for the close and a quarter
-- of a second more is what keeps the two from colliding (KnownIssue
-- player_closes_output_without_acknowledgement).
release :: Env -> RoomName -> IO ()
release env r = do
  waitFor <- atomically $ do
    m <- readTVar (conns env)
    case Map.lookup r m of
      Nothing -> pure Nothing
      Just pc -> do
        st <- readTVar (pcState pc)
        if csReleased st
          then pure Nothing
          else do
            when (csStreaming st) $ do
              void (flushTBQueue (pcAudio pc))
              writeTQueue (pcControl pc) (OutJson True (const streamEnd))
            writeTQueue (pcControl pc) OutClose
            writeTVar (pcState pc) st {csReleased = True, csStreaming = False}
            pure (Just (pc, csStreaming st))
  forM_ waitFor $ \(pc, wasStreaming) -> do
    void (timeout 2000000 (atomically (readTMVar (pcEnded pc))))
    when wasStreaming (threadDelay 250000)

events :: Env -> Events
events env =
  Events
    { evLog = say env
    , evPlaying = readTVarIO (flowing env)
    , evState = onState env
    }

-- | A client/state: start the stream when the player first reports
-- itself available with its player object, end it when it reports
-- itself unavailable, and tell the coordinator either way.
onState :: Env -> PlayerConn -> Bool -> Maybe PlayerState -> IO ()
onState env pc available player = do
  wanted <- readTVarIO (delays env)
  change <- atomically $ do
    st <- readTVar (pcState pc)
    let ps = maybe (csPlayer st) Just player
        st' = st {csAvailable = available, csPlayer = ps}
    case (csFormat st, csReleased st) of
      (Just f, False)
        | available && not (csStreaming st) && isJust ps -> do
            writeTQueue (pcControl pc) (OutJson True (streamStartPcm f))
            writeTVar (pcState pc) st' {csStreaming = True}
            pure (Just True)
        | not available && csStreaming st -> do
            void (flushTBQueue (pcAudio pc))
            writeTQueue (pcControl pc) (OutJson True (const streamEnd))
            writeTVar (pcState pc) st' {csStreaming = False}
            pure (Just False)
      _ -> writeTVar (pcState pc) st' >> pure Nothing
  atomically (sendDelay pc wanted)
  unless (pcOwn pc) $ case change of
    Just True -> post env (PlayerAvailable (pcRoom pc))
    Just False -> post env (PlayerGone (pcRoom pc))
    Nothing -> pure ()

-- | set_output_delay to the delay the coordinator wants for this player,
-- when the player takes the command and reports something else. The
-- delay counts as applied from the moment the command is queued:
-- aiosendspin applies it without reporting it in client/state (KnownIssue
-- player_does_not_report_commanded_delay), and the send-ahead and the
-- buffer accounting must include it either way. A later report from the
-- player replaces it.
sendDelay :: PlayerConn -> Map RoomName Millis -> STM ()
sendDelay pc wanted = do
  st <- readTVar (pcState pc)
  case (Map.lookup (pcRoom pc) wanted, csPlayer st) of
    (Just (Millis d), Just ps)
      | "set_output_delay" `elem` supportedCommands ps
      , clamped <- fromIntegral (max 0 (min 5000 d))
      , clamped /= outputDelayMs ps
      , not (csReleased st) -> do
          writeTQueue (pcControl pc) (OutJson False (const (setOutputDelay clamped)))
          writeTVar (pcState pc) st {csPlayer = Just ps {outputDelayMs = clamped}}
    _ -> pure ()

setDelays :: Env -> Map RoomName Millis -> IO ()
setDelays env m = atomically $ do
  writeTVar (delays env) m
  pcs <- Map.elems <$> readTVar (conns env)
  mapM_ (`sendDelay` m) pcs

-- | PauseClears: clear every stream now, then let the fifo reader
-- discard what MPD still delivers and seek MPD back once it is quiet.
flush :: Env -> IO ()
flush env = do
  now <- nowMicros
  atomically $ do
    tl <- readTVar (timeline env)
    let unheard = maybe 0 (\t -> max 0 (timelineEnd (sRate (fmt env)) t - now)) tl
    writeTVar (timeline env) Nothing
    writeTVar (draining env) (Just (now, unheard))
    pcs <- Map.elems <$> readTVar (conns env)
    forM_ pcs $ \pc -> do
      st <- readTVar (pcState pc)
      when (csStreaming st) $ do
        void (flushTBQueue (pcAudio pc))
        writeTQueue (pcControl pc) (OutJson True streamClear)

-- | MPD's fifo plugin uses a fifo it finds and removes only one it made,
-- so nixtune-room makes it, and holds it open read-write: MPD then
-- always finds a reader, and the reader never sees end of file.
ensureFifo :: FilePath -> IO ()
ensureFifo path = do
  exists <- doesPathExist path
  if exists
    then do
      st <- getFileStatus path
      unless (isNamedPipe st) (fail (path <> " exists and is not a fifo"))
    else createNamedPipe path 0o660

fifoLoop :: Env -> IO ()
fifoLoop env = forever $ do
  readFifo env `catchSync` \e -> say env ("multiroom fifo: " <> Text.pack (describe e))
  threadDelay 5000000

readFifo :: Env -> IO ()
readFifo env = do
  let path = fifoPath (sendspin (cfg env))
      f = fmt env
      frameBytes = inputFrameBytes f
      chunkBytes = chunkFrames f * frameBytes
  ensureFifo path
  bracket (openBinaryFile path ReadWriteMode) hClose $ \h -> do
    lastData <- newIORef =<< nowMicros
    let loop pending = do
          r <- timeout 50000 (ByteString.hGetSome h 65536)
          now <- nowMicros
          case r of
            Nothing -> do
              quietFor <- (now -) <$> readIORef lastData
              drain <- readTVarIO (draining env)
              case drain of
                Just (_, unheard) -> finishDrain env unheard
                Nothing -> unless (ByteString.null pending) (emit env pending)
              when (quietFor >= 500000) (setFlowing env False)
              loop ByteString.empty
            Just bytes -> do
              writeIORef lastData now
              drain <- readTVarIO (draining env)
              case drain of
                Just (began, unheard) -> do
                  let frames = fromIntegral (ByteString.length bytes `div` frameBytes)
                      unheard' = unheard + framesDuration (sRate f) frames
                  -- MPD did not stop: give up discarding after two
                  -- seconds rather than discard forever.
                  if now - began > 2000000
                    then finishDrain env unheard'
                    else atomically (writeTVar (draining env) (Just (began, unheard')))
                  loop ByteString.empty
                Nothing -> do
                  setFlowing env True
                  let buf = pending <> bytes
                      whole = (ByteString.length buf `div` chunkBytes) * chunkBytes
                      (ready, rest) = ByteString.splitAt whole buf
                  mapM_ (emit env) (splitEvery chunkBytes ready)
                  -- Keep only whole frames for later; a partial frame
                  -- waits in 'rest' for the bytes that complete it.
                  loop rest
    loop ByteString.empty

splitEvery :: Int -> ByteString -> [ByteString]
splitEvery n b
  | ByteString.null b = []
  | otherwise = let (x, y) = ByteString.splitAt n b in x : splitEvery n y

finishDrain :: Env -> Int64 -> IO ()
finishDrain env unheard = do
  atomically (writeTVar (draining env) Nothing)
  when (unheard > 0) $ do
    let secs = fromIntegral unheard / 1000000 :: Double
    r <- trySeek (Text.pack (showFFloat (Just 3) secs ""))
    case r of
      Left e -> say env ("seeking MPD back failed: " <> e)
      Right () -> pure ()
  where
    trySeek secs =
      ( bracket (Mpd.connect (mpdHost m) (mpdPort m)) Mpd.close $ \c -> do
          res <- Mpd.command c ("seekcur -" <> secs)
          pure $ case res of
            Done _ -> Right ()
            Failed e -> Left e
      )
        `catchSync` (pure . Left . Text.pack . describe)
      where
        m = mpd (cfg env)

setFlowing :: Env -> Bool -> IO ()
setFlowing env b = atomically $ do
  was <- readTVar (flowing env)
  when (was /= b) $ do
    writeTVar (flowing env) b
    pcs <- Map.elems <$> readTVar (conns env)
    forM_ pcs $ \pc -> do
      st <- readTVar (pcState pc)
      when (csActivated st && not (csReleased st)) $
        writeTQueue (pcControl pc) (OutJson False (const (groupUpdate b (name env))))

-- | Stamp one chunk of whole frames and queue it for every streaming
-- player, in its format. The streaming check and the queueing are one
-- transaction, so no chunk lands behind a stream/end or stream/clear.
emit :: Env -> ByteString -> IO ()
emit env raw = do
  let f = fmt env
      frames = fromIntegral (ByteString.length raw `div` inputFrameBytes f)
  now <- nowMicros
  pcs <- Map.elems <$> readTVarIO (conns env)
  streaming <- filterM (fmap (\s -> csStreaming s && not (csReleased s)) . readTVarIO . pcState) pcs
  formats <- nub . mapMaybe csFormat <$> mapM (readTVarIO . pcState) streaming
  payloads <- Map.fromList <$> traverse (\pf -> (pf,) <$> evaluate (pack f pf raw)) formats
  let dur = framesDuration (sRate f) frames
  dropped <- atomically $ do
    timings <- mapMaybe csPlayer <$> mapM (readTVar . pcState) streaming
    tl <- readTVar (timeline env)
    let ahead = sendAhead [(minBufferMs t, outputDelayMs t) | t <- timings]
        (ts, tl') = stamp (sRate f) ahead now frames tl
    writeTVar (timeline env) (Just tl')
    concat <$> traverse (queue ts dur payloads) pcs
  forM_ dropped $ \r -> say env (roomNameText r <> "'s player is a second behind; a chunk was dropped")
  where
    queue ts dur payloads pc = do
      st <- readTVar (pcState pc)
      case csFormat st >>= (`Map.lookup` payloads) of
        Just samples | csStreaming st && not (csReleased st) -> do
          full <- isFullTBQueue (pcAudio pc)
          if full
            then pure [pcRoom pc]
            else writeTBQueue (pcAudio pc) (OutChunk ts dur samples) >> pure []
        _ -> pure []