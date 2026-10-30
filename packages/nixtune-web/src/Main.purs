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

import Caps as Caps
import Data.Array (elem, head, length, snoc, uncons, (:))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int (fromString, toNumber)
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.Number as Number
import Data.String (Pattern(..), split, stripSuffix, trim)
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
  , Conn(..)
  , M
  , Req(..)
  , Role(..)
  , View(..)
  , arrived
  , idleCommand
  , initial
  , isSticker
  , maxVolumeOf
  , searchLimit
  , shownVolume
  , stickerFind
  , stickerName
  , unmuteFloor
  , volumeFloor
  )
import Volume (setVolume)
import Web.Event.Event (EventType(..), preventDefault)
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
        for_ caps.volumePath connectVolume
        { emitter, listener } <- liftEffect HS.create
        _ <- liftEffect (setInterval 1000 (HS.notify listener Tick))
        void (H.subscribe emitter)
  Opened _ -> pure unit
  Closed conn -> do
    setLink conn Nothing
    H.modify_ _ { error = Just "The player went away. Reconnecting.", asked = [] }
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
    H.modify_ \st ->
      let
        st' = st { ticks = st.ticks + 1 }
      in
        if isNothing st.seekDraft && st.status.state == Playing && st.status.duration > 0.0 && st.status.elapsed < st.status.duration then
          st' { status = st.status { elapsed = st.status.elapsed + 1.0 } }
        else st'
    st <- H.get
    -- A scan that runs for days changes the "database" subsystem only at
    -- its end, so the count is asked for every ten seconds while it runs.
    when (st.status.updating && st.ticks `mod` 10 == 0) do
      send Cmd RStats "stats"
      when (st.view == Library && isNothing st.searched) (browse st.path)
  Open v -> do
    H.modify_ _ { view = v }
    when (v == Library) do
      st <- H.get
      when (isNothing st.searched) (browse st.path)
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
    H.modify_ _ { searched = Nothing, query = "" }
    browse p
  SetQuery q -> H.modify_ _ { query = q }
  Search ev -> do
    liftEffect (preventDefault ev)
    q <- H.gets (trim <<< _.query)
    unless (q == "") do
      H.modify_ _ { searched = Just q }
      -- window, because MPD closes a connection whose reply overruns its
      -- output buffer, and "any" over a library this size can do that on
      -- a common word. The page says when a result set was cut.
      send Cmd (RSearch q) ("search any " <> Mpd.quote q <> " window 0:" <> show searchLimit)
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

-- | One complete line from MPD on one connection.
received :: forall o m. MonadAff m => Conn -> String -> M o m Unit
received conn l
  | Mpd.isGreeting l = do
      modifyLink conn _ { ready = true }
      H.modify_ _ { error = Nothing }
      case conn of
        Cmd -> refreshAll
        Idle -> send Idle RFire idleCommand
  | Mpd.isEnd l = do
      st <- H.get
      let
        block = maybe [] _.lines (linkOf conn st)
      modifyLink conn _ { lines = [] }
      case conn of
        Idle -> do
          changed block
          send Idle RFire idleCommand
        Cmd -> case uncons st.asked of
          Nothing -> pure unit
          Just { head: req, tail } -> do
            H.modify_ _ { asked = tail }
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
  when (elem "changed: playlist" block) (send Cmd RQueue "playlistinfo")
  when (elem "changed: sticker" block) (send Cmd RStickers stickerFind)
  when (elem "changed: database" block || elem "changed: update" block) do
    send Cmd RStats "stats"
    st <- H.get
    when (st.view == Library && isNothing st.searched) (browse st.path)

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
  RStats -> H.modify_ _ { songs = Mpd.parseStats block }
  RBrowse p -> H.modify_ _ { path = p, entries = Mpd.parseEntries block }
  RSearch _ -> H.modify_ _ { entries = Mpd.parseEntries block }
  RStickers -> H.modify_ _ { addedBy = Mpd.parseStickers block }
  RFire -> pure unit
