-- | The level: how a change is applied, and the bar that asks for one.
-- |
-- | A press or a drag sets a target and the level walks to it a few units
-- | at a time rather than jumping. Where each write goes depends on the
-- | host: a socket to the amixer helper when capabilities.json names one,
-- | MPD's own setvol otherwise. The level the page SHOWS always comes
-- | back from MPD, which reports the mixer whoever moved it, so AirPlay
-- | and a knob on the amplifier show up here too.
module Volume where

import Prelude

import Data.Int (toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Mpd (PlayState(..))
import Net (send)
import Types
  ( Action(..)
  , Conn(..)
  , M
  , Req(..)
  , State
  , maxVolumeOf
  , shownVolume
  , volumeFloor
  , volumeGlideMs
  , volumeGlideStep
  , volumeStep
  )
import Ui (classes, cls, icon, iconSized)
import Web.Socket.WebSocket as WS
import Web.UIEvent.KeyboardEvent as KE

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

-- | The host's player: transport and level, in one frame pinned to the
-- | bottom of every view.
-- |
-- | Transport used to live on the Now playing view, which meant that
-- | browsing a library this size with music on offered no way to skip a
-- | track without leaving the browse. Both belong to the player rather
-- | than to any one view, so both are here.
-- |
-- | Crowding is handled with a budget rather than a compromise. At phone
-- | width the bar carries previous, play/pause, next, mute and the
-- | slider. The typed level field and the steppers appear at 30rem and
-- | up (index.html). Nothing is dropped at any width: the two controls
-- | that fold away are the two with keyboard and gesture equivalents.
-- |
-- | The slider is a range input, so a drag, a tap and the arrow keys all
-- | work with no geometry arithmetic and no FFI. What broke the first
-- | version was its placement: the hit area began at the edge of the
-- | mute button, and the left edge of a range input is its minimum, so a
-- | thumb aimed at mute and landing a few pixels right silenced the
-- | room. Its minimum is volumeFloor rather than zero, zero belongs to
-- | the mute button alone, and the track is drawn from a CSS custom
-- | property set here so the fill always matches the thumb.
playerBar :: forall m. State -> H.ComponentHTML Action () m
playerBar st =
  HH.div [ cls "playerbar" ]
    ( [ HH.div [ cls "transport" ]
          [ HH.button
              [ cls "tr"
              , HP.title "Previous"
              , HE.onClick \_ -> Command "previous"
              ]
              [ iconSized "sm" "prev" ]
          , HH.button
              [ cls "tr play"
              , HP.title playTitle
              , HE.onClick \_ -> Command playPause
              ]
              [ icon playGlyph ]
          , HH.button
              [ cls "tr"
              , HP.title "Next"
              , HE.onClick \_ -> Command "next"
              ]
              [ iconSized "sm" "next" ]
          ]
      ]
        <> volumeGroup
    )
  where
  playPause = case st.status.state of
    Playing -> "pause 1"
    Paused -> "pause 0"
    Stopped -> "play"
  playGlyph = if st.status.state == Playing then "pause" else "play"
  playTitle = if st.status.state == Playing then "Pause" else "Play"

  top = maxVolumeOf st
  span = top - volumeFloor

  -- A host with no mixer at all (the null output profile) gets the
  -- transport and nothing else, rather than a dead slider.
  volumeGroup = case shownVolume st of
    Nothing -> []
    Just v ->
      let
        pct =
          if span > 0 then clamp 0.0 100.0 (toNumber (max volumeFloor v - volumeFloor) / toNumber span * 100.0)
          else 0.0
      in
        [ HH.button
            [ classes ([ "mute" ] <> (if v == 0 then [ "on" ] else []))
            , HP.title (if v == 0 then "Unmute" else "Mute")
            , HE.onClick \_ -> ToggleMute
            ]
            [ icon (if v == 0 then "mute" else "vol") ]
        , HH.div [ cls "track" ]
            [ HH.input
                [ HP.type_ HP.InputRange
                , HP.min (toNumber volumeFloor)
                , HP.max (toNumber top)
                , HP.step (HP.Step 1.0)
                , HP.value (show (max volumeFloor v))
                , HP.style ("--pct:" <> show pct <> "%")
                , HP.title "Volume"
                , HE.onValueInput SetVolume
                ]
            ]
        , HH.input
            [ cls "level"
            , HP.type_ HP.InputNumber
            , HP.min 0.0
            , HP.max (toNumber top)
            , HP.step (HP.Step 1.0)
            -- While the field has focus it shows what is being typed, so
            -- a report from MPD landing between keystrokes cannot
            -- rewrite it.
            , HP.value (fromMaybe (show v) st.volText)
            , HP.title "Type a level"
            , HE.onFocus \_ -> VolumeFocus
            , HE.onValueInput VolumeText
            , HE.onKeyDown (KE.key >>> VolumeKey)
            , HE.onBlur \_ -> CommitVolume
            ]
        , HH.div [ cls "steps" ]
            [ HH.button
                [ HP.title ("Louder by " <> show volumeStep)
                , HP.disabled (v >= top)
                , HE.onClick \_ -> Nudge volumeStep
                ]
                [ iconSized "sm" "plus" ]
            , HH.button
                [ HP.title ("Quieter by " <> show volumeStep)
                , HP.disabled (v <= volumeFloor)
                , HE.onClick \_ -> Nudge (negate volumeStep)
                ]
                [ iconSized "sm" "minus" ]
            ]
        ]
