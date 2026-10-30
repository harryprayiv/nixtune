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
module Main (main) where

import Prelude

import Caps (Caps, Station)
import Caps as Caps
import Control.Monad.Except (runExcept)
import Data.Array (elem, filter, head, length, null, snoc, take, uncons, (:))
import Data.Array as Array
import Data.Either (Either(..), hush)
import Data.Foldable (for_, lookup)
import Data.Int (fromString, toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.Number as Number
import Data.String (Pattern(..), indexOf, joinWith, split, stripSuffix, trim)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Random (randomInt)
import Effect.Timer (setInterval)
import Foreign (readString)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Query.Event as HQE
import Halogen.Subscription as HS
import Halogen.VDom.Driver (runUI)
import Mpd (Entry(..), PlayState(..), Song, Status)
import Mpd as Mpd
import Web.Event.Event (Event, preventDefault)
import Web.HTML (window)
import Web.HTML.Location as Location
import Web.HTML.Window (localStorage, location)
import Web.Socket.Event.EventTypes as WSE
import Web.Socket.Event.MessageEvent as ME
import Web.Socket.WebSocket (WebSocket)
import Web.Socket.WebSocket as WS
import Web.UIEvent.KeyboardEvent as KE
import Web.Storage.Storage as Storage

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

data Role = Host | Guest

derive instance eqRole :: Eq Role

data View = NowPlaying | Queue | Library | Radio | Qr

derive instance eqView :: Eq View

-- | The two connections.
data Conn = Cmd | Idle

derive instance eqConn :: Eq Conn

-- | What a reply on the command connection is for.
data Req
  = RStatus
  | RCurrent
  | RQueue
  | RStats
  | RBrowse String
  | RSearch String
  | RSticker String
  | RFire

-- | One connection: its socket, whether MPD has greeted on it, the lines
-- | of the reply being collected, and the unfinished tail of the last
-- | message. websocat frames messages by TCP read, not by line, so one
-- | message may hold a whole reply or end in the middle of a line.
type Link = { socket :: WebSocket, ready :: Boolean, lines :: Array String, partial :: String }

type State =
  { caps :: Maybe Caps
  , role :: Role
  , nickname :: String
  , view :: View
  , cmd :: Maybe Link
  , idle :: Maybe Link
  , asked :: Array Req
  , status :: Status
  , current :: Maybe Song
  , queue :: Array Song
  , songs :: Int
  , path :: String
  , query :: String
  , searched :: Maybe String
  , entries :: Array Entry
  , addedBy :: Array (Tuple String String)
  , error :: Maybe String
  , ticks :: Int
  -- Where the bar is being held. Shown immediately and kept until MPD
  -- reports that level back, so the thumb does not snap to a stale value
  -- between the command and the report.
  , volDraft :: Maybe Int
  -- The last level actually sent, and whether the sender is running. A
  -- drag produces an event per pixel; the sender turns that into a walk
  -- toward the target, one step every volumeGlideMs.
  , volSent :: Maybe Int
  , volSending :: Boolean
  -- The level to return to when unmuting. MPD has no mute of its own.
  , volBeforeMute :: Maybe Int
  -- What is in the typed volume field while it is being edited. Nothing
  -- means the field shows the live level; a report from MPD arriving
  -- mid-keystroke must not overwrite what is being typed.
  , volText :: Maybe String
  -- The socket volume changes are written to, when the host has one.
  -- Null in capabilities.json means MPD takes them instead.
  , volLink :: Maybe { socket :: WebSocket, ready :: Boolean }
  -- Where the seek bar is being held. While this is set the one-second
  -- tick leaves elapsed alone, so the thumb does not fight the clock.
  , seekDraft :: Maybe Number
  }

initial :: State
initial =
  { caps: Nothing
  , role: Guest
  , nickname: ""
  , view: NowPlaying
  , cmd: Nothing
  , idle: Nothing
  , asked: []
  , status: Mpd.emptyStatus
  , current: Nothing
  , queue: []
  , songs: 0
  , path: ""
  , query: ""
  , searched: Nothing
  , entries: []
  , addedBy: []
  , error: Nothing
  , ticks: 0
  , volDraft: Nothing
  , volSent: Nothing
  , volSending: false
  , volBeforeMute: Nothing
  , volText: Nothing
  , seekDraft: Nothing
  , volLink: Nothing
  }

data Action
  = Init
  | Opened Conn
  | Closed Conn
  | Chunk Conn String
  | Tick
  | Open View
  | Command String
  | SetVolume String
  | Nudge Int
  | ToggleMute
  | VolumeFocus
  | VolumeText String
  | CommitVolume
  | VolumeKey String
  | MoveQueue Int Int
  | VolOpened
  | VolClosed
  | DragSeek String
  | CommitSeek String
  | Browse String
  | SetQuery String
  | Search Event
  | PlayStation Station
  | AddPath String
  | PlayPath String
  | PlayPos Int
  | DeletePos Int
  | UpdateLibrary

idleCommand :: String
idleCommand = "idle player mixer playlist options database update"

stickerName :: String
stickerName = "nixtune.added_by"

nicknameKey :: String
nicknameKey = "nixtune.nickname"

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: const initial
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handle, initialize = Just Init }
    }

