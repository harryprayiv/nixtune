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
  , Tracks
  , cleared
  , columnOf
  , firstUnder
  , heldTo
  , isPlain
  , listCommands
  , listLabel
  , modifyColumn
  , orElse
  , queryAt
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
  , trackCombos
  , trackHeight
  , trackPage
  , tracksTotal
  , union
  )
import Cache as Cache
import Data.Array as Array
import Data.Foldable (for_)
import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Mpd as Mpd
import Net (send)
import Types (Conn(..), M, Req(..), View(..), colRef, tracksRef)
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
-- | The column that was clicked is not reloaded and not scrolled, so
-- | the row that was clicked stays exactly where it is. Everything to
-- | its right goes back to All and is asked for again.
choose :: forall o m. MonadAff m => Axis -> String -> MouseEvent -> M o m Unit
choose axis v ev = do
  col <- getColumn axis
  let
    shift = MouseEvent.shiftKey ev
    extend = MouseEvent.ctrlKey ev || MouseEvent.metaKey ev
    selected
      | shift = spanBetween (fromMaybe v col.anchor) v col.values
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

-- | Reload everything one column's selection narrows: the columns to its
-- | right, which go back to All first, and the track list. Every column
-- | to the right is cleared before any of them is asked for, because
-- | what a column is asked for depends on the selection in every column
-- | to its left.
narrow :: forall o m. MonadAff m => Axis -> M o m Unit
narrow axis = do
  br <- getBrowser
  let
    right = rightOf axis br
  for_ right \a -> do
    modifyCol a cleared
    scrollColumn a 0.0
  for_ right loadColumn
  loadTracks
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
  reload
  sync

-- ---------------------------------------------------------------------
-- Loading columns

-- | Load every column on screen and the list under them, for whatever is
-- | selected now. A column keeps showing what it has until its new list
-- | is complete; the track list starts over.
reload :: forall o m. MonadAff m => M o m Unit
reload = do
  br <- getBrowser
  for_ (shownAxes br) loadColumn
  loadTracks

-- | Bring the columns and the counts up to date without moving anything,
-- | which is what the ten-second tick does while a scan is running. The
-- | browser's store is bypassed: the database stamp does not move until
-- | the scan ends, and the point is to show what has been scanned so far.
recount :: forall o m. MonadAff m => M o m Unit
recount = do
  br <- getBrowser
  for_ (shownAxes br) (load false)
  for_ (Array.mapWithIndex Tuple br.tracks.queries) \(Tuple i q) ->
    unless (q.terms == "") (send Lib (RTrackCount br.tracks.gen i) ("count " <> q.terms))

loadColumn :: forall o m. MonadAff m => Axis -> M o m Unit
loadColumn = load true

-- | One column, built from the selection to its left.
-- |
-- | A column narrowed by nothing is one of the three whole-library
-- | lists, which is what the browser's store holds, so it is answered
-- | from there when the database has not moved since. A column narrowed
-- | by a selection is one `list` per combination of those values,
-- | because MPD's filters have no OR, and the replies are unioned as
-- | they arrive. It is never cached: there are hundreds of genres and
-- | thousands of artists, and each narrowed list is small anyway.
-- |
-- | The column's current values are left in place while the request is
-- | out. A column being refreshed shows what it had until the new list
-- | is complete; a column that was cleared shows that it is loading.
load :: forall o m. MonadAff m => Boolean -> Axis -> M o m Unit
load useCache axis = do
  st <- H.get
  let
    br = st.browser
    plain = isPlain axis br
  hit <-
    if plain && useCache then liftEffect (Cache.read (tagOf axis) st.dbStamp)
    else pure Nothing
  case hit of
    Just values | not (Array.null values) -> arrive axis values false
    _ -> do
      let
        cmds = listCommands axis br
        gen = (columnOf axis br).gen + 1
      modifyCol axis _ { gen = gen, pending = Array.length cmds, expected = Array.length cmds, arriving = [] }
      for_ cmds (send Lib (RTagValues axis gen))

