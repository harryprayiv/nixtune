-- | The player's page, in two roles from one bundle.
-- |
-- | Two websockets to MPD, each bridged by websocat to the daemon's TCP
-- | port. One carries commands and their replies, in order, so the page
-- | keeps a queue of what it asked and reads each reply against the head
-- | of that queue. The other sits in MPD's `idle` command and is told what
-- | changed; the page then asks the first connection for the new status.
-- | Nothing is polled.
-- |
-- | What the page may show is read once from capabilities.json, which Nix
-- | wrote when the host was built. The ROLE is read from the path the page
-- | was opened at: capabilities.hostPath opens the host page (everything,
-- | plus the QR code); any other path opens the guest page, which shows
-- | now playing and lets a guest browse the library and append to the
-- | queue, and nothing else. The limit is the page's: both roles reach the
-- | same websocket, and there is no component on the player that knows
-- | which page a socket belongs to.
-- |
-- | A guest is named by a nickname this page generates on first visit and
-- | keeps in the browser's localStorage. When a guest appends a track the
-- | page also sets an MPD sticker on it, nixtune.added_by, which the host
-- | page reads back beside each queue entry.
-- |
-- | This module is the component: the state machine and the protocol. The
-- | rest is beside it.
-- |
-- |   Types.purs    the state, the actions, the constants
-- |   Net.purs      the sockets and the requests
-- |   Volume.purs   the level, the glide, the bar
-- |   Reorder.purs  dragging a queue row
-- |   Art.purs      cover images from the library
-- |   Nick.purs     the role and the guest nickname
-- |   Page.purs     everything drawn
-- |   Ui.purs       class attributes and glyphs
-- |   Mpd.purs      the protocol's text, parsed
-- |   Caps.purs     capabilities.json
module Main (main) where

import Prelude

import Cache as Cache
import Caps as Caps
import Data.Array (any, elem, filter, head, length, null, snoc, uncons, (:))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (fromString, toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.Number as Number
import Data.String (Pattern(..), joinWith, split, stripSuffix, trim)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Timer (setInterval)
import Halogen as H
import Halogen.Aff as HA
import Halogen.Query.Event as HQE
import Halogen.Subscription as HS
import Halogen.VDom.Driver (runUI)
import Mpd (PlayState(..))
import Mpd as Mpd
import Net (browse, connect, connectVolume, linkOf, modifyLink, refreshAll, send, setLink)
import Nick (nicknameFor, roleFromPath)
import Page (render)
import Reorder (dragTarget, rowMiddles)
import Types
  ( Action(..)
  , Axis(..)
  , State
  , Viewport
  , colRef
  , firstUnder
  , rowHeight
  , valuesOf
  , viewportOf
  , BrowseMode(..)
  , Conn(..)
  , M
  , Req(..)
  , Role(..)
  , View(..)
  , arrived
  , tagOf
  , trackTerms
  , trackHeight
  , trackPage
  , tracksRef
  , idleCommand
  , initial
  , isSticker
  , markedIn
  , maxVolumeOf
  , searchLimit
  , selectionOf
  , setMarked
  , spanBetween
  , shownVolume
  , stickerFind
  , vetoFind
  , vetoLimit
  , vetoName
  , votersAgainst
  , stickerName
  , unmuteFloor
  , volumeFloor
  )
import Volume (setVolume)
import Web.DOM.Element as Element
import Web.Event.Event (EventType(..), preventDefault, target)
import Web.HTML (window)
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.Window (document)
import Web.UIEvent.KeyboardEvent as KE
import Web.UIEvent.MouseEvent as MouseEvent

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: const initial
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handle, initialize = Just Init }
    }

