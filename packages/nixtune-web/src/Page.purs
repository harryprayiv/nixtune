-- | Everything the page draws. No effects here: each function is state
-- | in, markup out, and every button names an Action for Main to handle.
module Page where

import Prelude

import Art (artUrl)
import Browse
  ( Axis
  , ColRow(..)
  , activeAxis
  , alphabet
  , axisLabel
  , columnOf
  , heldTo
  , initialOf
  , letterRailThreshold
  , lettersPresent
  , pluralOf
  , rowAt
  , rowCount
  , rowHeight
  , shownAxes
  , sliceFor
  , tagOf
  , topRow
  , trackCombos
  , trackHeight
  , trackScope
  , tracksTotal
  )
import Caps (Station)
import Data.Array (elem, length, null, take, (:))
import Data.Array as Array
import Data.Foldable (lookup)
import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.String (Pattern(..), joinWith, split)
import Data.Tuple (Tuple(..))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Elements.Keyed as HK
import Halogen.HTML.Properties as HP
import Mpd (Entry(..), PlayState(..), Quality(..), Song)
import Mpd as Mpd
import Reorder (rowRef, rowShift)
import Types
  ( Action(..)
  , BrowseMode(..)
  , Role(..)
  , State
  , View(..)
  , colRef
  , isStream
  , partyOn
  , searchLimit
  , tracksRef
  , vetoLimit
  , votersAgainst
  )
import Ui (classes, cls, iconSized)
import Volume (playerBar)
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

