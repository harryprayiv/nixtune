-- | The tag browser's behaviour: what a click does, what each column is
-- | asked for, how the replies are read, and where each list is
-- | scrolled to. Browse says what the browser is; this module performs
-- | it. Nothing here draws anything.
module Tags where

import Prelude

import Browse
  ( Axis
  , Browser
  , Column
  , TagValue
  , Tracks
  , activeAxis
  , cleared
  , columnOf
  , columnValues
  , firstUnder
  , heldTo
  , inListOrder
  , isPlain
  , listCommand
  , modifyColumn
  , orElse
  , pickedBy
  , rightOf
  , rowHeight
  , rowOfValue
  , selectionRow
  , shownAxes
  , spanBetween
  , tagOf
  , toggled
  , topRow
  , topValue
  , trackFilter
  , trackHeight
  , trackPage
  , yearOrdered
  )
import Cache as Cache
import Data.Array as Array
import Data.Foldable (for_)
import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Mpd as Mpd
import Net (busy, reopen, send)
import Types (BrowseMode(..), Conn(..), M, Req(..), View(..), colRef, tracksRef)
import Web.DOM.Element as Element
import Web.Event.Event (Event, target)
import Web.UIEvent.MouseEvent (MouseEvent)
import Web.UIEvent.MouseEvent as MouseEvent

-- ---------------------------------------------------------------------
-- State access

getBrowser :: forall o m. M o m Browser
getBrowser = H.gets _.browser

modifyBrowser :: forall o m. (Browser -> Browser) -> M o m Unit
modifyBrowser f = H.modify_ \st -> st { browser = f st.browser }

getColumn :: forall o m. Axis -> M o m Column
getColumn axis = H.gets (columnOf axis <<< _.browser)

modifyCol :: forall o m. Axis -> (Column -> Column) -> M o m Unit
modifyCol axis f = modifyBrowser (modifyColumn axis f)

getTracks :: forall o m. M o m Tracks
getTracks = H.gets _.browser.tracks

modifyTracks :: forall o m. (Tracks -> Tracks) -> M o m Unit
modifyTracks f = modifyBrowser \br -> br { tracks = f br.tracks }

-- ---------------------------------------------------------------------
-- Clicks

-- | A click on a value row. Plain replaces the column's selection with
-- | this one row and moves the anchor to it; shift extends from the
-- | anchor; the platform's own modifier adds or removes one row. All
-- | three are what the row would do in the iTunes column browser.
-- |
-- | More than one value in a column is one regular expression in the
-- | filter, so on an MPD without pcre the modifiers are ignored and every
-- | click is a plain one. The page does not fall back to one command per
-- | combination of values: that was the old design, and it could not be
-- | sorted as one list.
-- |
-- | The column that was clicked is not reloaded and not scrolled, so
-- | the row that was clicked stays exactly where it is. Everything to
-- | its right goes back to All and is asked for again.
choose :: forall o m. MonadAff m => Axis -> String -> MouseEvent -> M o m Unit
choose axis v ev = do
  br <- getBrowser
  let
    col = columnOf axis br
    shift = br.regex && MouseEvent.shiftKey ev
    extend = br.regex && (MouseEvent.ctrlKey ev || MouseEvent.metaKey ev)
    selected
      | shift = spanBetween (fromMaybe v col.anchor) v (map _.display col.values)
      | extend = toggled v col.selected
      | otherwise = [ v ]
    anchor = if shift then col.anchor `orElse` Just v else Just v
  modifyCol axis _ { selected = selected, anchor = anchor }
  unless (selected == col.selected) (narrow axis)

-- | The All row, or a chip on a phone: one column back to All, and so
-- | everything to its right as well.
clearColumn :: forall o m. MonadAff m => Axis -> M o m Unit
clearColumn axis = do
  col <- getColumn axis
  unless (Array.null col.selected) do
    modifyCol axis _ { selected = [], anchor = Nothing }
    narrow axis