handle :: forall o m. MonadAff m => Action -> M o m Unit
handle = case _ of
  Init -> do
    r <- H.liftAff Caps.fetch
    case r of
      Left e -> H.modify_ _ { error = Just ("capabilities.json could not be read: " <> e) }
      Right caps -> do
        role <- liftEffect (roleFromPath caps.hostPath)
        nick <- liftEffect nicknameFor
        H.modify_ _ { caps = Just caps, role = role, nickname = nick }
        connect Cmd
        connect Idle
        connect Lib
        for_ caps.volumePath connectVolume
        { emitter, listener } <- liftEffect HS.create
        _ <- liftEffect (setInterval 1000 (HS.notify listener Tick))
        void (H.subscribe emitter)
  Opened _ -> pure unit
  Closed conn -> do
    setLink conn Nothing
    H.modify_ _ { error = Just "The player went away. Reconnecting." }
    H.liftAff (delay (Milliseconds 2000.0))
    connect conn
  Chunk conn raw -> do
    st <- H.get
    let
      text = maybe "" _.partial (linkOf conn st) <> raw
      pieces = split (Pattern "\n") text
      complete = fromMaybe [] (Array.init pieces)
      rest = fromMaybe "" (Array.last pieces)
    modifyLink conn _ { partial = rest }
    for_ complete \l -> do
      let
        line = fromMaybe l (stripSuffix (Pattern "\r") l)
      unless (line == "") (received conn line)
  Tick -> do
    before <- H.get
    let
      -- The clock is drawn on Now playing and nowhere else, so advancing
      -- it while the library is on screen re-renders the whole page once
      -- a second for something nobody is looking at. Over a column of
      -- thousands of rows that is the difference between a page that
      -- answers a tap and one that looks dead. Open NowPlaying asks for
      -- `status`, so the clock is right again the moment it is visible.
      running =
        before.view == NowPlaying
          && before.status.state == Playing
          && isNothing before.seekDraft
          && before.status.duration > 0.0
          && before.status.elapsed < before.status.duration
    when running $
      H.modify_ \st -> st { status = st.status { elapsed = st.status.elapsed + 1.0 } }
    -- A scan that runs for days changes the "database" subsystem only at
    -- its end, so the count is asked for every ten seconds while it runs.
    -- The counter only turns while a scan is running, which keeps an
    -- idle page from re-rendering on a timer at all.
    when before.status.updating do
      H.modify_ \st -> st { ticks = st.ticks + 1 }
      st <- H.get
      when (st.ticks `mod` 10 == 0) do
        send Cmd RStats "stats"
        when (st.view == Library && isNothing st.searched) $ case st.mode of
          Folders -> browse st.path
          Tags -> refreshTags
  Open v -> do
    H.modify_ _ { view = v }
    -- The clock stops advancing while another view is up (see Tick), so
    -- it is resynced on the way back rather than kept warm the whole
    -- time at the cost of a re-render a second.
    when (v == NowPlaying) (send Cmd RStatus "status")
    -- The queue is fetched when the Queue view opens and not before. On
    -- a few hundred entries that reply is the most expensive thing the
    -- page asks for, and every other view needs only its length, which
    -- `status` already carries.
    when (v == Queue) do
      send Cmd RQueue "playlistinfo"
      send Cmd RStickers stickerFind
      send Cmd RVetoes vetoFind
    when (v == Library) do
      st <- H.get
      when (isNothing st.searched) $ case st.mode of
        Folders -> browse st.path
        -- Already fetched at startup, so opening the tab asks for
        -- nothing. A database change refreshes it through `changed`.
        Tags -> when (null st.artists) refreshTags
  Command c -> send Cmd RFire c
  SetVolume raw -> for_ (fromString raw) \v -> do
    top <- H.gets maxVolumeOf
    H.modify_ _ { volBeforeMute = Nothing }
    setVolume (clamp volumeFloor top v)
  Nudge by -> do
    st <- H.get
    for_ (shownVolume st) \now -> do
      -- Floored like the bar, so a stepper can never silence the player.
      let
        v = clamp volumeFloor (maxVolumeOf st) (now + by)
      when (v /= now) do
        H.modify_ _ { volBeforeMute = Nothing }
        setVolume v
  VolumeFocus -> do
    st <- H.get
    H.modify_ _ { volText = Just (maybe "" show (shownVolume st)) }
  VolumeText t -> H.modify_ _ { volText = Just t }
  -- Committed on Enter and on leaving the field, not on the change event:
  -- Halogen writes the value property on every render, which clears the
  -- browser's dirty flag, and an input the browser thinks is unmodified
  -- never fires change. Typing a level and pressing Done would have been
  -- silently dropped.
  CommitVolume -> do
    st <- H.get
    H.modify_ _ { volText = Nothing }
    for_ (st.volText >>= (fromString <<< trim)) \typed -> do
      -- A typed zero is a deliberate silence, so it is allowed where the
      -- bar's floor forbids it, and it remembers where to come back to.
      if typed <= 0 then do
        for_ (shownVolume st) \now -> when (now > 0) (H.modify_ _ { volBeforeMute = Just now })
        setVolume 0
      else do
        H.modify_ _ { volBeforeMute = Nothing }
        setVolume (clamp volumeFloor (maxVolumeOf st) typed)
  VolumeKey k -> when (k == "Enter") (handle CommitVolume)
  GrabRow i ev -> do
    st <- H.get
    -- A pointer event is a mouse event, so one pair of handlers covers a
    -- mouse, a finger and a stylus. preventDefault stops the drag being
    -- read as a text selection; touch-action on the handle stops it
    -- being read as a scroll.
    for_ (MouseEvent.fromEvent ev) \me -> when (isNothing st.drag && length st.queue > 1) do
      liftEffect (preventDefault ev)
      mids <- rowMiddles (length st.queue)
      when (length mids == length st.queue) do
        doc <- liftEffect (window >>= document)
        let
          target = HTMLDocument.toEventTarget doc
          y = toNumber (MouseEvent.clientY me)
          at j = fromMaybe 0.0 (Array.index mids j)
          advance = case Array.index mids (i + 1), Array.index mids (i - 1) of
            Just below, _ -> below - at i
            _, Just above -> at i - above
            _, _ -> 0.0
        -- Listened for on the document, not the row: a finger that
        -- outruns the row still steers the drag, and a pointer released
        -- anywhere at all ends it.
        move <- H.subscribe (HQE.eventListener (EventType "pointermove") target (Just <<< DragRow))
        up <- H.subscribe (HQE.eventListener (EventType "pointerup") target (const (Just DropRow)))
        off <- H.subscribe (HQE.eventListener (EventType "pointercancel") target (const (Just DropRow)))
        H.modify_ _ { drag = Just { from: i, startY: y, y, mids, advance, subs: [ move, up, off ] } }
  DragRow ev -> do
    st <- H.get
    for_ st.drag \d -> for_ (MouseEvent.fromEvent ev) \me ->
      H.modify_ _ { drag = Just (d { y = toNumber (MouseEvent.clientY me) }) }
  DropRow -> do
    st <- H.get
    for_ st.drag \d -> do
      for_ d.subs H.unsubscribe
      H.modify_ _ { drag = Nothing }
      let
        to = dragTarget d
        at j = fromMaybe j (Array.index st.queue j >>= _.pos)
      when (to /= d.from) (send Cmd RFire ("move " <> show (at d.from) <> " " <> show (at to)))
  GripKey pos ev -> do
    st <- H.get
    let
      lastPos = length st.queue - 1
    case KE.key ev of
      "ArrowUp" -> when (pos > 0) do
        liftEffect (preventDefault (KE.toEvent ev))
        send Cmd RFire ("move " <> show pos <> " " <> show (pos - 1))
      "ArrowDown" -> when (pos < lastPos) do
        liftEffect (preventDefault (KE.toEvent ev))
        send Cmd RFire ("move " <> show pos <> " " <> show (pos + 1))
      _ -> pure unit
  ToggleMute -> do
    st <- H.get
    for_ (shownVolume st) \now ->
      if now > 0 then do
        H.modify_ _ { volBeforeMute = Just now }
        setVolume 0
      else do
        -- Always restores to something audible. A player left silent with
        -- no earlier level remembered comes back at unmuteFloor rather
        -- than leaving the button doing nothing, which is the dead state
        -- the first version of this had.
        let
          back = clamp volumeFloor (maxVolumeOf st) (fromMaybe unmuteFloor st.volBeforeMute)
        H.modify_ _ { volBeforeMute = Nothing }
        setVolume back
  VolOpened -> H.modify_ \st -> st { volLink = map (_ { ready = true }) st.volLink }
  VolClosed -> do
    H.modify_ _ { volLink = Nothing }
    H.liftAff (delay (Milliseconds 2000.0))
    path <- H.gets (\st -> st.caps >>= _.volumePath)
    for_ path connectVolume
  ArtMissing -> H.modify_ \st -> st { artTry = st.artTry + 1 }
  DragSeek raw -> for_ (Number.fromString raw) \t ->
    H.modify_ _ { seekDraft = Just t }
  CommitSeek raw -> for_ (Number.fromString raw) \t -> do
    H.modify_ \st -> st { seekDraft = Nothing, status = st.status { elapsed = t } }
    send Cmd RFire ("seekcur " <> show t)
  Browse p -> do
    H.modify_ _ { searched = Nothing, query = "", mode = Folders }
    browse p
  SetMode m -> do
    H.modify_ _ { mode = m, searched = Nothing, query = "" }
    st <- H.get
    case m of
      Folders -> browse st.path
      Tags -> refreshTags
  ToggleGenreColumn -> do
    on <- H.gets _.genreColumn
    -- Turning the column off also drops whatever it was narrowing by,
    -- so the artist list is not left filtered by a column nobody can see.
    H.modify_ _
      { genreColumn = not on
      , selGenre = Nothing
      , selArtist = Nothing
      , selAlbum = Nothing
      , albums = []
      , tagTracks = []
      }
    refreshTags
  -- A click on a row. Plain moves the anchor and the chain; shift
  -- extends the mark from the anchor to here; the platform's own
  -- modifier toggles one row in or out. Only a plain click cascades,
  -- so the columns to the right always show one path through the
  -- library however many rows are marked.
  Choose axis v ev -> do
    st <- H.get
    let
      values = valuesOf axis st
      marked = markedIn axis st
      anchor = fromMaybe v (selectionOf axis st)
    if MouseEvent.shiftKey ev then
      H.modify_ (setMarked axis (spanBetween anchor v values))
    else if MouseEvent.ctrlKey ev || MouseEvent.metaKey ev then
      H.modify_
        ( setMarked axis
            (if elem v marked then filter (_ /= v) marked else snoc marked v)
        )
    else do
      H.modify_ (setMarked axis [ v ])
      handle (Pick axis (Just v))
  -- Everything marked, queued in one go. findadd does the work on MPD's
  -- side, so an artist with thirty albums is one command per album and
  -- not one per track.
  AddMarked axis play -> do
    st <- H.get
    let
      chosen = case markedIn axis st of
        [] -> maybe [] (\v -> [ v ]) (selectionOf axis st)
        vs -> vs
    unless (null chosen) do
      when play (send Cmd RFire "clear")
      for_ chosen \v -> send Cmd RFire (findaddFor axis v st)
      when play do
        send Cmd RFire "play"
        H.modify_ _ { view = NowPlaying }
  Pick axis v -> case axis of
    AxGenre -> do
      H.modify_ _
        { selGenre = v
        , selArtist = Nothing
        , selAlbum = Nothing
        , markArtist = []
        , markAlbum = []
        , artists = []
        , albums = []
        , tagTracks = []
        }
      loadArtists
      loadAlbums
      loadTracks
    AxArtist -> do
      H.modify_ _
        { selArtist = v
        , selAlbum = Nothing
        , markAlbum = []
        , albums = []
        , tagTracks = []
        }
      loadAlbums
      loadTracks
    AxAlbum -> do
      H.modify_ _ { selAlbum = v }
      loadTracks
  -- The rail scrolls the column to where that letter starts. Nothing is
  -- filtered and nothing is hidden: the scroll position moves, the
  -- scroll event that follows recomputes the slice, and everything
  -- above and below is still there to scroll to.
  JumpTo axis l -> do
    st <- H.get
    for_ (firstUnder l (valuesOf axis st)) \i -> do
      el <- H.getRef (colRef axis)
      for_ el \e -> do
        liftEffect (Element.setScrollTop (toNumber i * rowHeight) e)
        -- Setting scrollTop fires no scroll event in every browser, so
        -- the viewport is written here as well as read back later.
        setViewport axis ((viewportOf axis st) { top = toNumber i * rowHeight })
  -- A scroll is the one thing that happens sixty times a second, so it
  -- writes nothing when the numbers have not moved.
  -- The track list pages in as it is scrolled. Asking when the drawn
  -- slice comes within one screen of the end means the next page is
  -- usually there before the rows that need it are.
  ScrolledTracks ev -> for_ (target ev >>= Element.fromEventTarget) \el -> do
    top <- liftEffect (Element.scrollTop el)
    height <- liftEffect (Element.clientHeight el)
    st <- H.get
    when (st.vpTracks.top /= top || st.vpTracks.height /= height) do
      H.modify_ _ { vpTracks = { top, height } }
      let
        loaded = length st.tagTracks
        want = Int.floor (top / trackHeight)
        reach = Int.ceil ((top + height * 2.0) / trackHeight)
        held = st.tracksFrom + loaded
      unless st.tracksPending do
        if want < st.tracksFrom || want >= held then do
          -- Landed outside the run that is held, which a dragged
          -- scrollbar does. Start a new run on a page boundary at the
          -- row under the viewport rather than walking there.
          let
            base = (want / trackPage) * trackPage
          H.modify_ _ { tagTracks = [], tracksFrom = base }
          trackPageFrom base
        else when (reach >= held && held < st.tracksTotal) (trackPageFrom held)
  Scrolled axis ev -> for_ (target ev >>= Element.fromEventTarget) \el -> do
    top <- liftEffect (Element.scrollTop el)
    height <- liftEffect (Element.clientHeight el)
    st <- H.get
    let
      vp = viewportOf axis st
    when (vp.top /= top || vp.height /= height) (setViewport axis { top, height })
  -- One browser, one vote, per track. The tally is an MPD sticker on the
  -- track's URI, so every page sees the same number without anything on
  -- the player keeping score. Whoever casts the deciding vote is the one
  -- that removes the track, by id rather than by position so a racing
  -- removal cannot take the wrong one, and clears the tally so the track
  -- does not arrive pre-vetoed if somebody queues it again.
  Veto uri songId -> do
    st <- H.get
    let
      voters = votersAgainst st uri
      me = st.nickname
      updated = if elem me voters then voters else snoc voters me
    when (not (elem me voters)) do
      send Cmd RFire ("sticker set song " <> Mpd.quote uri <> " " <> vetoName <> " " <> Mpd.quote (joinWith "," updated))
      H.modify_ \s -> s { vetoes = (Tuple uri (joinWith "," updated)) : filter (\(Tuple u _) -> u /= uri) s.vetoes }
    when (length updated >= vetoLimit st) do
      -- Every copy of this track goes, because the tally is per URI and
      -- leaving a second copy queued would make the vote meaningless.
      for_ (filter (\q -> q.file == uri) st.queue) \q ->
        for_ q.id \i -> send Cmd RFire ("deleteid " <> show i)
      for_ songId \i -> when (not (any (\q -> q.file == uri) st.queue)) (send Cmd RFire ("deleteid " <> show i))
      send Cmd RFire ("sticker delete song " <> Mpd.quote uri <> " " <> vetoName)
      H.modify_ \s -> s { vetoes = filter (\(Tuple u _) -> u /= uri) s.vetoes }
  AddAlbum -> albumCommand false
  PlayAlbum -> albumCommand true
  SetQuery q -> H.modify_ _ { query = q }
  Search ev -> do
    liftEffect (preventDefault ev)
    q <- H.gets (trim <<< _.query)
    unless (q == "") do
      H.modify_ _ { searched = Just q }
      -- window, because MPD closes a connection whose reply overruns its
      -- output buffer, and "any" over a library this size can do that on
      -- a common word. The page says when a result set was cut.
      send Lib (RSearch q) ("search any " <> Mpd.quote q <> " window 0:" <> show searchLimit)
  PlayStation s -> do
    send Cmd RFire "clear"
    send Cmd RFire ("add " <> Mpd.quote s.url)
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }
  AddPath p -> do
    st <- H.get
    send Cmd RFire ("add " <> Mpd.quote p)
    when (st.role == Guest) do
      -- Attribution, on the file itself. For a folder MPD has no single
      -- URI to sticker, so a folder appended by a guest is unattributed.
      send Cmd RFire ("sticker set song " <> Mpd.quote p <> " " <> stickerName <> " " <> Mpd.quote st.nickname)
      H.modify_ \s -> s { addedBy = (Tuple p st.nickname) : s.addedBy }
      -- The one transport command a guest can cause: a silent player
      -- starts when a guest adds something to it.
      when (st.status.state == Stopped) (send Cmd RFire "play")
  PlayPath p -> do
    send Cmd RFire "clear"
    send Cmd RFire ("add " <> Mpd.quote p)
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }
  PlayPos n -> send Cmd RFire ("play " <> show n)
  DeletePos n -> send Cmd RFire ("delete " <> show n)
  UpdateLibrary -> send Cmd RFire "update"