-- | One of the replies that make up a column. The column is finished
-- | when the last of them has arrived; a reply from before the last
-- | click is thrown away rather than merged into a column it does not
-- | belong to.
tagValues :: forall o m. MonadAff m => Axis -> Int -> Array String -> M o m Unit
tagValues axis gen block = do
  col <- getColumn axis
  when (gen == col.gen && col.pending > 0) do
    let
      arriving = col.arriving <> Mpd.parseList (listLabel axis) block
      left = col.pending - 1
    modifyCol axis _ { arriving = arriving, pending = left }
    -- One command, one reply: MPD's own order, kept exactly. Only a
    -- union of several replies has to be merged.
    when (left == 0) (arrive axis (if col.expected <= 1 then arriving else union arriving) true)

-- | A column's new contents are complete, from MPD or from the store.
-- |
-- | Where to put the column afterwards: nowhere, when the list is the
-- | same as before, so a refresh never moves anything under the pointer.
-- | When the list did change and the column holds a selection, the
-- | first selected row goes to the top, which is where the row worth
-- | looking at should be; everything earlier in the alphabet is one
-- | scroll back. With no selection the value that was at the top stays
-- | at the top.
-- |
-- | A selection the new contents no longer hold has gone, and what it
-- | was narrowing is asked for again. That happens after a rescan that
-- | removed something, and not otherwise.
arrive :: forall o m. MonadAff m => Axis -> Array String -> Boolean -> M o m Unit
arrive axis values store = do
  st <- H.get
  let
    br = st.browser
    col = columnOf axis br
    kept = Array.filter (\v -> Array.elem v values) col.selected
    anchor = col.anchor >>= \a -> if Array.elem a values then Just a else Nothing
    next = col { values = values, selected = kept, anchor = anchor, arriving = [], pending = 0 }
    changed = values /= col.values
  modifyCol axis (const next)
  when changed do
    let
      row = selectionRow next `orElse` (topValue col >>= \v -> rowOfValue v next)
    for_ row \r -> scrollColumn axis (toNumber r * rowHeight)
  when (kept /= col.selected) (narrow axis)
  -- Only the three whole-library lists are what the browser's store is
  -- keyed on; a narrowed one is not that list.
  when (store && isPlain axis br) do
    stamp <- H.gets _.dbStamp
    liftEffect (Cache.write (tagOf axis) stamp values)