type M o m = H.HalogenM State Action () o m

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
  MoveQueue from to -> send Cmd RFire ("move " <> show from <> " " <> show to)
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

-- | The most results one search returns. MPD sends a reply in one piece
-- | and drops the client if it does not fit its output buffer, so the
-- | page asks for a window rather than everything that matches.
searchLimit :: Int
searchLimit = 200

-- | The lowest level the bar itself can reach. The bar cannot silence the
-- | player: zero belongs to the mute button, which remembers what to come
-- | back to.
volumeFloor :: Int
volumeFloor = 1

-- | What one press of a stepper moves the level by.
volumeStep :: Int
volumeStep = 5

-- | Where unmute lands when no earlier level is remembered.
unmuteFloor :: Int
unmuteFloor = 20

maxVolumeOf :: State -> Int
maxVolumeOf st = maybe 100 _.maxVolume st.caps

-- | Ask for a level. The bar reports every pixel of a drag, so the value
-- | is held here and the sender below decides what reaches the player.
setVolume :: forall o m. MonadAff m => Int -> M o m Unit
setVolume v = do
  H.modify_ _ { volDraft = Just v }
  busy <- H.gets _.volSending
  unless busy do
    H.modify_ _ { volSending = true }
    void (H.fork sendVolume)

-- | How far one step of the glide moves, and how long a step lasts. A
-- | press or a drag sets the target; the level walks to it rather than
-- | jumping, which is gentler on speakers and reads as deliberate rather
-- | than abrupt. A full-scale move takes about half a second.
volumeGlideStep :: Int
volumeGlideStep = 4

volumeGlideMs :: Number
volumeGlideMs = 40.0

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

-- | The volume socket. It carries one line per change and its replies are
-- | not read: the level the page shows always comes from MPD, which
-- | reports the mixer whoever moved it.
connectVolume :: forall o m. MonadAff m => String -> M o m Unit
connectVolume path = do
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just VolOpened))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just VolClosed))
  H.modify_ _ { volLink = Just { socket, ready: false } }

-- | Has MPD reported the level the page asked for, give or take a step.
arrived :: Maybe Int -> Maybe Int -> Boolean
arrived want got = case want, got of
  Just a, Just b -> a - b <= 1 && b - a <= 1
  _, _ -> false

-- | The level to show: the press just made, else what MPD last reported.
shownVolume :: State -> Maybe Int
shownVolume st = case st.volDraft of
  Just v -> Just v
  Nothing -> st.status.volume

isSticker :: Req -> Boolean
isSticker = case _ of
  RSticker _ -> true
  _ -> false

-- | Which page this is, from the path it was opened at.
roleFromPath :: String -> Effect Role
roleFromPath hostPath = do
  loc <- window >>= location
  p <- Location.pathname loc
  pure (if p == hostPath || p == hostPath <> "/" then Host else Guest)

-- | The nickname kept in this browser, made up on the first visit.
nicknameFor :: Effect String
nicknameFor = do
  storage <- window >>= localStorage
  kept <- Storage.getItem nicknameKey storage
  case kept of
    Just n -> pure n
    Nothing -> do
      a <- randomInt 0 (length adjectives - 1)
      b <- randomInt 0 (length animals - 1)
      let
        n = fromMaybe "quiet" (Array.index adjectives a) <> " " <> fromMaybe "otter" (Array.index animals b)
      Storage.setItem nicknameKey n storage
      pure n

adjectives :: Array String
adjectives =
  [ "amber", "brisk", "calm", "dusty", "early", "fuzzy", "gentle", "hollow"
  , "ivory", "jolly", "keen", "lucky", "mellow", "nimble", "olive", "plaid"
  , "quiet", "rusty", "sleepy", "tidy", "upbeat", "velvet", "witty", "zesty"
  ]