-- | Drop whatever the library connection is still working on.
-- |
-- | MPD answers one command at a time per connection, in the order they
-- | arrived, and nothing cancels a command it has started. The
-- | whole-library listings take seconds on a library this size, so a
-- | click that lands while they are in flight would wait for all of them
-- | before the player so much as read it. Closing the socket throws that
-- | work away; what the click asks for goes out on a connection with
-- | nothing in front of it, and `send` holds those requests until the new
-- | socket has greeted.
cancelLibrary :: forall o m. MonadAff m => M o m Unit
cancelLibrary = do
  st <- H.get
  when (busy Lib st) do
    dropPending
    reopen Lib

-- | Reload everything one column's selection narrows: the columns to its
-- | right, which go back to All first, and the track list. Every column
-- | to the right is cleared before any of them is asked for, because
-- | what a column is asked for depends on the selection in every column
-- | to its left.
-- |
-- | Whatever the library connection was doing is thrown away first. It
-- | was answering a question about the selection that has just been
-- | replaced.
narrow :: forall o m. MonadAff m => Axis -> M o m Unit
narrow axis = do
  br <- getBrowser
  let
    right = rightOf axis br
  for_ right \a -> do
    modifyCol a cleared
    scrollColumn a 0.0
  cancelLibrary
  -- The list under the columns first: it is what the click was about,
  -- and the columns to the right are a smaller question that can wait
  -- the few milliseconds behind it.
  loadTracks
  for_ right loadColumn
  -- On a phone the column on screen may just have changed, and a column
  -- that was hidden has no measured height.
  measure

-- | The rail scrolls the column to where that letter starts. Nothing is
-- | filtered and nothing is hidden: the scroll position moves, the
-- | scroll event that follows recomputes the slice, and everything above
-- | and below is still there to scroll to.
jumpTo :: forall o m. MonadAff m => Axis -> String -> M o m Unit
jumpTo axis l = do
  col <- getColumn axis
  for_ (firstUnder l col) \r -> scrollColumn axis (toNumber r * rowHeight)

-- | The genre column in or out of the chain. Either way every selection
-- | goes, so no column is left narrowed by a column nobody can see, and
-- | every column on screen is asked for again. The whole-library lists
-- | come from the browser's store, so this is instant on a warm cache.
toggleGenreColumn :: forall o m. MonadAff m => M o m Unit
toggleGenreColumn = do
  modifyBrowser \br -> br
    { genreColumn = not br.genreColumn
    , genre = cleared br.genre
    , artist = br.artist { selected = [], anchor = Nothing }
    , album = br.album { selected = [], anchor = Nothing }
    }
  cancelLibrary
  reload
  sync

-- | A new search text, or none. It narrows every column and the list, so
-- | everything is asked for again; selections are kept, and a selection
-- | the narrowed column no longer holds is dropped when that column's
-- | reply lands, like any other selection that has gone. Typing in the
-- | folder view moves to the tag browser, because that is where a search
-- | shows its result.
commitQuery :: forall o m. MonadAff m => Maybe String -> M o m Unit
commitQuery q = do
  br <- getBrowser
  unless (q == br.query) do
    modifyBrowser _ { query = q }
    H.modify_ _ { mode = Tags }
    cancelLibrary
    reload
    sync

-- ---------------------------------------------------------------------
-- Loading columns

-- | Load every column on screen and the list under them, for whatever is
-- | selected now. A column keeps showing what it has until its new list
-- | is complete; the track list starts over.
-- |
-- | The order is the order they are wanted in, because the player works
-- | through one connection in the order it was asked. The column the
-- | next click will land in goes first; the track list, which with no
-- | selection is the whole library and the most expensive thing here,
-- | goes last.
reload :: forall o m. MonadAff m => M o m Unit
reload = do
  br <- getBrowser
  let
    first = activeAxis br
    rest = Array.filter (_ /= first) (shownAxes br)
  loadColumn first
  for_ rest loadColumn
  loadTracks

-- | Bring the columns and the count up to date without moving anything,
-- | which is what the ten-second tick does while a scan is running. The
-- | browser's store is bypassed: the database stamp does not move until
-- | the scan ends, and the point is to show what has been scanned so far.
recount :: forall o m. MonadAff m => M o m Unit
recount = do
  br <- getBrowser
  for_ (shownAxes br) (load false)
  for_ (trackFilter br) \f -> send Lib (RTrackCount br.tracks.gen) ("count " <> Mpd.quote f)