-- | The library connection went away with requests outstanding. Their
-- | replies will never come, so nothing may wait for them; the next
-- | greeting asks for everything again.
dropPending :: forall o m. M o m Unit
dropPending = modifyBrowser \br -> br
  { genre = br.genre { pending = 0, arriving = [] }
  , artist = br.artist { pending = 0, arriving = [] }
  , album = br.album { pending = 0, arriving = [] }
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

-- | Start the track list over for whatever the columns now narrow to.
-- |
-- | The selection comes to one query per combination of the values
-- | picked, since MPD cannot be asked for a union, and no selection at
-- | all is one query for the whole library whose count is already known
-- | from `stats`. The counts go out together so the scrollbar is the
-- | real length as soon as they land, and the first page goes out beside
-- | them rather than behind them: row zero is in the first query
-- | whatever the counts turn out to be, so there is nothing to wait for.
loadTracks :: forall o m. MonadAff m => M o m Unit
loadTracks = do
  st <- H.get
  let
    cs = trackCombos st.browser
    gen = st.browser.tracks.gen + 1
    queries =
      if Array.null cs then [ { terms: "", count: st.songs } ]
      else map (\c -> { terms: c, count: 0 }) cs
  modifyTracks \t -> t
    { rows = []
    , from = 0
    , pending = false
    , gen = gen
    , queries = queries
    , vp = t.vp { top = 0.0 }
    }
  el <- H.getRef tracksRef
  for_ el \e -> liftEffect (Element.setScrollTop 0.0 e)
  for_ (Array.mapWithIndex Tuple cs) \(Tuple i c) -> send Lib (RTrackCount gen i) ("count " <> c)
  trackPageFrom 0

-- | `stats` came in: the whole-library query's count is its song count.
setLibraryCount :: forall o m. Int -> M o m Unit
setLibraryCount n = modifyTracks \t -> t
  { queries = map (\q -> if q.terms == "" then q { count = n } else q) t.queries }

-- | Ask for whatever rows the viewport needs that are not held. Asking
-- | when the drawn slice comes within one screen of the end means the
-- | next page is usually there before the rows that need it are.
fetchAround :: forall o m. MonadAff m => M o m Unit
fetchAround = do
  t <- getTracks
  let
    total = tracksTotal t
    want = clamp 0 (max 0 (total - 1)) (topRow t.vp trackHeight)
    reach = Int.ceil ((t.vp.top + t.vp.height * 2.0) / trackHeight)
    held = heldTo t
  unless (t.pending || total == 0) do
    if want < t.from || want >= held then do
      -- Landed outside the run that is held, which a dragged scrollbar
      -- does. Start a new run on a page boundary at the row under the
      -- viewport rather than walking there.
      let
        base = (want / trackPage) * trackPage
      modifyTracks _ { rows = [], from = base }
      trackPageFrom base
    else when (reach >= held && held < total) (trackPageFrom held)

-- | One window of tracks. MPD evaluates the filter and hands back the
-- | slice, so a scroll into the middle of seventy thousand songs costs
-- | one request of two hundred rather than the lot.
-- |
-- | With several queries the result is their rows laid end to end, and
-- | a row number is turned into a query and an offset in it by the
-- | counts. A window never crosses from one query into the next: it
-- | stops at the end of the one it started in, and the next fetch picks
-- | up where it left off.
trackPageFrom :: forall o m. MonadAff m => Int -> M o m Unit
trackPageFrom from = do
  t <- getTracks
  let
    -- Before any count has come back there is nothing to map a row
    -- onto, but row zero is in the first query by construction, so the
    -- first page needs no counts at all.
    spot =
      if tracksTotal t > 0 then queryAt from t.queries
      else if from == 0 then Just { index: 0, offset: 0, left: trackPage }
      else Nothing
  unless t.pending $ for_ spot \at -> for_ (Array.index t.queries at.index) \q -> do
    modifyTracks _ { pending = true }
    send Lib (RTracks t.gen from) (listing q.terms at.offset (at.offset + min trackPage at.left))
  where
  -- An empty needle matches every song, which is the only way MPD will
  -- list the whole library through a filter.
  listing terms a b =
    (if terms == "" then "search any \"\"" else "find " <> terms)
      <> " window "
      <> show a
      <> ":"
      <> show b

-- | How many tracks one query matches.
trackCount :: forall o m. MonadAff m => Int -> Int -> Array String -> M o m Unit
trackCount gen i block = do
  t <- getTracks
  when (gen == t.gen) do
    let
      qs = fromMaybe t.queries (Array.modifyAt i (_ { count = Mpd.parseCount block }) t.queries)
    modifyTracks _ { queries = qs }
    -- The first page is sent before the counts are back and asks the
    -- first query blind. If that came back empty because the first
    -- query matches nothing, this is where the real first page is asked
    -- for.
    when (Array.null t.rows && not t.pending) (trackPageFrom t.from)

-- | One page of tracks. Appended when it is the next page of the held
-- | run; a page for a selection that has since changed, or for a run
-- | that has since been abandoned, answers a request nobody is asking
-- | any more.
-- |
-- | A page shorter than it was asked for says where its query really
-- | ends, and the count is corrected to match. `find` is the truth and
-- | `count` was the estimate; without this a count that overstates by
-- | one row would have the list asking for that row forever.
tracks :: forall o m. MonadAff m => Int -> Int -> Array String -> M o m Unit
tracks gen from block = do
  t <- getTracks
  let
    page = Mpd.parseSongs block
    got = Array.length page
    at = queryAt from t.queries `orElse` (if from == 0 then Just { index: 0, offset: 0, left: trackPage } else Nothing)
    corrected = fromMaybe t.queries do
      a <- at
      let
        asked = min trackPage a.left
        real = a.offset + got
      Array.modifyAt a.index (\q -> q { count = if got < asked then real else max q.count real }) t.queries
  when (gen == t.gen) do
    modifyTracks \u -> u
      { pending = false
      , rows = if from == heldTo u then u.rows <> page else u.rows
      , queries = corrected
      }
    fetchAround

-- | Queue everything the columns narrow to, which is what the selection
-- | means. One `findadd` per query, so four artists with thirty albums
-- | between them is four commands and not nine hundred.
filterCommand :: forall o m. MonadAff m => Boolean -> M o m Unit
filterCommand play = do
  br <- getBrowser
  case trackCombos br of
    [] -> pure unit
    cs -> do
      when play (send Cmd RFire "clear")
      for_ cs \c -> send Cmd RFire ("findadd " <> c)
      when play do
        send Cmd RFire "play"
        H.modify_ _ { view = NowPlaying }