animals :: Array String
animals =
  [ "otter", "heron", "badger", "lynx", "moose", "finch", "newt", "ibis"
  , "puffin", "stoat", "tapir", "wren", "yak", "marten", "coot", "dingo"
  , "egret", "gecko", "hare", "kiwi", "loon", "mole", "osprey", "quail"
  ]

-- | Open one connection and route its events into actions.
socketUrl :: String -> Effect String
socketUrl path = do
  loc <- window >>= location
  proto <- Location.protocol loc
  host <- Location.host loc
  pure ((if proto == "https:" then "wss://" else "ws://") <> host <> path)

connect :: forall o m. MonadAff m => Conn -> M o m Unit
connect conn = do
  path <- H.gets (maybe "/ws" _.websocketPath <<< _.caps)
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just (Opened conn)))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just (Closed conn)))
  void $ H.subscribe $ HQE.eventListener WSE.onMessage target \ev -> do
    me <- ME.fromEvent ev
    s <- hush (runExcept (readString (ME.data_ me)))
    pure (Chunk conn s)
  setLink conn (Just { socket, ready: false, lines: [], partial: "" })

linkOf :: Conn -> State -> Maybe Link
linkOf = case _ of
  Cmd -> _.cmd
  Idle -> _.idle

setLink :: forall o m. Conn -> Maybe Link -> M o m Unit
setLink conn l = H.modify_ $ case conn of
  Cmd -> _ { cmd = l }
  Idle -> _ { idle = l }

modifyLink :: forall o m. Conn -> (Link -> Link) -> M o m Unit
modifyLink conn f = H.modify_ $ case conn of
  Cmd -> \st -> st { cmd = map f st.cmd }
  Idle -> \st -> st { idle = map f st.idle }

-- | One line to MPD. On the command connection the request is remembered,
-- | so its reply can be read against it.
send :: forall o m. MonadAff m => Conn -> Req -> String -> M o m Unit
send conn req line = do
  st <- H.get
  case linkOf conn st of
    Just k | k.ready -> do
      liftEffect (WS.sendString k.socket line)
      when (conn == Cmd) (H.modify_ _ { asked = snoc st.asked req })
    _ -> pure unit

refreshAll :: forall o m. MonadAff m => M o m Unit
refreshAll = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  send Cmd RQueue "playlistinfo"
  send Cmd RStats "stats"

browse :: forall o m. MonadAff m => String -> M o m Unit
browse p = send Cmd (RBrowse p) ("lsinfo " <> Mpd.quote p)

-- | The idle connection's reply: which subsystems changed.
changed :: forall o m. MonadAff m => Array String -> M o m Unit
changed block = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  when (elem "changed: playlist" block) (send Cmd RQueue "playlistinfo")
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
    H.modify_ _ { current = cur }
    for_ cur \s -> askSticker s.file
  RQueue -> do
    let
      q = Mpd.parseSongs block
    H.modify_ _ { queue = q }
    role <- H.gets _.role
    when (role == Host) (for_ q \s -> askSticker s.file)
  RStats -> H.modify_ _ { songs = Mpd.parseStats block }
  RBrowse p -> H.modify_ _ { path = p, entries = Mpd.parseEntries block }
  RSearch _ -> H.modify_ _ { entries = Mpd.parseEntries block }
  RSticker uri -> for_ (Mpd.parseSticker block) \who ->
    H.modify_ \st -> st { addedBy = (Tuple uri who) : filter (\(Tuple u _) -> u /= uri) st.addedBy }
  RFire -> pure unit

-- | Ask for a track's attribution once; the reply lands in addedBy.
askSticker :: forall o m. MonadAff m => String -> M o m Unit
askSticker uri = do
  known <- H.gets (lookup uri <<< _.addedBy)
  when (isNothing known && not (isStream uri)) do
    send Cmd (RSticker uri) ("sticker get song " <> Mpd.quote uri <> " " <> stickerName)

isStream :: String -> Boolean
isStream uri = isJust (indexOf (Pattern "://") uri)

-- ---------------------------------------------------------------- rendering

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
  , if st.role == Host then volumeBar st else HH.footer [ cls "me" ] [ HH.text ("you are " <> st.nickname) ]
  ]
  where
  online = maybe false _.ready st.cmd
  renderers = Array.filter (_ /= "mpd") (maybe [] _.modules st.caps)
  hasLibrary = maybe false _.library st.caps
  stations = maybe [] _.stations st.caps
  count = if null st.queue then "" else " (" <> show (length st.queue) <> ")"
  tabs = case st.role of
    Guest ->
      [ tab NowPlaying "Now playing" ]
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