-- | Put a column back at the top, in the page and in the state, after
-- | its contents have been replaced. The browser keeps an element's
-- | scroll position across a patch, so without this a column scrolled
-- | halfway down twelve thousand artists would open its replacement
-- | halfway down as well.
toTop :: forall o m. MonadAff m => Axis -> M o m Unit
toTop axis = do
  st <- H.get
  setViewport axis ((viewportOf axis st) { top = 0.0 })
  el <- H.getRef (colRef axis)
  for_ el \e -> liftEffect (Element.setScrollTop 0.0 e)

-- | Put a column's values in the browser's store for next time, under
-- | the database stamp they were read at.
keep :: forall o m. MonadAff m => Axis -> Array String -> M o m Unit
keep axis values = do
  stamp <- H.gets _.dbStamp
  liftEffect (Cache.write (tagOf axis) stamp values)

setViewport :: forall o m. Axis -> Viewport -> M o m Unit
setViewport axis vp = H.modify_ case axis of
  AxGenre -> _ { vpGenre = vp }
  AxArtist -> _ { vpArtist = vp }
  AxAlbum -> _ { vpAlbum = vp }

-- | Load whichever columns the current selection calls for. `list genre`
-- | is a few hundred rows and is asked for unconditionally while the
-- | column is shown; the columns to its right are always bounded by the
-- | selection to their left.
refreshTags :: forall o m. MonadAff m => M o m Unit
refreshTags = do
  st <- H.get
  when st.genreColumn (cachedOrAsk AxGenre ("list " <> tagOf AxGenre))
  loadArtists
  loadAlbums
  -- The list under the columns is the whole library until a column
  -- narrows it, so it is loaded alongside them rather than waiting for
  -- a choice.
  loadTracks

