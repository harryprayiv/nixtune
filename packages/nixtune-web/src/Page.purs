-- | Everything the page draws apart from the Library view, which is in
-- | Library. No effects here: each function is state in, markup out, and
-- | every button names an Action for Main to handle.
module Page where

import Prelude

import Art (artUrl)
import Caps (Station)
import Data.Array (elem, length, null)
import Data.Array as Array
import Data.Foldable (lookup)
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.String (joinWith)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Library (libraryView)
import Mpd (PlayState(..))
import Mpd as Mpd
import Player (playerBar, seekRow)
import PlaylistView as PlaylistView
import Reorder (rowRef, rowShift)
import Types
  ( Action(..)
  , QueuePane(..)
  , Role(..)
  , State
  , View(..)
  , isStream
  , partyOn
  , vetoLimit
  , votersAgainst
  )
import Ui (classes, cls, formatBadge, iconSized)
import Web.Event.Event (EventType(..))

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.main_
  [ HH.header [ cls "top" ]
      [ HH.div [ cls "brand" ]
          [ HH.span [ classes [ "dot", if online then "on" else "off" ] ] []
          , HH.span_ [ HH.text "nixtune" ]
          , HH.span [ cls "host" ] [ HH.text (maybe "" _.hostname st.caps) ]
          ]
      , HH.div [ cls "badges" ]
          ( map badge renderers
              <> [ HH.span [ classes ([ "badge" ] <> (if st.status.updating then [ "scanning" ] else [])) ]
                     [ HH.text (show st.songs <> " songs" <> (if st.status.updating then " · scanning" else "")) ]
                 ]
          )
      ]
  , HH.nav [ cls "tabs" ] tabs
  , HH.section [ cls "page" ] $ case st.view of
      NowPlaying -> nowPlaying st
      Queue -> queueView st
      Library -> libraryView st
      Radio -> radioView stations
      Qr -> qrView st
  , errorView st.error
  , if st.role == Host then playerBar st else HH.footer [ cls "me" ] [ HH.text ("you are " <> st.nickname) ]
  ]
  where
  online = maybe false _.ready st.cmd
  renderers = Array.filter (_ /= "mpd") (maybe [] _.modules st.caps)
  hasLibrary = maybe false _.library st.caps
  stations = maybe [] _.stations st.caps
  -- From `status`, not from the page's copy of the queue: the queue
  -- itself is only fetched while the Queue view is open.
  count = if st.status.queueLength == 0 then "" else " (" <> show st.status.queueLength <> ")"
  tabs = case st.role of
    Guest ->
      [ tab NowPlaying "Now playing" ]
        -- In party mode a guest sees the queue, so there is something to
        -- vote against.
        <> (if partyOn st then [ tab Queue ("Queue" <> count) ] else [])
        <> (if hasLibrary then [ tab Library "Library" ] else [])
    Host ->
      [ tab NowPlaying "Now playing", tab Queue ("Queue" <> count) ]
        <> (if hasLibrary then [ tab Library "Library" ] else [])
        <> (if null stations then [] else [ tab Radio "Radio" ])
        <> [ tab Qr "QR" ]
  tab v label =
    HH.button
      [ classes ([ "tab" ] <> (if st.view == v then [ "current" ] else []))
      , HE.onClick \_ -> Open v
      ]
      [ HH.text label ]

badge :: forall w i. String -> HH.HTML w i
badge m = HH.span [ cls "badge" ] [ HH.text (badgeName m) ]

badgeName :: String -> String
badgeName = case _ of
  "airplay" -> "AirPlay"
  "upnp_renderer" -> "UPnP"
  "spotify_connect" -> "Spotify"
  "squeezelite" -> "Squeezelite"
  "bluetooth" -> "Bluetooth"
  other -> other

whoAdded :: State -> String -> Maybe String
whoAdded st uri = lookup uri st.addedBy

-- | What the DAC is being fed, while something plays: the file's format,
-- | then the depth and rate the decoder is producing, then the bit rate
-- | for a stream, which is the only figure a stream has.
qualityBadges :: forall w i. State -> Array (HH.HTML w i)
qualityBadges st = case st.current of
  Nothing -> []
  Just song ->
    [ formatBadge song.file ]
      <> maybe [] (\r -> [ HH.span [ cls "fmt rate" ] [ HH.text r ] ]) rate
      <> maybe [] (\b -> [ HH.span [ cls "fmt rate" ] [ HH.text (show b <> " kbps") ] ]) kbps
  where
  rate = st.status.audio >>= Mpd.streamFormat
  -- Printed for a stream, where there is no file to name and no fixed
  -- depth; for a local file the depth and rate above say more.
  kbps = case st.current of
    Just s | isStream s.file -> st.status.bitrate
    _ -> Nothing

