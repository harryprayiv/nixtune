-- | The level: how a change is applied. The bar that asks for one is in
-- | Player.
-- |
-- | A press or a drag sets a target and the level walks to it a few units
-- | at a time rather than jumping. Where each write goes depends on the
-- | host: a socket to the amixer helper when capabilities.json names one,
-- | MPD's own setvol otherwise. The level the page SHOWS always comes
-- | back from MPD, which reports the mixer whoever moved it, so AirPlay
-- | and a knob on the amplifier show up here too.
module Volume where

import Prelude

import Data.Maybe (Maybe(..), fromMaybe)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Net (send)
import Types (Conn(..), M, Req(..), volumeGlideMs, volumeGlideStep)
import Web.Socket.WebSocket as WS

-- | Ask for a level. The bar reports every pixel of a drag, so the value
-- | is held in the state and the sender below decides what is written.
setVolume :: forall o m. MonadAff m => Int -> M o m Unit
setVolume v = do
  H.modify_ _ { volDraft = Just v }
  busy <- H.gets _.volSending
  unless busy do
    H.modify_ _ { volSending = true }
    void (H.fork sendVolume)

-- | Walk the level toward the target one step at a time until it arrives.
-- | The step is proportional to what is left, so the move starts quickly
-- | and settles softly, with a floor of one so it always finishes. The
-- | draft is not cleared here: it stands until MPD reports the level
-- | back (see reply RStatus), so the thumb never falls back for a frame.
sendVolume :: forall o m. MonadAff m => M o m Unit
sendVolume = do
  st <- H.get
  case st.volDraft of
    Nothing -> H.modify_ _ { volSending = false }
    Just target -> do
      let
        now = fromMaybe (fromMaybe target st.status.volume) st.volSent
      if now == target then H.modify_ _ { volSending = false }
      else do
        let
          gap = target - now
          step = clamp 1 volumeGlideStep ((if gap < 0 then negate gap else gap) / 3)
          next = if gap > 0 then min target (now + step) else max target (now - step)
        writeVolume next
        H.modify_ _ { volSent = Just next }
        H.liftAff (delay (Milliseconds volumeGlideMs))
        sendVolume

-- | One level, to whichever thing on this host can actually apply it.
writeVolume :: forall o m. MonadAff m => Int -> M o m Unit
writeVolume v = do
  st <- H.get
  case st.volLink of
    Just k | k.ready -> liftEffect (WS.sendString k.socket ("set " <> show v))
    _ -> case st.caps >>= _.volumePath of
      -- A host with a helper and no connection to it says so and writes
      -- nothing. Falling back to setvol here would mute the card, which
      -- is the whole reason the helper exists.
      Just _ -> H.modify_ _ { error = Just "The volume control is not reachable; the level was not changed." }
      Nothing -> send Cmd RFire ("setvol " <> show v)