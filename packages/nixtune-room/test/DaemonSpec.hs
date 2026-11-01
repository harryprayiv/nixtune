-- | Two real daemons, the kitchen and the lab, each with a fake MPD and a
-- fake Sendspin server, talking to each other over their websockets the
-- way two Pis do. What is checked is what the daemons say about
-- themselves and the commands each sent its MPD.
module DaemonSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (void)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import FakeMpd
import Generators
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Nixtune.Room.Clock (Millis (..))
import Nixtune.Room.Config
import Nixtune.Room.Coordinator (Event (..))
import Nixtune.Room.Daemon qualified as Daemon
import Nixtune.Room.Name (RoomName)
import Nixtune.Room.Peer qualified as Peer
import Nixtune.Room.Protocol
import Nixtune.Room.Server (SendspinServer (..))
import Nixtune.Room.Wire (WireStatus (..))
import Nixtune.Sendspin.Audio (StreamFormat (..))
import System.FilePath ((</>))
import System.Timeout (timeout)
import TempDir (withTempDir)
import Test.Hspec

freePort :: IO Int
freePort = do
  s <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
  Socket.bind s (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
  p <- fromIntegral <$> Socket.socketPort s
  Socket.close s
  pure p

-- | A Sendspin server whose players report available the given number of
-- microseconds after they are held, and gone when released.
fakeServer :: Int -> (Event -> IO ()) -> IO SendspinServer
fakeServer delay post =
  pure
    SendspinServer
      { serverHold = \r -> void . forkIO $ threadDelay delay >> post (PlayerAvailable r)
      , serverRelease = post . PlayerGone
      , serverHoldOwn = pure ()
      , serverReleaseOwn = pure ()
      , serverSetDelays = \_ -> pure ()
      , serverFlushAndSeekBack = pure ()
      }

data Home = Home
  { kitchenMpd :: FakeMpd
  , labMpd :: FakeMpd
  , ports :: Map.Map RoomName Int
  , dirOf :: FilePath
  , peerMs :: Int64
  }

configFor :: Home -> RoomName -> FakeMpd -> RoomConfig
configFor h r m =
  RoomConfig
    { room = r
    , peerConfigs =
        Map.fromList
          [(p, PeerConfig "127.0.0.1" port "/" (Millis 0) "-" "-") | (p, port) <- Map.toList (ports h)]
    , acousticsMs = Map.empty
    , timing = Timing 300 2000 2000 10000 100 (peerMs h)
    , listen = Listen "127.0.0.1" (Map.findWithDefault 0 r (ports h)) (dirOf h </> ("control-" <> show (Map.findWithDefault 0 r (ports h)) <> ".sock"))
    , mpd = MpdConfig "127.0.0.1" (fakePort m) "dac" "multiroom"
    , secrets = Secrets "" "" Map.empty Map.empty
    , sendspin = SendspinConfig 8928 "/sendspin" (dirOf h </> "fifo") (StreamFormat 44100 24 2)
    }

quiet :: Text -> IO ()
quiet _ = pure ()

withHome :: (Home -> Daemon.Daemon -> Daemon.Daemon -> IO a) -> IO a
withHome = withHomeOf 50000 2000

-- | Two daemons whose players report available after the given delay in
-- microseconds, with the given peer timeout in milliseconds.
withHomeOf :: Int -> Int64 -> (Home -> Daemon.Daemon -> Daemon.Daemon -> IO a) -> IO a
withHomeOf delay timeoutMs act = withTempDir "nixtune-room" $ \dir -> do
  km <- startFakeMpd True
  lm <- startFakeMpd True
  kp <- freePort
  lp <- freePort
  lv <- freePort
  let h = Home km lm (Map.fromList [(kitchen, kp), (lab, lp), (livingRoom, lv)]) dir timeoutMs
  -- The daemons' log goes nowhere: a refused or unanswered request is
  -- logged, and hspec's report is the output that matters here.
  kd <- Daemon.start quiet (configFor h kitchen km) (fakeServer delay)
  ld <- Daemon.start quiet (configFor h lab lm) (fakeServer delay)
  withAsync (Daemon.run kd) $ \_ -> withAsync (Daemon.run ld) $ \_ -> do
    threadDelay 200000
    act h kd ld

askRoom :: Home -> RoomName -> Request -> IO (Either Peer.PeerError (Either Refusal ()))
askRoom h r = Peer.ask 5000 (PeerConfig "127.0.0.1" (Map.findWithDefault 0 r (ports h)) "/" (Millis 0) "-" "-")

-- | Wait up to two seconds for a daemon's status to satisfy a predicate.
eventually :: Daemon.Daemon -> (WireStatus -> Bool) -> IO WireStatus
eventually d p = do
  r <- timeout 2000000 go
  maybe (Daemon.currentStatus d) pure r
  where
    go = do
      s <- Daemon.currentStatus d
      if p s then pure s else threadDelay 20000 >> go

-- | Wait up to two seconds for a value to satisfy a predicate.
settled :: IO a -> (a -> Bool) -> IO a
settled get p = do
  r <- timeout 2000000 go
  maybe get pure r
  where
    go = do
      x <- get
      if p x then pure x else threadDelay 20000 >> go

has :: Text -> FakeMpd -> IO Bool
has line m = elem line <$> mpdLog m

spec :: Spec
spec = describe "two daemons" $ do
  it "boot with the DAC output on and the multiroom output off" $
    withHome $ \h _ _ -> do
      os <- mpdOutputs (labMpd h)
      os `shouldBe` Map.fromList [(0, ("dac", True)), (1, ("multiroom", False))]
  it "group when the kitchen follows the lab, and ungroup when it leaves" $
    withHome $ \h kd ld -> do
      askRoom h kitchen (ReqFollow lab) `shouldReturn` Right (Right ())
      k <- eventually kd ((== "peer-server") . wsPath)
      wsSource k `shouldBe` Just lab
      l <- eventually ld ((== "own-server") . wsPath)
      wsAudience l `shouldBe` Set.fromList [kitchen]
      -- The kitchen paused its own MPD and freed its DAC; the lab moved
      -- from its DAC output to the multiroom output without pausing.
      has "pause 1" (kitchenMpd h) `shouldReturn` True
      has "disableoutput 0" (kitchenMpd h) `shouldReturn` True
      has "enableoutput 1" (labMpd h) `shouldReturn` True
      has "disableoutput 0" (labMpd h) `shouldReturn` True
      has "pause 1" (labMpd h) `shouldReturn` False
      askRoom h kitchen ReqOwn `shouldReturn` Right (Right ())
      k' <- eventually kd ((== "direct") . wsPath)
      wsIntent k' `shouldBe` "own"
      l' <- eventually ld ((== "direct") . wsPath)
      wsAudience l' `shouldBe` Set.empty
      -- Status is published before the step's effects run, so wait for
      -- the last switch to land.
      os <- settled (mpdOutputs (labMpd h)) (== Map.fromList [(0, ("dac", True)), (1, ("multiroom", False))])
      os `shouldBe` Map.fromList [(0, ("dac", True)), (1, ("multiroom", False))]
  it "waits for a player slower than one peer call, up to the player-ready timeout" $
    withHomeOf 1000000 500 $ \h kd _ -> do
      askRoom h kitchen (ReqFollow lab) `shouldReturn` Right (Right ())
      k <- eventually kd ((== "peer-server") . wsPath)
      wsSource k `shouldBe` Just lab
  it "refuses to follow a room that is not running, and stays as it was" $
    withHome $ \h kd _ -> do
      askRoom h kitchen (ReqFollow livingRoom) `shouldReturn` Right (Left SourceUnreachable)
      k <- Daemon.currentStatus kd
      wsPath k `shouldBe` "direct"
  it "answers a hook on the control socket" $
    withHome $ \h _ ld -> do
      let path = dirOf h </> ("control-" <> show (Map.findWithDefault 0 lab (ports h)) <> ".sock")
      r <- controlRequest path "interruption-starts airplay"
      r `shouldBe` "ok"
      l <- Daemon.currentStatus ld
      wsPath l `shouldBe` "interrupted"
      controlRequest path "interruption-ends airplay" `shouldReturn` "ok"
      has "pause 0" (labMpd h) `shouldReturn` True

controlRequest :: FilePath -> Text -> IO Text
controlRequest path line = do
  s <- Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
  Socket.connect s (Socket.SockAddrUnix path)
  SocketBS.sendAll s (encodeUtf8 line <> "\n")
  r <- SocketBS.recv s 4096
  Socket.close s
  pure (Text.strip (decodeUtf8Lenient r))