nowPlaying :: forall m. State -> Array (H.ComponentHTML Action () m)
nowPlaying st =
  [ HH.div [ classes ([ "now" ] <> (if isJust (artUrl st) then [ "withart" ] else [])) ]
      [ case artUrl st of
          Just url ->
            HH.img
              [ cls "art"
              , HP.src url
              , HP.alt ""
              , HE.onError \_ -> ArtMissing
              ]
          Nothing -> HH.text ""
      , HH.div [ cls "meta" ]
          [ HH.div [ cls "title" ] [ HH.text (maybe "Nothing queued" Mpd.songTitle st.current) ]
          , HH.div [ cls "line" ] [ HH.text (maybe "" Mpd.songLine st.current) ]
          , case qualityBadges st of
              [] -> HH.text ""
              bs -> HH.div [ cls "fmts" ] bs
          , case st.current >>= \s -> whoAdded st s.file of
              Just who -> HH.div [ cls "added" ] [ HH.text ("added by " <> who) ]
              Nothing -> HH.text ""
          ]
      -- The host's position is in the player bar under every view, with
      -- the transport it belongs with. A guest has no bar, so a guest's
      -- card keeps a plain progress line.
      , if st.role == Guest && st.status.duration > 0.0 then seekRow st else HH.text ""
      ]
  ]
    <>
      -- The transport and the position live in the bar at the bottom of
      -- every view (Player.playerBar). Here are the four MPD playback
      -- modes and Clear, which is the queue-wide action a host reaches
      -- for from this view. There is no Stop: pause does what a person
      -- means by it, and the bar has pause.
      ( if st.role == Host then
          [ HH.div [ cls "modes" ]
              [ toggle "Random" st.status.random ("random " <> flag st.status.random)
              , toggle "Repeat" st.status.repeat ("repeat " <> flag st.status.repeat)
              , toggle "Single" st.status.single ("single " <> flag st.status.single)
              , toggle "Consume" st.status.consume ("consume " <> flag st.status.consume)
              , clearButton st
              ]
          ]
        else
          [ HH.p [ cls "note" ] [ HH.text stateLine ] ]
      )
  where
  flag b = if b then "0" else "1"
  stateLine = case st.status.state of
    Playing -> "Playing. Add something from the library and it joins the queue."
    Paused -> "Paused by the host."
    Stopped -> "Nothing playing. The first thing you add starts it."
  toggle label on command =
    HH.button
      [ classes ([ "mode" ] <> (if on then [ "on" ] else []))
      , HE.onClick \_ -> Command command
      ]
      [ HH.text label ]

-- | Clear the queue, in two presses. MPD has no undo for `clear`, and a
-- | queue a room spent an evening building is one stray tap from gone, so
-- | the first press arms the button and says so, and only a second press
-- | within a few seconds clears.
clearButton :: forall m. State -> H.ComponentHTML Action () m
clearButton st =
  HH.button
    [ classes ([ "mode", "clear" ] <> (if armed then [ "armed" ] else []))
    , HP.disabled (st.status.queueLength == 0)
    , HP.title (if armed then "Press again to clear the queue" else "Clear the queue")
    , HE.onClick \_ -> ClearQueue
    ]
    [ HH.text (if armed then "Press again to clear" else "Clear queue") ]
  where
  armed = isJust st.clearArmed

-- | The Queue view. The host's has two panes: the queue, with the
-- | YouTube field and the save-as field above it, and the playlists saved
-- | on the player, one of which can be open for editing (PlaylistView). A
-- | guest's is the queue alone, and only in party mode.
queueView :: forall m. State -> Array (H.ComponentHTML Action () m)
queueView st = case st.role, st.pane of
  Host, PaneSaved -> [ PlaylistView.paneSwitch st [] ] <> PlaylistView.savedView st
  Host, PaneEdit name -> [ PlaylistView.paneSwitch st [] ] <> PlaylistView.editView st name
  Host, PaneQueue ->
    [ PlaylistView.paneSwitch st [ clearButton st ] ]
      <> youtubeForm st
      <> PlaylistView.saveForm st
      <> [ queueList ]
  Guest, _ ->
    [ if partyOn st then
        HH.p [ cls "note" ]
          [ HH.text ("Vote a track off and it goes when " <> show (vetoLimit st) <> " people agree. One vote each.") ]
      else HH.text ""
    , queueList
    ]
  where
  queueList =
    if null st.queue then HH.p [ cls "empty" ] [ HH.text "The queue is empty. Add something from the library or pick a station." ]
    else HH.ul [ classes ([ "list" ] <> (if isJust st.drag then [ "dragging" ] else [])) ] (Array.mapWithIndex item st.queue)
  -- Where the player is. Everything before it has been played, which is
  -- what dims those rows; with random on the order is not the order they
  -- were heard in, so nothing is dimmed.
  playing = st.status.song
  held = map _.from st.drag
  item i s =
    HH.li
      ( [ HP.ref (rowRef i)
        , classes
            ( [ "song" ]
                <> (if Just pos == playing then [ "current" ] else [])
                <> (if not st.status.random && playing /= Nothing && Just pos < playing then [ "past" ] else [])
                <> (if held == Just i then [ "held" ] else [])
            )
        ]
          -- The style is left off entirely for a row that is not moving,
          -- which is almost all of them: a pointer event redraws the whole
          -- list, and a queue of a few hundred makes the difference between
          -- one attribute to compare per row and none worth having.
          <> ( case rowShift st.drag i of
                 0.0 -> []
                 dy -> [ HP.style ("transform: translateY(" <> show dy <> "px)") ]
             )
      )
      ( ( if st.role == Host then
            [ HH.button
                [ cls "grip"
                , HP.title "Drag to reorder, or focus and use the arrow keys"
                , HE.handler (EventType "pointerdown") (GrabRow i)
                , HE.onKeyDown (GripKey pos)
                ]
                [ iconSized "sm" "grip" ]
            ]
          else []
        )
          <> [ rowBody, formatBadge s.file, HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ] ]
          <> (if partyOn st then [ vetoButton st s ] else [])
          <>
            ( if st.role == Host then
                [ HH.button [ cls "ghost icon-btn", HP.title "Remove", HE.onClick \_ -> DeletePos pos ] [ iconSized "sm" "x" ] ]
              else []
            )
      )
    where
    -- The queue arrives in order, so the index is the position. Pos from
    -- MPD is used when it is there and the index covers a reply that
    -- left it out.
    pos = fromMaybe i s.pos
    rowBody =
      if st.role == Host then HH.button [ cls "grow", HE.onClick \_ -> PlayPos pos ] rowInner
      else HH.div [ cls "grow" ] rowInner
    rowInner =
      [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
      , HH.div [ cls "line" ]
          [ HH.text
              ( joinWith " · "
                  (Array.filter (_ /= "") [ Mpd.songLine s, maybe "" (\w -> "added by " <> w) (whoAdded st s.file) ])
              )
          ]
      ]