-- | What a file is, in three or four letters, coloured by whether it
-- | keeps every sample. Nothing at all for a stream or an extension the
-- | page does not recognise: a blank says less than a wrong guess.
formatBadge :: forall w i. String -> HH.HTML w i
formatBadge file = case Mpd.fileFormat file of
  Nothing -> HH.text ""
  Just f ->
    HH.span
      [ classes [ "fmt", if f.quality == Lossless then "lossless" else "lossy" ]
      , HP.title (if f.quality == Lossless then f.label <> ", lossless" else f.label <> ", lossy")
      ]
      [ HH.text f.label ]

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
      , if st.status.duration > 0.0 then progress st else HH.text ""
      ]
  ]
    <>
      -- Transport is not here any more: it lives in the bar at the
      -- bottom of every view (Volume.playerBar). What stays is Stop,
      -- which belongs with the modes rather than with the three buttons
      -- a thumb reaches for, and the four MPD playback modes.
      ( if st.role == Host then
          [ HH.div [ cls "modes" ]
              [ toggle "Random" st.status.random ("random " <> flag st.status.random)
              , toggle "Repeat" st.status.repeat ("repeat " <> flag st.status.repeat)
              , toggle "Single" st.status.single ("single " <> flag st.status.single)
              , toggle "Consume" st.status.consume ("consume " <> flag st.status.consume)
              , HH.button [ cls "mode", HP.title "Stop", HE.onClick \_ -> Command "stop" ] [ HH.text "Stop" ]
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

-- | Elapsed, the bar, and the length. For the host the bar seeks: the
-- | drag is held in seekDraft so the one-second tick does not move the
-- | thumb under the finger, and the position is sent once, on release.
progress :: forall m. State -> H.ComponentHTML Action () m
progress st =
  HH.div [ cls "progress" ]
    [ HH.span_ [ HH.text (Mpd.clock at) ]
    , if st.role == Host then
        HH.div [ cls "seek" ]
          [ HH.input
              [ HP.type_ HP.InputRange
              , HP.min 0.0
              , HP.max s.duration
              , HP.step (HP.Step 1.0)
              , HP.value (show (Int.round at))
              , HP.style ("--pct:" <> show pct <> "%")
              , HP.title "Seek"
              , HE.onValueInput DragSeek
              , HE.onValueChange CommitSeek
              ]
          ]
      else
        HH.div [ cls "bar" ]
          [ HH.div [ cls "fill", HP.style ("width:" <> show pct <> "%") ] [] ]
    , HH.span_ [ HH.text (Mpd.clock s.duration) ]
    ]
  where
  s = st.status
  at = fromMaybe s.elapsed st.seekDraft
  pct = if s.duration > 0.0 then clamp 0.0 100.0 (at / s.duration * 100.0) else 0.0

queueView :: forall m. State -> Array (H.ComponentHTML Action () m)
queueView st =
  [ if st.role == Host then
      HH.div [ cls "row-actions" ]
        [ HH.button [ HP.disabled (null st.queue), HE.onClick \_ -> Command "clear" ] [ HH.text "Clear queue" ] ]
    else if partyOn st then
      HH.p [ cls "note" ]
        [ HH.text ("Vote a track off and it goes when " <> show (vetoLimit st) <> " people agree. One vote each.") ]
    else HH.text ""
  , if null st.queue then HH.p [ cls "empty" ] [ HH.text "The queue is empty. Add something from the library or pick a station." ]
    else HH.ul [ classes ([ "list" ] <> (if isJust st.drag then [ "dragging" ] else [])) ] (Array.mapWithIndex item st.queue)
  ]
  where
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

-- | The search row and the mode switch share one line where there is
-- | room, so the browser under them gets the height instead.
libraryView :: forall m. State -> Array (H.ComponentHTML Action () m)
libraryView st =
  [ HH.div [ cls "libtop" ]
      ( [ HH.form [ cls "search", HE.onSubmit Search ]
            [ HH.input
                [ HP.type_ HP.InputSearch
                , HP.placeholder "Search artists, albums, titles"
                , HP.value st.query
                , HE.onValueInput SetQuery
                ]
            , HH.button [ HP.type_ HP.ButtonSubmit ] [ HH.text "Search" ]
            ]
        ]
          <> (if isJust st.searched then [] else [ modeSwitch st ])
      )
  , scanBanner st
  ]
    <> case st.searched of
      -- A search result is a flat list either way, so it replaces both
      -- the tag browser and the folder tree while it is on screen.
      Just q ->
        [ HH.div [ cls "crumbs" ]
            [ HH.span [ cls "crumb-static" ]
                [ HH.text
                    ( "Results for \"" <> q <> "\""
                        <> (if length st.entries >= searchLimit then " (first " <> show searchLimit <> ")" else "")
                    )
                ]
            , HH.button [ cls "crumb", HE.onClick \_ -> SetMode st.mode ] [ HH.text "✕ clear search" ]
            ]
        , if null st.entries then HH.p [ cls "empty" ] [ HH.text emptyText ]
          else HH.ul [ cls "list" ] (map (entryRow st) st.entries)
        ]
      Nothing -> case st.mode of
        Tags -> tagBrowser st
        Folders -> folderView st
  where
  emptyText =
    if st.status.updating then "Nothing yet. The library is still being scanned; try again later."
    else "Nothing matches."

-- | How the library is being looked at, and whether the genre column is
-- | part of the chain. The genre column is off by default: this library
-- | has seven hundred and sixty five distinct genre strings, most of
-- | them spellings of each other, and a column of that many values is
-- | not a way of choosing anything. It is there for when the question
-- | really is "what reggae do I have".
modeSwitch :: forall m. State -> H.ComponentHTML Action () m
modeSwitch st =
  HH.div [ cls "modeswitch" ]
    [ HH.div [ cls "seg" ]
        [ seg Tags "Artists"
        , seg Folders "Folders"
        ]
    , case st.mode of
        Tags ->
          HH.button
            [ classes ([ "mode" ] <> (if st.browser.genreColumn then [ "on" ] else []))
            , HP.title "Add a genre column to the left of the artists"
            , HE.onClick \_ -> ToggleGenreColumn
            ]
            [ HH.text "Genre" ]
        Folders -> HH.text ""
    , HH.div [ cls "grow-space" ] []
    , if st.role == Host then
        HH.button
          [ cls "ghost"
          , HP.disabled st.status.updating
          , HE.onClick \_ -> UpdateLibrary
          ]
          [ HH.text (if st.status.updating then "Scanning…" else "Rescan") ]
      else HH.text ""
    ]
  where
  seg m label =
    HH.button
      [ classes ([ "segbtn" ] <> (if st.mode == m then [ "on" ] else []))
      , HE.onClick \_ -> SetMode m
      ]
      [ HH.text label ]

-- | The folder tree, which is what MPD indexes and the fourth way in.
folderView :: forall m. State -> Array (H.ComponentHTML Action () m)
folderView st =
  [ HH.div [ cls "crumbs" ] (crumb "" "Library" : Array.mapWithIndex part parts)
  , if st.path == "" then HH.text ""
    else HH.div [ cls "row-actions" ]
      ( [ HH.button [ HE.onClick \_ -> AddPath st.path ] [ HH.text "Add all" ] ]
          <>
            ( if st.role == Host then
                [ HH.button [ cls "primary", HE.onClick \_ -> PlayPath st.path ] [ HH.text "Play all" ] ]
              else []
            )
      )
  , if null st.entries then HH.p [ cls "empty" ] [ HH.text emptyText ]
    else HH.ul [ cls "list" ] (map (entryRow st) st.entries)
  ]
  where
  parts = if st.path == "" then [] else split (Pattern "/") st.path
  part i name = crumb (joinWith "/" (take (i + 1) parts)) name
  crumb target label =
    HH.button [ cls "crumb", HE.onClick \_ -> Browse target ] [ HH.text label ]
  emptyText =
    if st.status.updating then "Nothing here yet. The library is still being scanned."
    else "Nothing here. If the library is empty, the NAS may not be mounted yet."

entryRow :: forall m. State -> Entry -> H.ComponentHTML Action () m
entryRow st = case _ of
  Dir d ->
    HH.li [ cls "dir" ]
      [ HH.button [ cls "grow", HE.onClick \_ -> Browse d ]
          [ HH.span [ cls "rowicon" ] [ iconSized "sm" "folder" ], HH.text (Mpd.basename d) ]
      , HH.button [ cls "ghost icon-btn", HP.title "Add this folder", HE.onClick \_ -> AddPath d ] [ iconSized "sm" "plus" ]
      ]
  Playlist p ->
    if st.role == Host then
      HH.li [ cls "dir" ]
        [ HH.button [ cls "grow", HE.onClick \_ -> Command ("load " <> Mpd.quote p) ]
            [ HH.span [ cls "rowicon" ] [ iconSized "sm" "list" ], HH.text p ]
        ]
    else HH.text ""
  File s -> songRow s

-- | One track, in a search result, a folder listing or the tag browser.
-- |
-- | Both roles get the same thing: a plus, which appends. There is no
-- | play button on a track row for either of them. This list is the
-- | quickest way to build up a queue, and a control that throws away
-- | what has been built so far does not belong in it. The row itself
-- | appends too, so the whole width is the target.
songRow :: forall m. Song -> H.ComponentHTML Action () m
songRow s =
  HH.li [ cls "song" ]
    [ HH.button [ cls "grow", HP.title "Add to the queue", HE.onClick \_ -> AddPath s.file ]
        [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
        , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
        ]
    , formatBadge s.file
    , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
    , HH.button
        [ cls "ghost icon-btn"
        , HP.title "Add to the queue"
        , HE.onClick \_ -> AddPath s.file
        ]
        [ iconSized "sm" "plus" ]
    ]

-- | The tag browser: a chain of columns, each one narrowed by the
-- | selection to its left, with the tracks they narrow to underneath.
-- | One flex column so the columns and the list below them divide the
-- | height that is actually there, rather than each stopping at a figure
-- | picked in advance.
-- |
-- | The columns are KEYED by axis. Without keys the renderer patches
-- | children by position, so switching the genre column on turns the
-- | element that was the artist column into the genre column, and the
-- | renderer never re-registers a ref whose label changed on a patched
-- | element. Every scroll aimed at the artist column then lands on the
-- | genre column, which is the jump to the top this browser used to do
-- | whenever a genre was clicked.
tagBrowser :: forall m. State -> Array (H.ComponentHTML Action () m)
tagBrowser st =
  [ HH.div [ cls "browser" ]
      ( [ tagCrumbs st
        , HK.div [ cls "columns" ] (map (\a -> Tuple (tagOf a) (tagColumn st a)) (shownAxes st.browser))
        ]
          <> trackList st
      )
  ]

-- | The choices already made, as chips that clear them. Drawn only when
-- | the columns are stacked, because side by side each column shows its
-- | own selection and this would say it twice.
tagCrumbs :: forall m. State -> H.ComponentHTML Action () m
tagCrumbs st =
  if null chips then HH.text ""
  else HH.div [ cls "tagcrumbs" ] chips
  where
  chips = Array.mapMaybe chip (shownAxes st.browser)
  chip axis = case (columnOf axis st.browser).selected of
    [] -> Nothing
    [ v ] -> Just (button axis v)
    vs -> Just (button axis (show (length vs) <> " " <> pluralOf axis))
  button axis label =
    HH.button
      [ cls "crumb"
      , HP.title ("Back to all " <> pluralOf axis)
      , HE.onClick \_ -> ClearColumn axis
      ]
      [ HH.text ("‹ " <> label) ]

-- | One column: its name and count in the head, the All row and the
-- | values in a scroller, and a letter rail beside a long list.
tagColumn :: forall m. State -> Axis -> H.ComponentHTML Action () m
tagColumn st axis =
  HH.div [ classes ([ "col" ] <> (if activeAxis br == axis then [ "cur" ] else [])) ]
    [ HH.div [ cls "colhead" ]
        [ HH.span [ cls "colname" ] [ HH.text (axisLabel axis) ]
        , if col.pending > 0 && not (null col.values) then HH.span [ cls "spin" ] [] else HH.text ""
        , HH.span [ cls "count" ] [ HH.text countText ]
        ]
    , HH.div [ cls "colbody" ]
        [ HH.ul
            [ cls "vals"
            , HP.ref (colRef axis)
            -- Every scroll says where the column is now; Tags turns
            -- that into the slice below and nothing else happens
            -- unless the slice actually moved.
            , HE.handler (EventType "scroll") (Scrolled axis)
            ]
            body
        , if length col.values > letterRailThreshold then rail else HH.text ""
        ]
    ]
  where
  br = st.browser
  col = columnOf axis br
  total = rowCount col
  -- The slice that is on screen. The whole column is still there as far
  -- as the scrollbar and the scroll position are concerned: the rows
  -- that are not drawn are stood in for by two blank rows of exactly
  -- their height, one above and one below. Both are always present,
  -- even at zero height, so every row keeps its place among the
  -- element's children from one render to the next.
  slice = sliceFor col.vp rowHeight total
  rows = if slice.count <= 0 then [] else Array.mapMaybe (rowAt col) (Array.range slice.first (slice.first + slice.count - 1))
  spacer n =
    HH.li [ cls "spacer", HP.style ("height:" <> show (toNumber (max 0 n) * rowHeight) <> "px") ] []

  -- The count says how many of how many once some are picked, because
  -- the number that matters then is the size of the selection.
  countText = case length col.selected of
    0 -> show (length col.values)
    n -> show n <> " of " <> show (length col.values)
  body
    | null col.values && col.pending > 0 = [ HH.li [ cls "val empty" ] [ HH.span [ cls "spin" ] [], HH.text " Loading" ] ]
    | null col.values = [ HH.li [ cls "val empty" ] [ HH.text "Nothing here" ] ]
    | otherwise = [ spacer slice.first ] <> map row rows <> [ spacer (total - slice.first - length rows) ]
  -- The All row is selected exactly when nothing else is, which is what
  -- the iTunes browser shows and the reason the column is never without
  -- a highlighted row.
  row AllRow =
    HH.li [ classes ([ "val", "all" ] <> (if null col.selected then [ "on" ] else [])) ]
      [ HH.button
          [ cls "grow"
          , HP.title ("Every " <> axisLabel axis)
          , HE.onClick \_ -> ClearColumn axis
          ]
          [ HH.text ("All (" <> show (length col.values) <> " " <> pluralOf axis <> ")") ]
      ]
  row (ValueRow v) =
    HH.li [ classes ([ "val" ] <> (if elem v col.selected then [ "on" ] else [])) ]
      [ HH.button
          [ cls "grow"
          -- A row is one line of a fixed height, which is what the slice
          -- arithmetic above depends on, so a long name is cut and kept
          -- here in full.
          , HP.title v
          -- Shift extends from the anchor, the platform's modifier adds
          -- or removes one row, a plain click replaces the selection.
          , HE.onClick (Choose axis v)
          ]
          [ HH.text v ]
      ]
  -- The letter the column is sitting on, which is the one the rail
  -- marks. It follows the scroll rather than being a thing you set.
  atLetter = case rowAt col (topRow col.vp rowHeight) of
    Just (ValueRow v) -> Just (initialOf v)
    _ -> Nothing
  present = lettersPresent col
  rail = HH.div [ cls "rail" ] (map letterButton alphabet)
  letterButton l =
    HH.button
      [ classes (if atLetter == Just l then [ "on" ] else [])
      , HP.disabled (not (elem l present))
      , HP.title ("Scroll to " <> l)
      -- The rail scrolls the column. Nothing is filtered and nothing is
      -- hidden: the whole list is there to scroll through, and this is
      -- the shortcut for not doing that over ten thousand names.
      , HE.onClick \_ -> JumpTo axis l
      ]
      [ HH.text l ]

-- | The tracks the columns narrow to. With nothing picked that is the
-- | whole library, so this is a filter and never a gate: the list is
-- | always there and each column only makes it smaller.
-- |
-- | Only the pages that have been scrolled to are held, and only the
-- | rows in view are drawn, so seventy thousand songs cost one request
-- | of two hundred and a screenful of elements.
trackList :: forall m. State -> Array (H.ComponentHTML Action () m)
trackList st =
  [ HH.div [ cls "row-actions trackhead" ]
      ( [ HH.span [ cls "crumb-static" ] [ HH.text (trackScope br) ]
        , HH.span [ cls "count" ] [ HH.text (show total <> " songs") ]
        , HH.div [ cls "grow-space" ] []
        ]
          <> bulk
      )
  , HH.ul
      [ cls "list tracks"
      , HP.ref tracksRef
      , HE.handler (EventType "scroll") ScrolledTracks
      ]
      body
  ]
  where
  br = st.browser
  t = br.tracks
  total = tracksTotal t
  -- Add and Play act on the whole filter rather than on the rows that
  -- happen to be loaded, so queueing four artists does not stop at two
  -- hundred tracks. With nothing selected there is no filter and the
  -- buttons would mean "the entire library", which nobody wants by
  -- accident, so they are not offered.
  bulk =
    if total == 0 || Array.null (trackCombos br) then []
    else
      [ HH.button [ HE.onClick \_ -> AddFilter ] [ HH.text "Add these" ] ]
        <>
          ( if st.role == Host then
              [ HH.button [ cls "primary", HE.onClick \_ -> PlayFilter ] [ HH.text "Play these" ] ]
            else []
          )

  -- The window of rows to draw, in the whole result's numbering, cut
  -- down to the run actually held. Anything outside it is spacing, so
  -- a scrollbar dragged ahead of the fetch shows empty space of the
  -- right size rather than the wrong rows.
  slice = sliceFor t.vp trackHeight total
  from = max t.from slice.first
  to = min (heldTo t) (slice.first + slice.count)
  shown = if to <= from then [] else Array.slice (from - t.from) (to - t.from) t.rows
  drawnFrom = if Array.null shown then 0 else from
  spacer n =
    HH.li [ cls "spacer", HP.style ("height:" <> show (toNumber (max 0 n) * trackHeight) <> "px") ] []

  body
    | total == 0 && t.pending =
        [ HH.li [ cls "val empty" ] [ HH.span [ cls "spin" ] [], HH.text " Loading" ] ]
    | total == 0 =
        [ HH.li [ cls "val empty" ] [ HH.text "Nothing matches." ] ]
    | otherwise =
        [ spacer drawnFrom ]
          <> map songRow shown
          -- The gap below stands in for everything past what has been
          -- fetched as well as for what is simply not drawn, so the
          -- scrollbar is the real length of the result from the start.
          <> [ spacer (total - drawnFrom - length shown) ]

-- | What the library is doing, said plainly above the listing.
scanBanner :: forall w i. State -> HH.HTML w i
scanBanner st =
  if st.status.updating then
    HH.div [ cls "scan" ]
      [ HH.span [ cls "spin" ] []
      , HH.span_ [ HH.text ("Scanning the library: " <> show st.songs <> " songs so far. Folders already read are browsable below; the count refreshes every ten seconds.") ]
      ]
  else if st.songs == 0 then
    HH.div [ cls "scan idle" ]
      [ HH.span_ [ HH.text "The library has not been scanned. The first scan starts two minutes after boot; if the NAS was down then, the host can start it with Rescan library." ] ]
  else HH.text ""

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