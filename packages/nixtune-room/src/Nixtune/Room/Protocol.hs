-- | What pages, peers and hooks ask a coordinator, and how it answers.
-- These are the requests of the Coordinator contract in
-- nixtune-multiroom.allium; the wire encoding comes in a later stage.
module Nixtune.Room.Protocol
  ( ReplyTo (..)
  , Request (..)
  , Refusal (..)
  , Interrupter (..)
  )
where

import Nixtune.Room.Name (RoomName)

-- | Identifies the connection and request a reply belongs to. The shell
-- assigns these; the core only hands them back.
newtype ReplyTo = ReplyTo Int
  deriving stock (Eq, Ord, Show)

-- | What can take a room's speaker away from its group for a while.
data Interrupter
  = AirPlay
  | Upnp
  | ForeignSendspin
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Request
  = -- | This room's speaker should play that room's server.
    ReqFollow RoomName
  | -- | This room's speaker should play this room's MPD.
    ReqOwn
  | -- | This room's speaker should play nothing.
    ReqSilence
  | -- | A peer asks this room's server to hold its player.
    ReqHold RoomName
  | -- | A peer asks this room's server to let its player go.
    ReqRelease RoomName
  | -- | A peer that follows this room has been interrupted; keep its
    -- place in the audience.
    ReqSuspend RoomName
  | -- | Pin the acoustic focus of this room's group to a room.
    ReqPin RoomName
  | ReqUnpin
  | ReqInterruptionStarts Interrupter
  | ReqInterruptionEnds Interrupter
  deriving stock (Eq, Show)

data Refusal
  = UnknownRoom
  | IsSelf
  | RoomInterrupted
  | Busy
  | PlayerNotReady
  | SourceUnreachable
  deriving stock (Eq, Ord, Show, Enum, Bounded)