loadColumn :: forall o m. MonadAff m => Axis -> M o m Unit
loadColumn = load true

-- | One column, built from the selection to its left and the search.
-- |
-- | A column narrowed by nothing is one of the three whole-library
-- | lists, which is what the browser's store holds, so it is answered
-- | from there when the database has not moved since. Otherwise it is
-- | one `list` command, whatever is selected.
load :: forall o m. MonadAff m => Boolean -> Axis -> M o m Unit
load useCache axis = do
  st <- H.get
  let
    br = st.browser
  hit <-
    if useCache && isPlain axis br then liftEffect (Cache.read (tagOf axis) st.dbStamp)
    else pure Nothing
  case hit of
    Just values | not (Array.null values) -> arrive axis values false
    _ -> do
      let
        gen = (columnOf axis br).gen + 1
      modifyCol axis _ { gen = gen, pending = true, byYear = yearOrdered axis br }
      send Lib (RTagValues axis gen) (listCommand axis br)

-- | A column's reply. A reply from before the last click is thrown away
-- | rather than shown in a column it does not belong to.
tagValues :: forall o m. MonadAff m => Axis -> Int -> Array String -> M o m Unit
tagValues axis gen block = do
  col <- getColumn axis
  when (gen == col.gen && col.pending) $
    arrive axis (columnValues axis col.byYear block) true

-- | A column's new contents are complete, from MPD or from the store.
-- |
-- | Where to put the column afterwards: nowhere, when the list is the
-- | same as before, so a refresh never moves anything under the pointer.
-- | When the list did change and the column holds a selection, the
-- | first selected row goes to the top, which is where the row worth
-- | looking at should be; everything earlier is one scroll back. With no
-- | selection the value that was at the top stays at the top.
-- |
-- | A selection the new contents no longer hold has gone, and what it
-- | was narrowing is asked for again. That happens after a rescan that
-- | removed something, and when a search no longer matches it.
arrive :: forall o m. MonadAff m => Axis -> Array TagValue -> Boolean -> M o m Unit
arrive axis values store = do
  st <- H.get
  let
    br = st.browser
    col = columnOf axis br
    held v = Array.any (\x -> x.display == v) values
    kept = Array.filter held col.selected
    anchor = col.anchor >>= \a -> if held a then Just a else Nothing
    next = col { values = values, selected = kept, anchor = anchor, pending = false }
    changed = map _.display values /= map _.display col.values
  modifyCol axis (const next)
  when changed do
    let
      row = selectionRow next `orElse` (topValue col >>= \v -> rowOfValue v next)
    for_ row \r -> scrollColumn axis (toNumber r * rowHeight)
  when (kept /= col.selected) (narrow axis)
  -- Only the whole-library lists are what the browser's store is keyed
  -- on; a narrowed or searched one is not that list.
  when (store && isPlain axis br) $
    liftEffect (Cache.write (tagOf axis) st.dbStamp values)

-- | The library connection went away, or was dropped to cancel. Replies
-- | to what was outstanding will never come, so nothing may wait for
-- | them; whatever asks next asks again.
dropPending :: forall o m. M o m Unit
dropPending = modifyBrowser \br -> br
  { genre = br.genre { pending = false }
  , artist = br.artist { pending = false }
  , album = br.album { pending = false }
  , tracks = br.tracks { pending = false }
  }

-- ---------------------------------------------------------------------
-- Scrolling and measuring

-- | Put a column at a scroll position, in the state and in the page.
-- | The element is not there when the Library view is not open; the
-- | state keeps the position and `sync` applies it when it is.
scrollColumn :: forall o m. MonadAff m => Axis -> Number -> M o m Unit
scrollColumn axis top = do
  modifyCol axis \c -> c { vp = c.vp { top = top } }
  el <- H.getRef (colRef axis)
  for_ el \e -> liftEffect (Element.setScrollTop top e)

-- | A column was scrolled. Written only when the row under the top edge
-- | or the height moved: a scroll is the one thing that happens sixty
-- | times a second, and the slice drawn only changes once a row.
scrolled :: forall o m. MonadAff m => Axis -> Event -> M o m Unit
scrolled axis ev = for_ (target ev >>= Element.fromEventTarget) \el -> do
  top <- liftEffect (Element.scrollTop el)
  height <- liftEffect (Element.clientHeight el)
  col <- getColumn axis
  when (topRow { top, height } rowHeight /= topRow col.vp rowHeight || height /= col.vp.height) $
    modifyCol axis _ { vp = { top, height } }

