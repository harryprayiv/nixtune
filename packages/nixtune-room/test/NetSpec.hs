-- | Reaching another room when its name resolves to more than one
-- address and not every address has anything listening.
module NetSpec (spec) where

import Control.Exception (bracket)
import Network.Socket qualified as Socket
import Nixtune.Net (connectFirst)
import Test.Hspec

loopback :: Socket.PortNumber -> Socket.AddrInfo
loopback port =
  Socket.defaultHints
    { Socket.addrFamily = Socket.AF_INET
    , Socket.addrSocketType = Socket.Stream
    , Socket.addrAddress = Socket.SockAddrInet port (Socket.tupleToHostAddress (127, 0, 0, 1))
    }

-- | A listening socket on a port the system picked.
withListener :: (Socket.PortNumber -> IO a) -> IO a
withListener act =
  bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \s -> do
    Socket.bind s (Socket.addrAddress (loopback 0))
    Socket.listen s 4
    Socket.socketPort s >>= act

-- | A port nothing listens on: bound by the system, then let go.
closedPort :: IO Socket.PortNumber
closedPort = bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \s -> do
  Socket.bind s (Socket.addrAddress (loopback 0))
  Socket.socketPort s

peerPortOf :: Socket.Socket -> IO Socket.PortNumber
peerPortOf s =
  Socket.getPeerName s >>= \case
    Socket.SockAddrInet port _ -> pure port
    other -> fail ("connected to an address that is not IPv4: " <> show other)

spec :: Spec
spec = describe "connectFirst" $ do
  it "connects to the second address when the first refuses" $ do
    refusing <- closedPort
    withListener $ \open -> do
      port <- bracket (connectFirst [loopback refusing, loopback open]) Socket.close peerPortOf
      port `shouldBe` open
  it "fails when every address refuses" $ do
    a <- closedPort
    b <- closedPort
    (connectFirst [loopback a, loopback b] >>= Socket.close) `shouldThrow` anyIOException
