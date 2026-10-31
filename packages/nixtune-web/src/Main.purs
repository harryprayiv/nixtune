-- | The player's page, in two roles from one bundle.
-- |
-- | Three websockets to MPD, each bridged by websocat to the daemon's TCP
-- | port. One carries commands and their replies, in order, so the page
-- | keeps a queue of what it asked and reads each reply against the head
-- | of that queue. One sits in MPD's `idle` command and is told what
-- | changed; the page then asks the first connection for the new status.
-- | One is the library's own, so a browse is never behind a queue fetch.
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
-- |   Browse.purs   the tag browser as data, and its arithmetic
-- |   Tags.purs     the tag browser's behaviour
-- |   Net.purs      the sockets and the requests
-- |   Volume.purs   the level and the glide
-- |   Player.purs   the bar: position, transport, level
-- |   Reorder.purs  dragging a queue row
-- |   Art.purs      cover images from the library
-- |   Nick.purs     the role and the guest nickname
-- |   Cache.purs    the library index, kept between visits
-- |   Page.purs     everything drawn but the Library view and the bar
-- |   Library.purs  the Library view: search, tag browser, folders
-- |   Filter.purs   MPD filter expressions and their escaping
-- |   Ui.purs       class attributes, glyphs, the format badge
-- |   Mpd.purs      the protocol's text, parsed
-- |   Caps.purs     capabilities.json
module Main (main) where

import Prelude

import Browse (emptyBrowser)
import Caps as Caps
import Data.Array (any, elem, filter, head, length, null, snoc, uncons, (:))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (fromString, toNumber)
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.Number as Number
import Data.String (joinWith, trim)
import Data.String.CodeUnits (toCharArray)
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
import Net (browse, connect, connectVolume, linkOf, liveLink, modifyLink, pushLine, refreshAll, send, setLink, takeBlock, takeLines)
import Nick (nicknameFor, roleFromPath)
import Page (render)
import Reorder (dragTarget, rowMiddles)
import Tags as Tags
import Types
  ( Action(..)
  , BrowseMode(..)
  , Conn(..)
  , M
  , Req(..)
  , Role(..)
  , View(..)
  , arrived
  , clearConfirmMs
  , idleCommand
  , initial
  , isQuiet
  , maxVolumeOf
  , searchMinChars
  , searchPauseMs
  , shownVolume
  , stickerFind
  , stickerName
  , unmuteFloor
  , vetoFind
  , vetoLimit
  , vetoName
  , volumeFloor
  , votersAgainst
  )
import Volume (setVolume)
import Web.Event.Event (EventType(..), preventDefault)
import Web.HTML (window)
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.Window (document, innerHeight)
import Web.HTML.Window as Window
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
        win <- liftEffect window
        -- The lists are measured once they are on the page; until then
        -- the window's height is the guess, so nothing is drawn short.
        height <- liftEffect (innerHeight win)
        H.modify_ _ { caps = Just caps, role = role, nickname = nick, browser = emptyBrowser (toNumber height) }
        connect Cmd
        connect Idle
        connect Lib
        for_ caps.volumePath connectVolume
        { emitter, listener } <- liftEffect HS.create
        _ <- liftEffect (setInterval 1000 (HS.notify listener Tick))
        void (H.subscribe emitter)
        void (H.subscribe (HQE.eventListener (EventType "resize") (Window.toEventTarget win) (const (Just Measure))))
  Opened _ _ -> pure unit
  -- Only the socket the connection is actually using closing means the
  -- player went away. A socket dropped on purpose to cancel stale work
  -- closes too, moments after its replacement is live, and that is not
  -- an outage and must not take the new socket down with it.
  Closed conn serial -> do
    st <- H.get
    when (isJust (liveLink conn serial st)) do
      setLink conn Nothing
      when (conn == Lib) Tags.dropPending
      H.modify_ _ { error = Just "The player went away. Reconnecting." }
      H.liftAff (delay (Milliseconds 2000.0))
      connect conn
  -- One message off the wire. Everything here that is not the end of a
  -- reply happens in Refs, through liftEffect, and touches no component
  -- state: Halogen renders the whole page on every state update, and a
  -- ten thousand line reply collected through the state rendered the
  -- page ten thousand times, which is what made opening the Library take
  -- most of a minute against a player that answered in under a second.
  Chunk conn serial raw -> do
    st <- H.get
    for_ (liveLink conn serial st) \k -> do
      lines <- liftEffect (takeLines k raw)
      for_ lines \line ->
        if Mpd.isGreeting line || Mpd.isEnd line then finished conn line
        else liftEffect (pushLine k line)
  Tick -> do
    before <- H.get
    let
      -- The host's clock is in the player bar, on every view; a guest's
      -- is on the Now playing card only, so a guest's page does not
      -- re-render once a second for a clock nobody is looking at. Every
      -- list on the page is drawn a slice at a time, so a render is a
      -- few hundred nodes whatever the library holds. Open NowPlaying
      -- asks for `status`, so a guest's clock is right again the moment
      -- it is visible.
      running =
        (before.role == Host || before.view == NowPlaying)
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
        when (st.view == Library) $ case st.mode of
          Folders -> browse st.path
          Tags -> Tags.recount
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
      case st.mode of
        Folders -> browse st.path
        Tags -> showTags
  Measure -> Tags.measure
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
    H.modify_ _ { mode = Folders }
    browse p
  SetMode m -> do
    H.modify_ _ { mode = m }
    st <- H.get
    case m of
      Folders -> browse st.path
      Tags -> showTags
  ToggleGenreColumn -> Tags.toggleGenreColumn
  Choose axis v ev -> Tags.choose axis v ev
  ClearColumn axis -> Tags.clearColumn axis
  JumpTo axis l -> Tags.jumpTo axis l
  ChooseTrack row ev -> Tags.chooseTrack row ev
  ClearTracks -> Tags.clearPicked
  Scrolled axis ev -> Tags.scrolled axis ev
  ScrolledTracks ev -> Tags.scrolledTracks ev
  AddFilter -> Tags.filterCommand false
  PlayFilter -> Tags.filterCommand true
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
  -- The search narrows the columns and the list as it is typed, once
  -- typing pauses. Each keystroke takes a number; a pause applies the
  -- search only if no keystroke came after the one it was waiting on.
  SetQuery q -> do
    st <- H.modify \s -> s { query = q, queryTick = s.queryTick + 1 }
    let
      tick = st.queryTick
    void $ H.fork do
      H.liftAff (delay (Milliseconds searchPauseMs))
      handle (QueryPaused tick)
  QueryPaused tick -> do
    st <- H.get
    when (tick == st.queryTick) (Tags.commitQuery (typedQuery false st.query))
  -- Enter applies whatever is there, however short, at once.
  Search ev -> do
    liftEffect (preventDefault ev)
    st <- H.modify \s -> s { queryTick = s.queryTick + 1 }
    Tags.commitQuery (typedQuery true st.query)
  ClearQuery -> do
    H.modify_ \s -> s { query = "", queryTick = s.queryTick + 1 }
    Tags.commitQuery Nothing
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
  ClearQueue -> do
    st <- H.get
    case st.clearArmed of
      Just _ -> do
        H.modify_ _ { clearArmed = Nothing }
        send Cmd RFire "clear"
      Nothing -> do
        let
          press = st.clearTick + 1
        H.modify_ _ { clearArmed = Just press, clearTick = press }
        void $ H.fork do
          H.liftAff (delay (Milliseconds clearConfirmMs))
          handle (ClearDisarm press)
  ClearDisarm press -> do
    armed <- H.gets _.clearArmed
    when (armed == Just press) (H.modify_ _ { clearArmed = Nothing })
  UpdateLibrary -> send Cmd RFire "update"