nowPlaying :: forall m. State -> Array (H.ComponentHTML Action () m)
nowPlaying st =
  [ HH.div [ cls "now" ]
      [ HH.div [ cls "title" ] [ HH.text (maybe "Nothing queued" Mpd.songTitle st.current) ]
      , HH.div [ cls "line" ] [ HH.text (maybe "" Mpd.songLine st.current) ]
      , case st.current >>= \s -> whoAdded st s.file of
          Just who -> HH.div [ cls "added" ] [ HH.text ("added by " <> who) ]
          Nothing -> HH.text ""
      , if st.status.duration > 0.0 then progress st else HH.text ""
      ]
  ]
    <>
      ( if st.role == Host then
          [ HH.div [ cls "controls" ]
              [ HH.button [ HP.title "Previous", HE.onClick \_ -> Command "previous" ] [ icon "prev" ]
              , HH.button [ cls "primary big", HP.title playTitle, HE.onClick \_ -> Command playPause ] [ iconSized "lg" playGlyph ]
              , HH.button [ HP.title "Stop", HE.onClick \_ -> Command "stop" ] [ icon "stop" ]
              , HH.button [ HP.title "Next", HE.onClick \_ -> Command "next" ] [ icon "next" ]
              ]
          , HH.div [ cls "modes" ]
              [ toggle "Random" st.status.random ("random " <> flag st.status.random)
              , toggle "Repeat" st.status.repeat ("repeat " <> flag st.status.repeat)
              , toggle "Single" st.status.single ("single " <> flag st.status.single)
              , toggle "Consume" st.status.consume ("consume " <> flag st.status.consume)
              ]
          ]
        else
          [ HH.p [ cls "note" ] [ HH.text stateLine ] ]
      )
  where
  playPause = case st.status.state of
    Playing -> "pause 1"
    Paused -> "pause 0"
    Stopped -> "play"
  playGlyph = if st.status.state == Playing then "pause" else "play"
  playTitle = if st.status.state == Playing then "Pause" else "Play"
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

-- | The host's volume, on every view: mute, the bar, the level.
-- |
-- | The bar is a range input, so a drag and a tap both work and the arrow
-- | keys work on a desktop, with no geometry arithmetic and no FFI. What
-- | broke the first version was its placement: the hit area ran from the
-- | edge of the mute button, and the left edge of a range input is its
-- | minimum, so a thumb aimed at mute and landing a few pixels right
-- | silenced the room. Here the bar is the only thing between the mute
-- | button and the number, with a gap either side, its minimum is
-- | volumeFloor rather than zero, and the track is drawn from a CSS
-- | custom property this sets, so the fill always matches the thumb.
volumeBar :: forall m. State -> H.ComponentHTML Action () m
volumeBar st = case shownVolume st of
  Nothing -> HH.text ""
  Just v ->
    HH.div [ cls "volbar" ]
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
          -- While the field has focus it shows what is being typed, so a
          -- report from MPD landing between keystrokes cannot rewrite it.
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
    pct =
      if span > 0 then clamp 0.0 100.0 (toNumber (max volumeFloor v - volumeFloor) / toNumber span * 100.0)
      else 0.0

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
  [ HH.div [ cls "row-actions" ]
      [ HH.button [ HP.disabled (null st.queue), HE.onClick \_ -> Command "clear" ] [ HH.text "Clear queue" ] ]
  , if null st.queue then HH.p [ cls "empty" ] [ HH.text "The queue is empty. Add something from the library or pick a station." ]
    else HH.ul [ cls "list" ] (Array.mapWithIndex item st.queue)
  ]
  where
  lastIndex = length st.queue - 1
  -- Where the player is. Everything before it has been played, which is
  -- what dims those rows; with random on the order is not the order they
  -- were heard in, so nothing is dimmed.
  playing = st.status.song
  item i s =
    HH.li
      [ classes
          ( [ "song" ]
              <> (if Just pos == playing then [ "current" ] else [])
              <> (if not st.status.random && playing /= Nothing && Just pos < playing then [ "past" ] else [])
          )
      ]
      [ HH.div [ cls "reorder" ]
          [ HH.button
              [ HP.title "Move up", HP.disabled (i == 0), HE.onClick \_ -> MoveQueue pos (pos - 1) ]
              [ iconSized "sm" "up" ]
          , HH.button
              [ HP.title "Move down", HP.disabled (i == lastIndex), HE.onClick \_ -> MoveQueue pos (pos + 1) ]
              [ iconSized "sm" "down" ]
          ]
      , HH.button [ cls "grow", HE.onClick \_ -> PlayPos pos ]
          [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
          , HH.div [ cls "line" ]
              [ HH.text
                  ( joinWith " · "
                      (Array.filter (_ /= "") [ Mpd.songLine s, maybe "" (\w -> "added by " <> w) (whoAdded st s.file) ])
                  )
              ]
          ]
      , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
      , HH.button [ cls "ghost icon-btn", HP.title "Remove", HE.onClick \_ -> DeletePos pos ] [ iconSized "sm" "x" ]
      ]
    where
    -- The queue arrives in order, so the index is the position. Pos from
    -- MPD is used when it is there and the index covers a reply that left
    -- it out.
    pos = fromMaybe i s.pos

