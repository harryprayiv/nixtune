-- | The order in which the shell changes a room's outputs.
--
-- MPD cannot release the DAC while its ALSA output is enabled and
-- playing, and the player cannot open the DAC until MPD has. So every
-- change that takes the DAC away from MPD disables the ALSA output before
-- any player is held, and every change that gives it back releases the
-- player before the ALSA output is enabled. 'plan' produces that order;
-- the shell runs the actions one at a time and waits for each.
module Nixtune.Room.Outputs
  ( Action (..)
  , plan
  )
where

import Nixtune.Room.Name (RoomName)
import Nixtune.Room.State (Holder (..), Outputs (..), Path (..))

data Action
  = EnableFifo
  | DisableFifo
  | EnableAlsa
  | DisableAlsa
  | -- | This room's server holds this room's player.
    HoldOwnPlayer
  | -- | This room's server lets this room's player go.
    ReleaseOwnPlayer
  | -- | Ask the named room's server to hold this room's player.
    AskHold RoomName
  | -- | Ask the named room's server to let this room's player go.
    AskRelease RoomName
  | -- | Tell the named room's server that this room is interrupted: it
    -- lets the player go but keeps this room in its audience.
    AskSuspend RoomName
  deriving stock (Eq, Show)

-- | From the outputs a room has to the outputs it should have.
plan :: (Path, Outputs) -> (Path, Outputs) -> [Action]
plan (_oldPath, old) (newPath, new) =
  concat
    [ [EnableFifo | fifoOutput new, not (fifoOutput old)]
    , [DisableAlsa | alsaOutput old, not (alsaOutput new)]
    , releaseOld
    , acquireNew
    , [EnableAlsa | alsaOutput new, not (alsaOutput old)]
    , [DisableFifo | fifoOutput old, not (fifoOutput new)]
    ]
  where
    interrupted = case newPath of
      Interrupted _ -> True
      _ -> False

    changed = player old /= player new

    -- A new holder displaces the old one by Sendspin's multiple-server
    -- rule, so an explicit release is needed only when nothing of ours
    -- takes the player, or when a source must be told this room is
    -- interrupted rather than gone.
    releaseOld
      | not changed = []
      | otherwise = case (player old, player new) of
          (Just (ByPeer r), _) | interrupted -> [AskSuspend r]
          (Just (ByPeer r), Nothing) -> [AskRelease r]
          (Just BySelf, Nothing) -> [ReleaseOwnPlayer]
          _ -> []

    acquireNew
      | not changed = []
      | otherwise = case player new of
          Just BySelf -> [HoldOwnPlayer]
          Just (ByPeer r) -> [AskHold r]
          Just ByInterrupter -> []
          Nothing -> []