-- | Fill the columns that do not depend on a choice, at startup rather
-- | than on the first Library open.
primeTags :: forall o m. MonadAff m => M o m Unit
primeTags = do
  st <- H.get
  when (st.mode == Tags) refreshTags

-- | A column whose contents depend on nothing but the database: the
-- | genre list, and the artist list when no genre narrows it. Those are
-- | the two worth keeping between visits, and the only two that can be
-- | answered without asking MPD anything.
cachedOrAsk :: forall o m. MonadAff m => Axis -> String -> M o m Unit
cachedOrAsk axis command = do
  st <- H.get
  hit <- liftEffect (Cache.read (tagOf axis) st.dbStamp)
  case hit of
    Just values | not (Array.null values) -> do
      H.modify_ (setValues axis values)
      toTop axis
    _ -> send Lib (RTagValues axis) command

setValues :: Axis -> Array String -> State -> State
setValues axis values = case axis of
  AxGenre -> _ { genres = values }
  AxArtist -> _ { artists = values }
  AxAlbum -> _ { albums = values }

loadArtists :: forall o m. MonadAff m => M o m Unit
loadArtists = do
  st <- H.get
  case st.selGenre of
    -- Narrowed by a genre, so it is neither the cached list nor worth
    -- caching: it is small and there are hundreds of genres.
    Just g | st.genreColumn ->
      send Lib (RTagValues AxArtist) ("list artist genre " <> Mpd.quote g)
    _ -> cachedOrAsk AxArtist "list artist"

