-- | What a coordinator says about itself, built from its state alone, so
-- that @status@ never waits on anything (AnswersFromMemory).
module Nixtune.Room.Status
  ( statusOf
  , peerView
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nixtune.Room.Coordinator (PeerView (..), focusMembers)
import Nixtune.Room.Focus (chooseFocus)
import Nixtune.Room.State
import Nixtune.Room.Wire (WireStatus (..))

statusOf :: RoomState -> WireStatus
statusOf st =
  WireStatus
    { wsRoom = self st
    , wsIntent = case intent st of
        Own -> "own"
        Following _ -> "following"
        Silent -> "silent"
    , wsSource = currentSource st
    , -- Joining members are listed too, so a follower whose hold is
      -- still completing does not ask again.
      wsAudience = Map.keysSet (Map.filter (not . isSuspended) (members st))
    , wsSuspended = Map.keysSet (Map.filter isSuspended (members st))
    , wsMovedTo = Nothing
    , wsPath = case path st of
        Direct -> "direct"
        OwnServer -> "own-server"
        PeerServer _ -> "peer-server"
        Off -> "off"
        Interrupted _ -> "interrupted"
    , wsInterruptedBy = interruptedBy <$> interruption st
    , wsFocus =
        if streaming st then chooseFocus (self st) (pin st) (focusMembers st) else Nothing
    }
  where
    isSuspended (Suspended _) = True
    isSuspended _ = False

-- | What a follower's reconcile needs from its source's status. A
-- suspended member counts as listed: its place is kept.
peerView :: WireStatus -> PeerView
peerView s =
  PeerView
    { viewAudience = wsAudience s `Set.union` wsSuspended s
    , viewMovedTo = wsMovedTo s
    }