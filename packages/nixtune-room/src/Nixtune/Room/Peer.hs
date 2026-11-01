-- | Asking another room's coordinator something, over the same websocket
-- pages use (through the peer's nginx at /room). One connection per
-- request: a request is rare, and a fresh connection never carries state
-- from an earlier failure.
module Nixtune.Room.Peer
  ( PeerError (..)
  , describePeerError
  , ask
  , askStatus
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.WebSockets qualified as WS
import Nixtune.Room.Config (PeerConfig (..))
import Nixtune.Room.Protocol (Refusal, Request)
import Nixtune.Room.Sync (describe, trySync)
import Nixtune.Room.Wire (WireStatus, parseReply, parseStatus, renderRequest)
import System.Timeout (timeout)

data PeerError
  = Unreachable Text
  | TimedOut
  | Garbled Text
  deriving stock (Eq, Show)

describePeerError :: PeerError -> Text
describePeerError = \case
  Unreachable why -> "unreachable: " <> why
  TimedOut -> "timed out"
  Garbled line -> "answered with something that is not a reply: " <> line

exchange :: Int64 -> PeerConfig -> Text -> IO (Either PeerError Text)
exchange timeoutMs p line = do
  r <-
    timeout (fromIntegral timeoutMs * 1000) . trySync $
      WS.runClient (Text.unpack (peerHost p)) (peerPort p) (Text.unpack (peerPath p)) $ \conn -> do
        WS.sendTextData conn line
        answer <- WS.receiveData conn
        WS.sendClose conn ("done" :: Text)
        pure answer
  pure $ case r of
    Nothing -> Left TimedOut
    Just (Left e) -> Left (Unreachable (Text.pack (describe e)))
    Just (Right answer) -> Right answer

ask :: Int64 -> PeerConfig -> Request -> IO (Either PeerError (Either Refusal ()))
ask timeoutMs p req = do
  r <- exchange timeoutMs p (renderRequest req)
  pure (r >>= either (Left . Garbled) Right . parseReply)

askStatus :: Int64 -> PeerConfig -> IO (Either PeerError WireStatus)
askStatus timeoutMs p = do
  r <- exchange timeoutMs p "status"
  pure (r >>= either (Left . Garbled) Right . parseStatus)