-- | The album column is a filter like the others, so with no artist
-- | picked it lists every album in the library, or every album in the
-- | chosen genre.
loadAlbums :: forall o m. MonadAff m => M o m Unit
loadAlbums = do
  st <- H.get
  case st.selArtist, st.selGenre of
    Just a, _ -> send Lib (RTagValues AxAlbum) ("list album artist " <> Mpd.quote a)
    Nothing, Just g | st.genreColumn -> send Lib (RTagValues AxAlbum) ("list album genre " <> Mpd.quote g)
    _, _ -> cachedOrAsk AxAlbum "list album"

-- | Start the track list over for whatever the columns now narrow to.
-- | The count comes separately so the scrollbar is the real length from
-- | the first paint, and the first page follows it.
loadTracks :: forall o m. MonadAff m => M o m Unit
loadTracks = do
  H.modify_ \st -> st
    { tagTracks = []
    , tracksTotal = 0
    , tracksFrom = 0
    , tracksPending = false
    , vpTracks = st.vpTracks { top = 0.0 }
    }
  el <- H.getRef tracksRef
  for_ el \e -> liftEffect (Element.setScrollTop 0.0 e)
  st <- H.get
  case trackTerms st of
    -- Nothing picked: MPD has already counted the library in `stats`,
    -- and there is no filter expression that `count` will accept for
    -- "everything".
    [] -> H.modify_ _ { tracksTotal = st.songs }
    ts -> send Lib RTrackCount ("count " <> joinWith " " ts)
  trackPageFrom 0

