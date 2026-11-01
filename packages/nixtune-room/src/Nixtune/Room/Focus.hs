-- | Acoustic alignment for a focus room (M14 in nixtune-multiroom.allium).
--
-- For focus f, member r gets
--
-- > outputDelay r + (A - travel f r)
--
-- where travel f r is the time sound takes from r's speakers to the
-- listening spot in f, and A is the largest travel f x over the members.
-- The farthest audible room gets no added delay and the focus room gets
-- the most, so every speaker's sound reaches the listener together. A
-- room with no declared travel from f is treated as if it were f.
module Nixtune.Room.Focus
  ( Acoustics
  , chooseFocus
  , alignedDelays
  , maxOutputDelay
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Nixtune.Room.Clock (Millis (..))
import Nixtune.Room.Name (RoomName)

-- | acoustics.<focus>.<room>, in milliseconds, as declared in Nix.
type Acoustics = Map RoomName (Map RoomName Millis)

-- | Sendspin's limit on output_delay_ms.
maxOutputDelay :: Millis
maxOutputDelay = Millis 5000

-- | The pinned room when it is a member; otherwise this room when it is
-- listening to its own server; otherwise the first member by name.
chooseFocus :: RoomName -> Maybe RoomName -> Set RoomName -> Maybe RoomName
chooseFocus selfName pinned ms
  | Just p <- pinned, p `Set.member` ms = Just p
  | selfName `Set.member` ms = Just selfName
  | otherwise = Set.lookupMin ms

alignedDelays ::
  -- | Each room's declared outputDelay.
  Map RoomName Millis ->
  Acoustics ->
  RoomName ->
  Set RoomName ->
  Map RoomName Millis
alignedDelays base acoustics focus ms = Map.fromSet delay ms
  where
    fromFocus = Map.findWithDefault Map.empty focus acoustics
    ownTravel = Map.findWithDefault (Millis 0) focus fromFocus
    travel r = Map.findWithDefault ownTravel r fromFocus
    longest = maximum (Millis 0 : map travel (Set.toList ms))
    delay r =
      let Millis b = Map.findWithDefault (Millis 0) r base
          Millis a = longest
          Millis t = travel r
       in clamp (Millis (b + a - t))
    clamp (Millis n) = let Millis hi = maxOutputDelay in Millis (max 0 (min hi n))