-- | The track list was scrolled. Pages in whatever the viewport now
-- | needs.
scrolledTracks :: forall o m. MonadAff m => Event -> M o m Unit
scrolledTracks ev = for_ (target ev >>= Element.fromEventTarget) \el -> do
  top <- liftEffect (Element.scrollTop el)
  height <- liftEffect (Element.clientHeight el)
  t <- getTracks
  when (topRow { top, height } trackHeight /= topRow t.vp trackHeight || height /= t.vp.height) do
    modifyTracks _ { vp = { top, height } }
    fetchAround

-- | Read every list's real height and scroll position off the page,
-- | for when the window changed size or a column came on screen.
measure :: forall o m. MonadAff m => M o m Unit
measure = do
  br <- getBrowser
  for_ (shownAxes br) \a -> do
    el <- H.getRef (colRef a)
    for_ el \e -> do
      vp <- read e
      when (vp /= (columnOf a br).vp) (modifyCol a _ { vp = vp })
  el <- H.getRef tracksRef
  for_ el \e -> do
    vp <- read e
    when (vp /= br.tracks.vp) do
      modifyTracks _ { vp = vp }
      fetchAround
  where
  read e = do
    top <- liftEffect (Element.scrollTop e)
    height <- liftEffect (Element.clientHeight e)
    pure { top, height }

-- | Put every list where the state says it is, then measure. For when
-- | the Library view has just been drawn: its elements are new and sit
-- | at the top, while the state remembers where each list was.
sync :: forall o m. MonadAff m => M o m Unit
sync = do
  br <- getBrowser
  for_ (shownAxes br) \a -> do
    el <- H.getRef (colRef a)
    for_ el \e -> liftEffect (Element.setScrollTop (columnOf a br).vp.top e)
  el <- H.getRef tracksRef
  for_ el \e -> liftEffect (Element.setScrollTop br.tracks.vp.top e)
  measure

-- ---------------------------------------------------------------------
-- The track list

-- | Start the track list over for whatever the columns and the search
-- | now narrow to.
-- |
-- | That is one filter, whatever is selected, so it is one `count` for
-- | the scrollbar and one `find` per page. With no filter at all the list
-- | is the whole library, whose size `stats` already gave. The first page
-- | goes out beside the count rather than behind it: row zero exists
-- | whatever the count turns out to be.
loadTracks :: forall o m. MonadAff m => M o m Unit
loadTracks = do
  st <- H.get
  let
    f = trackFilter st.browser
    gen = st.browser.tracks.gen + 1
  modifyTracks \t -> t
    { rows = []
    , from = 0
    , pending = false
    , gen = gen
    , total = if isNothing f then st.songs else 0
    , counted = isNothing f
    , vp = t.vp { top = 0.0 }
    -- The selection belonged to the list that has just been replaced.
    , picked = []
    , anchor = Nothing
    }
  el <- H.getRef tracksRef
  for_ el \e -> liftEffect (Element.setScrollTop 0.0 e)
  for_ f \e -> send Lib (RTrackCount gen) ("count " <> Mpd.quote e)
  trackPageFrom 0

-- | `stats` came in: with no filter, the list is that many songs.
setLibraryCount :: forall o m. Int -> M o m Unit
setLibraryCount n = do
  br <- getBrowser
  when (isNothing (trackFilter br)) $
    modifyTracks _ { total = n, counted = true }

-- | Ask for whatever rows the viewport needs that are not held. Asking
-- | when the drawn slice comes within one screen of the end means the
-- | next page is usually there before the rows that need it are.
fetchAround :: forall o m. MonadAff m => M o m Unit
fetchAround = do
  t <- getTracks
  let
    want = clamp 0 (max 0 (t.total - 1)) (topRow t.vp trackHeight)
    reach = Int.ceil ((t.vp.top + t.vp.height * 2.0) / trackHeight)
    held = heldTo t
  unless (t.pending || t.total == 0) do
    if want < t.from || want >= held then do
      -- Landed outside the run that is held, which a dragged scrollbar
      -- does. Start a new run on a page boundary at the row under the
      -- viewport rather than walking there.
      let
        base = (want / trackPage) * trackPage
      modifyTracks _ { rows = [], from = base }
      trackPageFrom base
    else when (reach >= held && held < t.total) (trackPageFrom held)