-- | One window of tracks. MPD evaluates the filter and hands back the
-- | slice, so a scroll into the middle of seventy thousand songs costs
-- | one request of two hundred rather than the lot.
trackPageFrom :: forall o m. MonadAff m => Int -> M o m Unit
trackPageFrom from = do
  st <- H.get
  unless st.tracksPending do
    H.modify_ _ { tracksPending = true }
    let
      -- An empty needle matches every song, which is the only way MPD
      -- will list the whole library through a filter.
      query = case trackTerms st of
        [] -> "search any \"\""
        ts -> "find " <> joinWith " " ts
    send Lib (RTracks from)
      (query <> " window " <> show from <> ":" <> show (from + trackPage))

-- | What to send to queue everything under one value of a column. An
-- | album is qualified by the anchored artist, because album titles
-- | repeat across a library and "Greatest Hits" on its own would queue
-- | a dozen records.
findaddFor :: Axis -> String -> State -> String
findaddFor axis v st = case axis of
  AxGenre -> "findadd genre " <> Mpd.quote v
  AxArtist -> "findadd artist " <> Mpd.quote v
  AxAlbum -> case st.selArtist of
    Just a -> "findadd album " <> Mpd.quote v <> " artist " <> Mpd.quote a
    Nothing -> "findadd album " <> Mpd.quote v

