-- | The host's player: the track's position, the transport and the
-- | level, in one frame pinned to the bottom of every view.
-- |
-- | The position used to sit on the Now playing card and the transport in
-- | this bar, so the one thing a person reaches for while listening was
-- | split across the screen with empty space between the halves. All of
-- | it belongs to the player rather than to any one view, so all of it is
-- | here: a seek row on top, the transport and the level under it.
-- |
-- | Crowding is handled with a budget rather than a compromise. At phone
-- | width the bar carries the seek row, previous, play/pause, next, mute
-- | and the level slider. The typed level field and the steppers appear
-- | at 30rem and up (index.html). Nothing is dropped at any width: the
-- | two controls that fold away are the two with keyboard and gesture
-- | equivalents.
-- |
-- | The level slider is a range input, so a drag, a tap and the arrow
-- | keys all work with no geometry arithmetic and no FFI. What broke the
-- | first version was its placement: the hit area began at the edge of
-- | the mute button, and the left edge of a range input is its minimum,
-- | so a thumb aimed at mute and landing a few pixels right silenced the
-- | room. Its minimum is volumeFloor rather than zero, zero belongs to
-- | the mute button alone, and the track is drawn from a CSS custom
-- | property set here so the fill always matches the thumb.
module Player
  ( playerBar
  , seekRow
  ) where

import Prelude

import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Mpd (PlayState(..))
import Mpd as Mpd
import Types
  ( Action(..)
  , Role(..)
  , State
  , isStream
  , maxVolumeOf
  , shownVolume
  , volumeFloor
  , volumeStep
  )
import Ui (classes, cls, icon, iconSized)
import Web.UIEvent.KeyboardEvent as KE

playerBar :: forall m. State -> H.ComponentHTML Action () m
playerBar st =
  HH.div [ cls "playerbar" ]
    [ seekRow st
    , HH.div [ cls "barrow" ]
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
            <> volumeGroup st
        )
    ]
  where
  playPause = case st.status.state of
    Playing -> "pause 1"
    Paused -> "pause 0"
    Stopped -> "play"
  playGlyph = if st.status.state == Playing then "pause" else "play"
  playTitle = if st.status.state == Playing then "Pause" else "Play"

-- | Elapsed, the bar, and the length. For the host the bar seeks: the
-- | drag is held in seekDraft so the one-second tick does not move the
-- | thumb under the finger, and the position is sent once, on release.
-- | For a guest it is a plain bar on the Now playing card.
-- |
-- | The row is always drawn, with nothing to seek when nothing is
-- | playing, so the bar keeps one height and the view above it never
-- | jumps when a track starts. A stream has no length: its elapsed time
-- | counts up and the right-hand label says so.
seekRow :: forall m. State -> H.ComponentHTML Action () m
seekRow st =
  HH.div [ cls "progress" ]
    [ HH.span [ cls "clock" ] [ HH.text (Mpd.clock at) ]
    , if st.role == Host then
        HH.div [ cls "seek" ]
          [ HH.input
              [ HP.type_ HP.InputRange
              , HP.min 0.0
              , HP.max (if seekable then s.duration else 1.0)
              , HP.step (HP.Step 1.0)
              , HP.value (show (Int.round (if seekable then at else 0.0)))
              , HP.style ("--pct:" <> show pct <> "%")
              , HP.title "Seek"
              , HP.disabled (not seekable)
              , HE.onValueInput DragSeek
              , HE.onValueChange CommitSeek
              ]
          ]
      else
        HH.div [ cls "bar" ]
          [ HH.div [ cls "fill", HP.style ("width:" <> show pct <> "%") ] [] ]
    , HH.span [ cls "clock" ] [ HH.text right ]
    ]
  where
  s = st.status
  seekable = s.duration > 0.0 && s.state /= Stopped
  at = if s.state == Stopped then 0.0 else fromMaybe s.elapsed st.seekDraft
  pct = if seekable then clamp 0.0 100.0 (at / s.duration * 100.0) else 0.0
  streaming = case st.current of
    Just c -> isStream c.file
    Nothing -> false
  right
    | seekable = Mpd.clock s.duration
    | streaming && s.state /= Stopped = "live"
    | otherwise = Mpd.clock 0.0

-- | The level. A host with no mixer at all (the null output profile)
-- | gets the transport and nothing else, rather than a dead slider.
volumeGroup :: forall m. State -> Array (H.ComponentHTML Action () m)
volumeGroup st = case shownVolume st of
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
  where
  top = maxVolumeOf st
  span = top - volumeFloor