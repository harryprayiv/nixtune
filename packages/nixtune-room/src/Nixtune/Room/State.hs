-- | One room's state, and everything derived from it.
--
-- The coordinator stores only facts it owns or has observed: its intent,
-- the members of its audience, whether it is interrupted, its pin, and
-- what MPD last said. The audio path, the MPD output switches and who
-- holds the player are functions of those facts ('path', 'outputs'), not
-- fields, so they cannot disagree with them. That is how the Room
-- entity's invariants in nixtune-multiroom.allium (AlsaOutputOnlyWhenDirect,
-- HeldByMatchesPath, SourceOnlyWhenFollowing) hold by construction.
module Nixtune.Room.State
  ( Intent (..)
  , Member (..)
  , Resumption (..)
  , Interruption (..)
  , PendingFollow (..)
  , RoomState (..)
  , Path (..)
  , Holder (..)
  , Outputs (..)
  , initialState
  , path
  , outputs
  , streaming
  , heldMembers
  , currentSource
  , isInterrupted
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Nixtune.Room.Clock (Instant, Millis)
import Nixtune.Room.Name (RoomName)
import Nixtune.Room.Protocol (Interrupter (..), ReplyTo)

-- | The one fact a room's coordinator writes about its own speaker. A
-- following room names its source inside the constructor, so a source
-- exists exactly when the room is following.
data Intent
  = Own
  | Following RoomName
  | Silent
  deriving stock (Eq, Show)

-- | A peer in this room's audience.
data Member
  = -- | Asked to be held; its player has not reported available yet. The
    -- reply goes out when it does, or a refusal at the deadline.
    Joining Instant ReplyTo
  | Held
  | -- | Interrupted in its own room since the instant given, and coming
    -- back. It keeps the source streaming but takes no part in focus.
    Suspended Instant
  deriving stock (Eq, Show)

-- | What an interruption saved, to put back when it ends.
data Resumption = Resumption
  { resumeIntent :: Intent
  , resumeMpdPlaying :: Bool
  -- ^ Only ever True for a room that was playing alone, which is the
  -- only case where the interruption paused MPD.
  }
  deriving stock (Eq, Show)

data Interruption = Interruption
  { interruptedBy :: Interrupter
  , resumption :: Resumption
  }
  deriving stock (Eq, Show)

-- | A follow request whose source has not answered yet.
data PendingFollow = PendingFollow
  { pendingReply :: ReplyTo
  , pendingTarget :: RoomName
  , pendingPrevious :: Intent
  }
  deriving stock (Eq, Show)

data RoomState = RoomState
  { self :: RoomName
  , intent :: Intent
  , members :: Map RoomName Member
  , audienceEmptySince :: Maybe Instant
  -- ^ Set when the last member leaves; while set, the room keeps
  -- streaming for the audience grace period.
  , interruption :: Maybe Interruption
  , pin :: Maybe RoomName
  , mpdPlaying :: Bool
  -- ^ As MPD last reported it. MPD is the truth.
  , sourceUnreachableSince :: Maybe Instant
  , pendingFollow :: Maybe PendingFollow
  , appliedDelays :: Map RoomName Millis
  -- ^ The output delays this room's server last sent its players.
  }
  deriving stock (Eq, Show)

-- | RoomBoots.
initialState :: RoomName -> RoomState
initialState name =
  RoomState
    { self = name
    , intent = Own
    , members = Map.empty
    , audienceEmptySince = Nothing
    , interruption = Nothing
    , pin = Nothing
    , mpdPlaying = False
    , sourceUnreachableSince = Nothing
    , pendingFollow = Nothing
    , appliedDelays = Map.empty
    }

-- | What feeds the DAC.
data Path
  = -- | MPD's ALSA output, bit-perfect, as nixtune does with multiroom off.
    Direct
  | -- | This room's player, held by this room's own server.
    OwnServer
  | -- | This room's player, held by the named room's server.
    PeerServer RoomName
  | -- | Nothing; this room's MPD still feeds its audience.
    Off
  | Interrupted Interrupter
  deriving stock (Eq, Show)

-- | Whether this room's server is feeding anyone, or is within the grace
-- period after the last member left.
streaming :: RoomState -> Bool
streaming st = not (Map.null (members st)) || isJust (audienceEmptySince st)

isInterrupted :: RoomState -> Bool
isInterrupted = isJust . interruption

currentSource :: RoomState -> Maybe RoomName
currentSource st = case intent st of
  Following r -> Just r
  _ -> Nothing

-- | Members whose players this room's server holds right now.
heldMembers :: RoomState -> Set RoomName
heldMembers = Map.keysSet . Map.filter (== Held) . members

path :: RoomState -> Path
path st = case interruption st of
  Just i -> Interrupted (interruptedBy i)
  Nothing -> case intent st of
    Own
      | streaming st -> OwnServer
      | otherwise -> Direct
    Following r -> PeerServer r
    Silent -> Off

-- | Who holds this room's player.
data Holder
  = BySelf
  | ByPeer RoomName
  | -- | A declared foreign Sendspin server, which took it on its own.
    ByInterrupter
  deriving stock (Eq, Show)

-- | The switches the shell makes true: MPD's ALSA output, MPD's
-- multiroom fifo output, and the holder of this room's player.
data Outputs = Outputs
  { alsaOutput :: Bool
  , fifoOutput :: Bool
  , player :: Maybe Holder
  }
  deriving stock (Eq, Show)

outputs :: RoomState -> Outputs
outputs st =
  Outputs
    { alsaOutput = p == Direct
    , fifoOutput = streaming st
    , player = case p of
        OwnServer -> Just BySelf
        PeerServer r -> Just (ByPeer r)
        Interrupted ForeignSendspin -> Just ByInterrupter
        Interrupted _ -> Nothing
        Direct -> Nothing
        Off -> Nothing
    }
  where
    p = path st