-- | Queue the selected album. `findadd` does it in one command, so a
-- | twenty track album is one round trip and not twenty.
albumCommand :: forall o m. MonadAff m => Boolean -> M o m Unit
albumCommand play = do
  st <- H.get
  case st.selArtist, st.selAlbum of
    Just a, Just alb -> do
      when play (send Cmd RFire "clear")
      send Cmd RFire ("findadd album " <> Mpd.quote alb <> " artist " <> Mpd.quote a)
      when play do
        send Cmd RFire "play"
        H.modify_ _ { view = NowPlaying }
    _, _ -> pure unit

-- | One complete line from MPD on one connection.
received :: forall o m. MonadAff m => Conn -> String -> M o m Unit
received conn l
  | Mpd.isGreeting l = do
      modifyLink conn _ { ready = true }
      H.modify_ _ { error = Nothing }
      held <- H.gets (maybe [] _.queued <<< linkOf conn)
      modifyLink conn _ { queued = [] }
      for_ held \h -> send conn h.req h.line
      case conn of
        Cmd -> refreshAll
        Idle -> send Idle RFire idleCommand
        -- The library connection asks for nothing until a view wants
        -- something from it.
        Lib -> do
          st <- H.get
          when (st.view == Library && isNothing st.searched) $ case st.mode of
            Folders -> browse st.path
            Tags -> refreshTags
  | Mpd.isEnd l = do
      st <- H.get
      let
        block = maybe [] _.lines (linkOf conn st)
      modifyLink conn _ { lines = [] }
      case conn of
        Idle -> do
          changed block
          send Idle RFire idleCommand
        _ -> case uncons (maybe [] _.asked (linkOf conn st)) of
          Nothing -> pure unit
          Just { head: req, tail } -> do
            modifyLink conn _ { asked = tail }
            -- A missing sticker is reported by MPD as an error; it is
            -- the normal state of a track nobody attributed.
            when (Mpd.isError l && not (isSticker req)) (H.modify_ _ { error = Just l })
            unless (Mpd.isError l) (reply req block)
  | otherwise = modifyLink conn \k -> k { lines = snoc k.lines l }

