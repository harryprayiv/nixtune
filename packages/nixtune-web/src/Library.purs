-- | The Library view: the search box, the tag browser, its track list,
-- | and the folder tree. Like Page, state in and markup out, with every
-- | control naming an Action for Main to handle.
module Library
  ( libraryView
  ) where

import Prelude

import Browse
  ( Axis
  , ColRow(..)
  , Tracks
  , activeAxis
  , axisLabel
  , columnOf
  , hasRail
  , heldTo
  , isPicked
  , letterAt
  , lettersPresent
  , pickedCount
  , pluralOf
  , railLetters
  , rowAt
  , rowCount
  , rowHeight
  , shownAxes
  , sliceFor
  , tagOf
  , trackFilter
  , trackHeight
  , trackScope
  )
import Data.Array (elem, length, null, take, (:))
import Data.Array as Array
import Data.Int (toNumber)
import Data.Maybe (Maybe(..), isJust, isNothing, maybe)
import Data.String (Pattern(..), joinWith, split)
import Data.Tuple (Tuple(..))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Elements.Keyed as HK
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Mpd (Entry(..), Song)
import Mpd as Mpd
import Types (Action(..), BrowseMode(..), Role(..), State, colRef, tracksRef)
import Ui (classes, cls, formatBadge, iconSized)
import Web.Event.Event (EventType(..))

-- | The search row and the mode switch share one line where there is
-- | room, so the browser under them gets the height instead.
-- |
-- | The search box filters: as it is typed, every column and the track
-- | list narrow to what matches, and browsing carries on inside the
-- | result. It is applied after a pause in typing, or at once on Enter.
libraryView :: forall m. State -> Array (H.ComponentHTML Action () m)
libraryView st =
  [ HH.div [ cls "libtop" ]
      [ HH.form [ cls "search", HE.onSubmit Search ]
          ( [ HH.input
                [ HP.type_ HP.InputSearch
                , HP.placeholder "Filter by artist, album, title"
                , HP.value st.query
                , HE.onValueInput SetQuery
                ]
            ]
              <>
                ( if st.query == "" && isNothing st.browser.query then []
                  else [ HH.button [ HP.type_ HP.ButtonButton, HP.title "Clear the filter", HE.onClick \_ -> ClearQuery ] [ HH.text "Clear" ] ]
                )
          )
      , modeSwitch st
      ]
  , scanBanner st
  ]
    <> case st.mode of
      Tags -> tagBrowser st
      Folders -> folderView st

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

-- | The folder tree, which is what MPD indexes.
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
    else HH.ul [ cls "list" ] (map entryRow st.entries)
  ]
  where
  parts = if st.path == "" then [] else split (Pattern "/") st.path
  part i name = crumb (joinWith "/" (take (i + 1) parts)) name
  crumb target label =
    HH.button [ cls "crumb", HE.onClick \_ -> Browse target ] [ HH.text label ]
  emptyText =
    if st.status.updating then "Nothing here yet. The library is still being scanned."
    else "Nothing here. If the library is empty, the NAS may not be mounted yet."

entryRow :: forall m. Entry -> H.ComponentHTML Action () m
entryRow = case _ of
  Dir d ->
    HH.li [ cls "dir" ]
      [ HH.button [ cls "grow", HE.onClick \_ -> Browse d ]
          [ HH.span [ cls "rowicon" ] [ iconSized "sm" "folder" ], HH.text (Mpd.basename d) ]
      , HH.button [ cls "ghost icon-btn", HP.title "Add this folder", HE.onClick \_ -> AddPath d ] [ iconSized "sm" "plus" ]
      ]
  -- A playlist file found in the library: written by some other program
  -- years ago, naming paths that were true for that program. MPD indexes
  -- them because the m3u plugin is on for nixtune's own playlists (see
  -- database.nix), and the page leaves them out. The playlists worth
  -- loading are the saved ones, on the Queue view.
  Playlist _ -> HH.text ""
  File s -> songRow s

