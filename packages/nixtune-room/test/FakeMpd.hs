-- | Just enough of MPD for the daemon: status, outputs, enableoutput,
-- disableoutput, pause, and idle player. It records every command that
-- changes something, so a test can read back what the daemon did.
module FakeMpd
  ( FakeMpd (..)
  , startFakeMpd
  , mpdLog
  , mpdOutputs
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forever, void)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Nixtune.Room.Sync (catchSync)

data FakeMpd = FakeMpd
  { fakePort :: Int
  , fakePlaying :: TVar Bool
  , fakeVersion :: TVar Int
  , fakeOutputs :: TVar (Map Int (Text, Bool))
  , fakeLog :: TVar [Text]
  }

mpdLog :: FakeMpd -> IO [Text]
mpdLog f = reverse <$> readTVarIO (fakeLog f)

mpdOutputs :: FakeMpd -> IO (Map Int (Text, Bool))
mpdOutputs = readTVarIO . fakeOutputs

-- | Output 0 is the DAC, output 1 the multiroom fifo, both as nixtune's
-- MPD has them before the daemon starts: whatever the state file said.
startFakeMpd :: Bool -> IO FakeMpd
startFakeMpd playing = do
  s <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
  Socket.setSocketOption s Socket.ReuseAddr 1
  Socket.bind s (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
  Socket.listen s 16
  port <- fromIntegral <$> Socket.socketPort s
  f <-
    FakeMpd port
      <$> newTVarIO playing
      <*> newTVarIO 0
      <*> newTVarIO (Map.fromList [(0, ("dac", False)), (1, ("multiroom", True))])
      <*> newTVarIO []
  void . forkIO . forever $ do
    (c, _) <- Socket.accept s
    void . forkIO $ (serve f c `catchSync` \_ -> pure ()) `finally` Socket.close c
  pure f

serve :: FakeMpd -> Socket.Socket -> IO ()
serve f c = do
  send "OK MPD 0.24.0"
  loop mempty
  where
    send t = SocketBS.sendAll c (encodeUtf8 t <> "\n")
    loop buf = case Char8.elemIndex '\n' buf of
      Just i -> do
        handle (decodeUtf8Lenient (ByteString.take i buf))
        loop (ByteString.drop (i + 1) buf)
      Nothing -> do
        more <- SocketBS.recv c 4096
        if ByteString.null more then pure () else loop (buf <> more)
    record t = atomically (modifyTVar' (fakeLog f) (t :) >> modifyTVar' (fakeVersion f) (+ 1))
    handle line = case Text.words line of
      ["status"] -> do
        p <- readTVarIO (fakePlaying f)
        send ("state: " <> if p then "play" else "pause")
        send "OK"
      ["outputs"] -> do
        os <- readTVarIO (fakeOutputs f)
        mapM_
          ( \(i, (n, e)) -> do
              send ("outputid: " <> Text.pack (show i))
              send ("outputname: " <> n)
              send ("outputenabled: " <> if e then "1" else "0")
          )
          (Map.toList os)
        send "OK"
      [verb, n] | verb `elem` ["enableoutput", "disableoutput"] -> do
        let i = read (Text.unpack n)
        atomically (modifyTVar' (fakeOutputs f) (Map.adjust (\(name, _) -> (name, verb == "enableoutput")) i))
        record line
        send "OK"
      ["pause", v] -> do
        atomically (writeTVar (fakePlaying f) (v == "0"))
        record line
        send "OK"
      ("idle" : _) -> do
        v0 <- readTVarIO (fakeVersion f)
        atomically (readTVar (fakeVersion f) >>= \v -> check (v /= v0))
        send "changed: player"
        send "OK"
      _ -> send ("ACK [5@0] {} unknown command \"" <> line <> "\"")