-- | The idle connection's reply: which subsystems changed.
changed :: forall o m. MonadAff m => Array String -> M o m Unit
changed block = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  st <- H.get
  when (elem "changed: playlist" block && st.view == Queue) (send Cmd RQueue "playlistinfo")
  when (elem "changed: sticker" block && st.view == Queue) do
    send Cmd RStickers stickerFind
    send Cmd RVetoes vetoFind
  -- A vote removes a track, so a guest watching the queue needs the
  -- playlist back even though the page's own tab is what gates the
  -- fetch above.
  when (elem "changed: playlist" block && st.view == Queue) (send Cmd RVetoes vetoFind)
  when (elem "changed: database" block || elem "changed: update" block) do
    -- Only the folder tree is refreshed here. The tag columns follow
    -- the database stamp that this `stats` carries, so reloading them
    -- here as well would fetch the artist list twice for one rescan.
    send Cmd RStats "stats"
    when (st.view == Library && isNothing st.searched && st.mode == Folders) (browse st.path)

-- | A command connection's reply, read against what was asked.
reply :: forall o m. MonadAff m => Req -> Array String -> M o m Unit
reply req block = case req of
  RStatus -> do
    let
      status = Mpd.parseStatus block
      done st = not st.volSending && arrived st.volDraft status.volume
    H.modify_ \st ->
      st
        { status = status
        -- Cleared when MPD reports the level that was asked for, but
        -- only once the glide has finished: a report arriving mid-glide
        -- would otherwise end it early. One unit of slack, because the
        -- mapped write lands on the nearest 0.5 dB step and reading that
        -- back can round the other way.
        , volDraft = if done st then Nothing else st.volDraft
        , volSent = if done st then Nothing else st.volSent
        }
  RCurrent -> do
    let
      cur = head (Mpd.parseSongs block)
    H.modify_ \st ->
      st
        { current = cur
        , artTry = if map _.file cur == map _.file st.current then st.artTry else 0
        }
  RQueue -> H.modify_ _ { queue = Mpd.parseSongs block }
  RStats -> do
    before <- H.gets _.dbStamp
    let
      stats = Mpd.parseStats block
    H.modify_ _ { songs = stats.songs, dbStamp = stats.stamp }
    -- The index is fetched as soon as the stamp is known, not when the
    -- Library tab is first opened, so the column is already there when
    -- it is. On a warm cache this costs nothing at all.
    when (stats.stamp /= before) primeTags
  RBrowse p -> H.modify_ _ { path = p, entries = Mpd.parseEntries block }
  RSearch _ -> H.modify_ _ { entries = Mpd.parseEntries block }
  RStickers -> H.modify_ _ { addedBy = Mpd.parseStickers block }
  RVetoes -> H.modify_ _ { vetoes = Mpd.parseStickers block }
  RTagValues AxGenre -> do
    let
      values = Mpd.parseList "Genre" block
    H.modify_ _ { genres = values }
    toTop AxGenre
    keep AxGenre values
  RTagValues AxArtist -> do
    let
      values = Mpd.parseList "Artist" block
    H.modify_ _ { artists = values }
    toTop AxArtist
    -- Only the unnarrowed list is the one the cache is keyed on.
    st <- H.get
    when (not st.genreColumn || st.selGenre == Nothing) (keep AxArtist values)
  RTagValues AxAlbum -> do
    let
      values = Mpd.parseList "Album" block
    H.modify_ _ { albums = values }
    toTop AxAlbum
    st <- H.get
    -- Only the whole-library list is the one the cache is keyed on.
    when (st.selArtist == Nothing && st.selGenre == Nothing) (keep AxAlbum values)
  RTrackCount -> H.modify_ _ { tracksTotal = (Mpd.parseCount block) }
  RTracks from -> do
    let
      page = Mpd.parseSongs block
    H.modify_ \st -> st
      { tracksPending = false
      -- A page that is not the next one in line is a reply to a request
      -- the selection has since moved past, so it is dropped.
      -- A page that is not the next one in the held run answers a
      -- request the selection or the scroll has since moved past.
      , tagTracks =
          if from == st.tracksFrom + length st.tagTracks then st.tagTracks <> page
          else st.tagTracks
      }
  RFire -> pure unit
