-- | Opening a websocket to another machine by name: to a peer
-- coordinator, through its nginx, and to a player, by the room's server.
--
-- A name can resolve to an IPv6 address and an IPv4 one, with the IPv6
-- one first, while what listens there listens on IPv4 only: nginx with
-- the module's listen on 0.0.0.0, and sendspin-cli's player, whose
-- listener binds 0.0.0.0. websockets' own runClient tries the first
-- address and gives up, so the connection is made here and the
-- websocket run over it.
module Nixtune.Net
  ( connectFirst
  , connectHost
  , websocketOver
  )
where

import Control.Exception (throwIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.Socket qualified as Socket
import Network.WebSockets qualified as WS
import Nixtune.Room.Sync (trySync)

-- | Connect to the first of the addresses that accepts, in the order
-- given. A refused address is skipped at once. One that drops the
-- connection holds the attempt until the caller's timeout, so the later
-- addresses are not reached; on a LAN with NixOS's firewall, which
-- allows a port on both families alike, a closed port refuses.
connectFirst :: [Socket.AddrInfo] -> IO Socket.Socket
connectFirst = \case
  [] -> ioError (userError "the host has no address")
  a : rest -> do
    s <- Socket.socket (Socket.addrFamily a) Socket.Stream Socket.defaultProtocol
    r <- trySync (Socket.connect s (Socket.addrAddress a))
    case r of
      Right () -> pure s
      Left e -> do
        Socket.close s
        if null rest then throwIO e else connectFirst rest

-- | Resolve the host and connect to the first of its addresses that
-- accepts. The caller closes the socket.
connectHost :: Text -> Int -> IO Socket.Socket
connectHost host port = do
  let hints = Socket.defaultHints {Socket.addrSocketType = Socket.Stream}
  addrs <- Socket.getAddrInfo (Just hints) (Just (Text.unpack host)) (Just (show port))
  s <- connectFirst addrs
  Socket.setSocketOption s Socket.NoDelay 1
  pure s

-- | A websocket client over a connected socket, with the Host header
-- websockets' runClient sends. It does not close the socket.
websocketOver :: Socket.Socket -> Text -> Int -> Text -> WS.ClientApp a -> IO a
websocketOver s host port path =
  WS.runClientWithSocket s hostHeader (Text.unpack path) WS.defaultConnectionOptions []
  where
    hostHeader
      | port == 80 = Text.unpack host
      | otherwise = Text.unpack host <> ":" <> show port
