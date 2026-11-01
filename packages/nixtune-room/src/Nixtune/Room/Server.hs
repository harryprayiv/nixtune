-- | What the coordinator needs from the room's Sendspin server. Stage 3
-- implements it; until then 'unbuiltServer' logs every call and holds no
-- player, so a hold is refused player-not-ready at its deadline, which is
-- the truth about a room with no server.
module Nixtune.Room.Server
  ( SendspinServer (..)
  , unbuiltServer
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Nixtune.Room.Clock (Millis)
import Nixtune.Room.Name (RoomName, roomNameText)

-- | The server reports back through the coordinator's events
-- (PlayerAvailable, PlayerGone); these are the calls into it.
data SendspinServer = SendspinServer
  { serverHold :: RoomName -> IO ()
  -- ^ Connect to that room's player and take it for playback.
  , serverRelease :: RoomName -> IO ()
  , serverHoldOwn :: IO ()
  -- ^ Take this room's own player.
  , serverReleaseOwn :: IO ()
  , serverSetDelays :: Map RoomName Millis -> IO ()
  , serverFlushAndSeekBack :: IO ()
  }

unbuiltServer :: (Text -> IO ()) -> SendspinServer
unbuiltServer logLine =
  SendspinServer
    { serverHold = \r -> logLine ("sendspin server not built yet: hold " <> roomNameText r)
    , serverRelease = \r -> logLine ("sendspin server not built yet: release " <> roomNameText r)
    , serverHoldOwn = logLine "sendspin server not built yet: hold own player"
    , serverReleaseOwn = logLine "sendspin server not built yet: release own player"
    , serverSetDelays = \m -> logLine ("sendspin server not built yet: delays " <> Text.pack (show m))
    , serverFlushAndSeekBack = logLine "sendspin server not built yet: flush"
    }