-- | The tag browser has just come on screen. Its columns were fetched at
-- | startup, so this usually asks for nothing; a page whose fetch never
-- | happened (the library connection came up after the stamp) asks now.
-- | Either way the new elements are put where the state says they were
-- | and measured.
showTags :: forall o m. MonadAff m => M o m Unit
showTags = do
  st <- H.get
  when (null st.browser.artist.values && not st.browser.artist.pending) Tags.reload
  Tags.sync

-- | A greeting, or the line that ends a reply. These are the only two
-- | lines off the wire that change anything the page draws.
finished :: forall o m. MonadAff m => Conn -> String -> M o m Unit
finished conn l
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
        -- something from it, and a socket opened to cancel stale work
        -- already carries what the click asked for in `queued`. Only a
        -- connection that came back with nothing waiting on it has to
        -- ask again.
        Lib -> when (Array.null held) do
          st <- H.get
          when (st.view == Library) $ case st.mode of
            Folders -> browse st.path
            Tags -> Tags.reload
  | otherwise = do
      st <- H.get
      block <- case linkOf conn st of
        Just k -> liftEffect (takeBlock k)
        Nothing -> pure []
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
            when (Mpd.isError l && not (isQuiet req)) (H.modify_ _ { error = Just l })
            unless (Mpd.isError l) (reply req block)

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
    when (st.view == Library && st.mode == Folders) (browse st.path)

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
    Tags.setLibraryCount stats.songs
    -- The index is fetched as soon as the stamp is known, not when the
    -- Library tab is first opened, so the column is already there when
    -- it is. On a warm cache this costs nothing at all.
    when (stats.stamp /= before) do
      mode <- H.gets _.mode
      when (mode == Tags) Tags.reload
  RBrowse p -> H.modify_ _ { path = p, entries = Mpd.parseEntries block }
  RStickers -> H.modify_ _ { addedBy = Mpd.parseStickers block }
  RVetoes -> H.modify_ _ { vetoes = Mpd.parseStickers block }
  RTagValues axis gen -> Tags.tagValues axis gen block
  RTrackCount gen -> Tags.trackCount gen block
  RTracks w -> Tags.tracks w block
  -- An OK is the answer; the reply's rows do not matter.
  RProbe -> Tags.modifyBrowser _ { regex = true }
  RFire -> pure unit

-- | What the search box holds, as a search: trimmed, and Nothing when it
-- | is empty or, unless Enter was pressed, shorter than searchMinChars.
typedQuery :: Boolean -> String -> Maybe String
typedQuery enter raw =
  let
    q = trim raw
  in
    if q == "" then Nothing
    else if enter || length (toCharArray q) >= searchMinChars then Just q
    else Nothing