-- | A YouTube video or playlist link to fetch into the library and queue,
-- | on the host page of a host built with services.nixtune.youtube. The
-- | field stays as typed while the request runs and empties once anything
-- | from it is queued; the line under it is the last thing the helper
-- | said.
youtubeForm :: forall m. State -> Array (H.ComponentHTML Action () m)
youtubeForm st =
  if st.role /= Host || isNothing (st.caps >>= _.youtubePath) then []
  else
    [ HH.div [ cls "libtop" ]
        [ HH.form [ cls "search", HE.onSubmit YtSubmit ]
            [ HH.input
                [ HP.type_ HP.InputUrl
                , HP.placeholder "YouTube video or playlist link to add to the queue"
                , HP.value st.ytText
                , HP.disabled st.ytBusy
                , HE.onValueInput YtText
                ]
            , HH.button
                [ HP.type_ HP.ButtonSubmit
                , HP.disabled (st.ytBusy || st.ytText == "" || not (maybe false _.ready st.ytLink))
                ]
                [ HH.text (if st.ytBusy then "Fetching…" else "Fetch") ]
            ]
        ]
    ]
      <> maybe [] (\note -> [ HH.p [ cls "note" ] [ HH.text note ] ]) st.ytNote

-- | The veto button and its tally. One vote per browser: a browser that
-- | has already voted sees the count and a disabled button, because the
-- | honest thing to show is that its vote is in, not a button that does
-- | nothing.
vetoButton :: forall m. State -> Mpd.Song -> H.ComponentHTML Action () m
vetoButton st s =
  HH.button
    [ classes ([ "veto" ] <> (if mine then [ "mine" ] else []) <> (if cast > 0 then [ "some" ] else []))
    , HP.disabled mine
    , HP.title title
    , HE.onClick \_ -> Veto s.file s.id
    ]
    [ iconSized "sm" "down", HH.span_ [ HH.text (show cast <> "/" <> show limit) ] ]
  where
  voters = votersAgainst st s.file
  cast = length voters
  limit = vetoLimit st
  mine = elem st.nickname voters
  title =
    if mine then "You voted against this: " <> show cast <> " of " <> show limit
    else "Vote against this track"

radioView :: forall m. Array Station -> Array (H.ComponentHTML Action () m)
radioView stations =
  [ HH.ul [ cls "list" ] (map station stations) ]
  where
  station s =
    HH.li [ cls "song" ]
      [ HH.button [ cls "grow", HE.onClick \_ -> PlayStation s ]
          [ HH.div [ cls "title" ] [ HH.text s.name ]
          , HH.div [ cls "line" ] [ HH.text s.url ]
          ]
      ]

qrView :: forall m. State -> Array (H.ComponentHTML Action () m)
qrView st =
  [ HH.div [ cls "qr" ]
      [ HH.img [ HP.src "qr.svg", HP.alt "QR code for the guest page" ]
      , HH.p [ cls "url" ] [ HH.text (maybe "" _.publicUrl st.caps) ]
      , HH.p [ cls "note" ] [ HH.text "Anyone who scans this gets the guest page: now playing, and the library to add from." ]
      ]
  ]

errorView :: forall w i. Maybe String -> HH.HTML w i
errorView = case _ of
  Just e -> HH.p [ cls "error" ] [ HH.text e ]
  Nothing -> HH.text ""