-- | One track in a folder listing.
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
-- | genre column.
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
        , if col.pending && not (null col.values) then HH.span [ cls "spin" ] [] else HH.text ""
        , HH.span [ cls "count" ] [ HH.text countText ]
        ]
    , HH.div [ cls "colbody" ]
        [ HH.ul
            [ cls "vals"
            , HP.ref (colRef axis)
            -- The row height the slice arithmetic uses, handed to the
            -- stylesheet, so a row is drawn exactly as tall as it is
            -- counted.
            , HP.style (rowVar rowHeight)
            -- Every scroll says where the column is now; Tags turns
            -- that into the slice below and nothing else happens
            -- unless the slice actually moved.
            , HE.handler (EventType "scroll") (Scrolled axis)
            ]
            body
        , if hasRail col then rail else HH.text ""
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
    | null col.values && col.pending = [ HH.li [ cls "val empty" ] [ HH.span [ cls "spin" ] [], HH.text " Loading" ] ]
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
    HH.li [ classes ([ "val" ] <> (if elem v.display col.selected then [ "on" ] else [])) ]
      [ HH.button
          [ cls "grow"
          -- A row is one line of a fixed height, which is what the slice
          -- arithmetic above depends on, so a long name is cut and kept
          -- here in full.
          , HP.title (v.display <> maybe "" (\y -> " (" <> show y <> ")") v.year)
          -- Shift extends from the anchor, the platform's modifier adds
          -- or removes one row, a plain click replaces the selection.
          , HE.onClick (Choose axis v.display)
          ]
          ( case v.year of
              Just y | col.byYear -> [ HH.span [ cls "year" ] [ HH.text (show y) ], HH.text (" " <> v.display) ]
              _ -> [ HH.text v.display ]
          )
      ]
  -- The letter the column is sitting on, which is the one the rail
  -- marks. It follows the scroll rather than being a thing you set.
  atLetter = letterAt shownLetters col
  present = lettersPresent shownLetters col
  -- As many letters as the column's measured height has room for, and
  -- their count handed to the stylesheet so the type is sized to share
  -- the height between exactly those.
  shownLetters = railLetters col
  rail =
    HH.div [ cls "rail", HP.style ("--letters:" <> show (length shownLetters)) ]
      (map letterButton shownLetters)
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

-- | One track in the tag browser's list, where a row is a thing to pick
-- | as well as a thing to queue.
-- |
-- | The body of the row selects: plain picks it alone, the platform's
-- | modifier adds or removes it, shift takes the run from the last row
-- | picked. The plus at the end still queues that one track on its own,
-- | so the quickest path to a queue is unchanged and the slower path of
-- | gathering a few tracks and queueing them together exists beside it.
trackRow :: forall m. Tracks -> Int -> Song -> H.ComponentHTML Action () m
trackRow t row s =
  HH.li [ classes ([ "song" ] <> (if on then [ "picked" ] else [])) ]
    [ HH.button
        [ cls "grow"
        , HP.title "Click to select, ctrl or cmd click to add to the selection, shift click for a run"
        , HE.onClick (ChooseTrack row)
        ]
        [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
        , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
        ]
    , formatBadge s.file
    , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
    , HH.button
        [ cls "ghost icon-btn"
        , HP.title "Add this track to the queue"
        , HE.onClick \_ -> AddPath s.file
        ]
        [ iconSized "sm" "plus" ]
    ]
  where
  on = isPicked t s

-- | The tracks the columns and the search narrow to. With nothing chosen
-- | that is the whole library, so this is a filter and never a gate: the
-- | list is always there and each choice only makes it smaller.
-- |
-- | Only the pages that have been scrolled to are held, and only the
-- | rows in view are drawn, so seventy thousand songs cost one request
-- | of two hundred and a screenful of elements.
trackList :: forall m. State -> Array (H.ComponentHTML Action () m)
trackList st =
  [ HH.div [ cls "row-actions trackhead" ]
      ( [ HH.span [ cls "crumb-static" ] [ HH.text (trackScope br) ]
        , HH.span [ cls "count" ]
            [ HH.text (if picked > 0 then show picked <> " of " <> show total <> " selected" else show total <> " songs") ]
        , HH.div [ cls "grow-space" ] []
        ]
          <> bulk
      )
  , HH.ul
      [ cls "list tracks"
      , HP.ref tracksRef
      , HP.style (rowVar trackHeight)
      , HE.handler (EventType "scroll") ScrolledTracks
      ]
      body
  ]
  where
  br = st.browser
  t = br.tracks
  total = t.total
  -- With rows picked the buttons act on exactly those. With none they
  -- act on the whole filter rather than on the rows that happen to be
  -- loaded, so queueing four artists does not stop at two hundred
  -- tracks. With nothing picked and no filter they would mean "the
  -- entire library", which nobody wants by accident, so they are not
  -- offered at all.
  picked = pickedCount t
  bulk
    | picked > 0 =
        [ HH.button [ cls "ghost", HP.title "Clear the selection", HE.onClick \_ -> ClearTracks ] [ HH.text "Clear" ]
        , HH.button [ HE.onClick \_ -> AddFilter ] [ HH.text ("Add " <> show picked) ]
        ]
          <>
            ( if st.role == Host then
                [ HH.button [ cls "primary", HE.onClick \_ -> PlayFilter ] [ HH.text ("Play " <> show picked) ] ]
              else []
            )
    | total == 0 || not (isJust (trackFilter br)) = []
    | otherwise =
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
        [ HH.li [ cls "val empty" ] [ HH.text emptyText ] ]
    | otherwise =
        [ spacer drawnFrom ]
          <> Array.mapWithIndex (\i -> trackRow t (drawnFrom + i)) shown
          -- The gap below stands in for everything past what has been
          -- fetched as well as for what is simply not drawn, so the
          -- scrollbar is the real length of the result from the start.
          <> [ spacer (total - drawnFrom - length shown) ]
  emptyText =
    if st.status.updating then "Nothing yet. The library is still being scanned."
    else "Nothing matches."

-- | A list's row height as the CSS custom property its rows are sized
-- | by. The constants live in Browse, where the slice arithmetic reads
-- | them; index.html only ever says var(--row).
rowVar :: Number -> String
rowVar h = "--row:" <> show h <> "px"

-- | What the library is doing, said plainly above the listing.
scanBanner :: forall w i. State -> HH.HTML w i
scanBanner st =
  if st.status.updating then
    HH.div [ cls "scan" ]
      [ HH.span [ cls "spin" ] []
      , HH.span_ [ HH.text ("Scanning the library: " <> show st.songs <> " songs so far. Everything already read is browsable below; the counts refresh every ten seconds.") ]
      ]
  else if st.songs == 0 then
    HH.div [ cls "scan idle" ]
      [ HH.span_ [ HH.text ("The library has not been scanned. The first scan starts two minutes after boot; if the NAS was down then, the host can start it with Rescan.") ]
      ]
  else HH.text ""