libraryView :: forall m. State -> Array (H.ComponentHTML Action () m)
libraryView st =
  [ HH.form [ cls "search", HE.onSubmit Search ]
      [ HH.input
          [ HP.type_ HP.InputSearch
          , HP.placeholder "Search artists, albums, titles"
          , HP.value st.query
          , HE.onValueInput SetQuery
          ]
      , HH.button [ HP.type_ HP.ButtonSubmit ] [ HH.text "Search" ]
      ]
  , scanBanner st
  , case st.searched of
      Just q ->
        HH.div [ cls "crumbs" ]
          [ HH.span [ cls "crumb-static" ]
              [ HH.text
                  ( "Results for \"" <> q <> "\""
                      <> (if length st.entries >= searchLimit then " (first " <> show searchLimit <> ")" else "")
                  )
              ]
          , HH.button [ cls "crumb", HE.onClick \_ -> Browse st.path ] [ HH.text "✕ back to folders" ]
          ]
      Nothing -> HH.div [ cls "crumbs" ] (crumb "" "Library" : Array.mapWithIndex part parts)
  , if st.role == Host then
      HH.div [ cls "row-actions" ]
        ( (if st.path == "" || st.searched /= Nothing then [] else
             [ HH.button [ HE.onClick \_ -> AddPath st.path ] [ HH.text "Add all" ]
             , HH.button [ cls "primary", HE.onClick \_ -> PlayPath st.path ] [ HH.text "Play all" ]
             ])
            <> [ HH.button [ cls "ghost", HP.disabled st.status.updating, HE.onClick \_ -> UpdateLibrary ]
                   [ HH.text (if st.status.updating then "Scanning…" else "Rescan library") ] ]
        )
    else if st.path == "" || st.searched /= Nothing then HH.text ""
    else HH.div [ cls "row-actions" ] [ HH.button [ HE.onClick \_ -> AddPath st.path ] [ HH.text "Add this folder" ] ]
  , if null st.entries then HH.p [ cls "empty" ] [ HH.text emptyText ]
    else HH.ul [ cls "list" ] (map entry st.entries)
  ]
  where
  parts = if st.path == "" then [] else split (Pattern "/") st.path
  part i name = crumb (joinWith "/" (take (i + 1) parts)) name
  crumb target label =
    HH.button [ cls "crumb", HE.onClick \_ -> Browse target ] [ HH.text label ]
  emptyText = case st.searched of
    Just _ -> if st.status.updating then "Nothing yet. The library is still being scanned; try again later." else "Nothing matches."
    Nothing -> if st.status.updating then "Nothing here yet. The library is still being scanned." else "Nothing here. If the library is empty, the NAS may not be mounted yet."
  entry = case _ of
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
    File s ->
      HH.li [ cls "song" ]
        ( [ HH.button [ cls "grow", HE.onClick \_ -> AddPath s.file ]
              [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
              , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
              ]
          , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
          ]
            <> (if st.role == Host then [ HH.button [ cls "ghost icon-btn", HP.title "Play this now", HE.onClick \_ -> PlayPath s.file ] [ iconSized "sm" "play" ] ] else [ HH.span [ cls "plus" ] [ iconSized "sm" "plus" ] ])
        )

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

-- | One glyph from the set in index.html, painted with the colour of
-- | whatever contains it.
icon :: forall w i. String -> HH.HTML w i
icon name = HH.span [ classes [ "i", "i-" <> name ] ] []

iconSized :: forall w i. String -> String -> HH.HTML w i
iconSized size name = HH.span [ classes [ "i", size, "i-" <> name ] ] []

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls = HP.class_ <<< HH.ClassName

classes :: forall r i. Array String -> HP.IProp (class :: String | r) i
classes = HP.classes <<< map HH.ClassName