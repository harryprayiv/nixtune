-- | What the coordinator needs from the room's Sendspin server; the
-- server itself is "Nixtune.Sendspin.Server". The server reports back
-- through the coordinator's events (PlayerAvailable, PlayerGone).
module Nixtune.Room.Server
  ( SendspinServer (..)
  )
where

import Data.Map.Strict (Map)
import Nixtune.Room.Clock (Millis)
import Nixtune.Room.Name (RoomName)

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