-- | One window of tracks. MPD evaluates the filter and hands back the
-- | slice, so a scroll into the middle of seventy thousand songs costs
-- | one request of two hundred rather than the lot.
trackPageFrom :: forall o m. MonadAff m => Int -> M o m Unit
trackPageFrom from = do
  br <- getBrowser
  let
    t = br.tracks
    want = if t.counted then min trackPage (t.total - from) else trackPage
  unless (t.pending || want <= 0) do
    modifyTracks _ { pending = true }
    send Lib (RTracks { gen: t.gen, from, want }) (listing (trackFilter br) from (from + want))
  where
  -- An empty needle matches every song, which is the only way MPD will
  -- list the whole library through a search.
  listing f a b =
    ( case f of
        Nothing -> "search any \"\""
        Just e -> "find " <> Mpd.quote e
    )
      <> " window "
      <> show a
      <> ":"
      <> show b

-- | How many tracks the filter matches.
trackCount :: forall o m. MonadAff m => Int -> Array String -> M o m Unit
trackCount gen block = do
  t <- getTracks
  when (gen == t.gen) do
    modifyTracks _ { total = Mpd.parseCount block, counted = true }
    fetchAround

-- | One page of tracks. Appended when it is the next page of the held
-- | run; a page for a selection that has since changed, or for a run
-- | that has since been abandoned, answers a request nobody is asking
-- | any more.
-- |
-- | A page shorter than it was asked for says where the result really
-- | ends, and the total is corrected to match. `find` is the truth and
-- | `count` was the estimate; without this a count that overstates by a
-- | row would have the list asking for that row for ever.
tracks :: forall o m. MonadAff m => { gen :: Int, from :: Int, want :: Int } -> Array String -> M o m Unit
tracks w block = do
  t <- getTracks
  when (w.gen == t.gen) do
    let
      page = Mpd.parseSongs block
      got = Array.length page
      reached = w.from + got
      short = got < w.want
    modifyTracks \u -> u
      { pending = false
      , rows = if w.from == heldTo u then u.rows <> page else u.rows
      , total = if short then reached else max u.total reached
      , counted = u.counted || short
      }
    fetchAround

-- | A click on a track row. Plain picks that row, the platform's
-- | modifier adds or removes it, shift takes the run from the last row
-- | picked. The row's own plus still queues it on its own: this is for
-- | gathering a handful of tracks and queueing them together.
chooseTrack :: forall o m. MonadAff m => Int -> MouseEvent -> M o m Unit
chooseTrack row ev = modifyTracks \t -> t
  { picked = pickedBy t row (MouseEvent.shiftKey ev) (MouseEvent.ctrlKey ev || MouseEvent.metaKey ev)
  , anchor = if MouseEvent.shiftKey ev then t.anchor `orElse` Just row else Just row
  }

clearPicked :: forall o m. M o m Unit
clearPicked = modifyTracks _ { picked = [], anchor = Nothing }

-- | Queue what the buttons above the list act on: the tracks picked in
-- | the list when any are, and otherwise everything the columns and the
-- | search narrow to.
-- |
-- | A selection is one `add` per track, in the order they are listed. A
-- | whole filter is one `findadd`, so four artists with thirty albums
-- | between them is one command and not nine hundred.
filterCommand :: forall o m. MonadAff m => Boolean -> M o m Unit
filterCommand play = do
  br <- getBrowser
  case inListOrder br.tracks, trackFilter br of
    [], Nothing -> pure unit
    [], Just f -> do
      start
      send Cmd RFire ("findadd " <> Mpd.quote f)
      finish
    uris, _ -> do
      start
      for_ uris \u -> send Cmd RFire ("add " <> Mpd.quote u)
      finish
  where
  start = when play (send Cmd RFire "clear")
  finish = when play do
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }