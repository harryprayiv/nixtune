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
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.String (Pattern(..), indexOf, joinWith, split, trim)
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

type Link = { socket :: WebSocket, ready :: Boolean, lines :: Array String }

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
  -- Volume the slider shows while a drag is in flight, and whether a
  -- setvol is being sent for it. While a draft exists, MPD's own reports
  -- do not move the slider under the finger.
  , volDraft :: Maybe Int
  , volBusy :: Boolean
  -- The level to return to when unmuting. MPD has no mute of its own.
  , volBeforeMute :: Maybe Int
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
  , volBusy: false
  , volBeforeMute: Nothing
  }

data Action
  = Init
  | Opened Conn
  | Closed Conn
  | Line Conn String
  | Tick
  | Open View
  | Command String
  | SetVolume String
  | ToggleMute
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
        { emitter, listener } <- liftEffect HS.create
        _ <- liftEffect (setInterval 1000 (HS.notify listener Tick))
        void (H.subscribe emitter)
  Opened _ -> pure unit
  Closed conn -> do
    setLink conn Nothing
    H.modify_ _ { error = Just "The player went away. Reconnecting.", asked = [] }
    H.liftAff (delay (Milliseconds 2000.0))
    connect conn
  Line conn l
    | Mpd.isGreeting l -> do
        modifyLink conn _ { ready = true }
        H.modify_ _ { error = Nothing }
        case conn of
          Cmd -> refreshAll
          Idle -> send Idle RFire idleCommand
    | Mpd.isEnd l -> do
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
    | otherwise -> modifyLink conn \k -> k { lines = snoc k.lines l }
  Tick -> do
    H.modify_ \st ->
      let
        st' = st { ticks = st.ticks + 1 }
      in
        if st.status.state == Playing && st.status.duration > 0.0 && st.status.elapsed < st.status.duration then
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
  SetVolume s -> do
    top <- H.gets (maybe 100 _.maxVolume <<< _.caps)
    case fromString s of
      Nothing -> pure unit
      Just raw -> do
        let
          v = clamp 0 top raw
        busy <- H.gets _.volBusy
        H.modify_ _ { volDraft = Just v, volBeforeMute = Nothing }
        unless busy do
          H.modify_ _ { volBusy = true }
          void (H.fork flushVolume)
  ToggleMute -> do
    st <- H.get
    case st.volBeforeMute, shownVolume st of
      Just back, _ -> do
        H.modify_ _ { volBeforeMute = Nothing, volDraft = Just back }
        send Cmd RFire ("setvol " <> show back)
      Nothing, Just v | v > 0 -> do
        H.modify_ _ { volBeforeMute = Just v, volDraft = Just 0 }
        send Cmd RFire "setvol 0"
      _, _ -> pure unit
  Browse p -> do
    H.modify_ _ { searched = Nothing, query = "" }
    browse p
  SetQuery q -> H.modify_ _ { query = q }
  Search ev -> do
    liftEffect (preventDefault ev)
    q <- H.gets (trim <<< _.query)
    unless (q == "") do
      H.modify_ _ { searched = Just q }
      send Cmd (RSearch q) ("search any " <> Mpd.quote q)
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

-- | Send the slider's latest value, at most one setvol per 80 ms, until
-- | the value stops changing; then let MPD's reports drive the slider again.
flushVolume :: forall o m. MonadAff m => M o m Unit
flushVolume = do
  draft <- H.gets _.volDraft
  case draft of
    Nothing -> H.modify_ _ { volBusy = false }
    Just v -> do
      send Cmd RFire ("setvol " <> show v)
      H.liftAff (delay (Milliseconds 80.0))
      again <- H.gets _.volDraft
      if again == Just v then H.modify_ _ { volBusy = false, volDraft = Nothing }
      else flushVolume

-- | The level the slider shows: the drag in flight, else MPD's.
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
connect :: forall o m. MonadAff m => Conn -> M o m Unit
connect conn = do
  path <- H.gets (maybe "/ws" _.websocketPath <<< _.caps)
  url <- liftEffect do
    loc <- window >>= location
    proto <- Location.protocol loc
    host <- Location.host loc
    pure ((if proto == "https:" then "wss://" else "ws://") <> host <> path)
  socket <- liftEffect (WS.create url [])
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just (Opened conn)))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just (Closed conn)))
  void $ H.subscribe $ HQE.eventListener WSE.onMessage target \ev -> do
    me <- ME.fromEvent ev
    s <- hush (runExcept (readString (ME.data_ me)))
    pure (Line conn s)
  setLink conn (Just { socket, ready: false, lines: [] })

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
  RStatus -> H.modify_ _ { status = Mpd.parseStatus block }
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
      , if st.status.duration > 0.0 then progress st.status else HH.text ""
      ]
  ]
    <>
      ( if st.role == Host then
          [ HH.div [ cls "controls" ]
              [ HH.button [ HE.onClick \_ -> Command "previous" ] [ HH.text "⏮" ]
              , HH.button [ cls "primary big", HE.onClick \_ -> Command playPause ] [ HH.text playGlyph ]
              , HH.button [ HE.onClick \_ -> Command "stop" ] [ HH.text "⏹" ]
              , HH.button [ HE.onClick \_ -> Command "next" ] [ HH.text "⏭" ]
              ]
          , HH.div [ cls "modes" ]
              [ toggle "Random" st.status.random ("random " <> flag st.status.random)
              , toggle "Repeat" st.status.repeat ("repeat " <> flag st.status.repeat)
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
  playGlyph = if st.status.state == Playing then "⏸" else "▶"
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

-- | The host's volume, on every view: mute, slider, level. Pinned to the
-- | bottom of the page so it is under the thumb whatever is on screen.
volumeBar :: forall m. State -> H.ComponentHTML Action () m
volumeBar st = case shownVolume st of
  Nothing -> HH.text ""
  Just v ->
    HH.div [ cls "volbar" ]
      [ HH.button
          [ classes ([ "mute" ] <> (if muted then [ "on" ] else []))
          , HP.title (if muted then "Unmute" else "Mute")
          , HE.onClick \_ -> ToggleMute
          ]
          [ HH.text (if muted then "🔇" else "🔊") ]
      , HH.input
          [ HP.type_ HP.InputRange
          , HP.min 0.0
          , HP.max (toNumber top)
          , HP.step (HP.Step 1.0)
          , HP.value (show v)
          , HE.onValueInput SetVolume
          ]
      , HH.span [ cls "level" ] [ HH.text (show v) ]
      ]
  where
  top = maybe 100 _.maxVolume st.caps
  muted = isJust st.volBeforeMute || v == 0
    where
    v = fromMaybe 0 (shownVolume st)

progress :: forall w i. Status -> HH.HTML w i
progress s =
  HH.div [ cls "progress" ]
    [ HH.span_ [ HH.text (Mpd.clock s.elapsed) ]
    , HH.div [ cls "bar" ]
        [ HH.div [ cls "fill", HP.style ("width:" <> show pct <> "%") ] [] ]
    , HH.span_ [ HH.text (Mpd.clock s.duration) ]
    ]
  where
  pct = if s.duration > 0.0 then clamp 0.0 100.0 (s.elapsed / s.duration * 100.0) else 0.0

queueView :: forall m. State -> Array (H.ComponentHTML Action () m)
queueView st =
  [ HH.div [ cls "row-actions" ]
      [ HH.button [ HP.disabled (null st.queue), HE.onClick \_ -> Command "clear" ] [ HH.text "Clear queue" ] ]
  , if null st.queue then HH.p [ cls "empty" ] [ HH.text "The queue is empty. Add something from the library or pick a station." ]
    else HH.ul [ cls "list" ] (map item st.queue)
  ]
  where
  item s =
    HH.li
      [ classes ([ "song" ] <> (if s.pos /= Nothing && s.pos == st.status.song then [ "current" ] else [])) ]
      [ HH.button [ cls "grow", HE.onClick \_ -> PlayPos (fromMaybe 0 s.pos) ]
          [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
          , HH.div [ cls "line" ]
              [ HH.text
                  ( joinWith " · "
                      (Array.filter (_ /= "") [ Mpd.songLine s, maybe "" (\w -> "added by " <> w) (whoAdded st s.file) ])
                  )
              ]
          ]
      , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
      , HH.button [ cls "ghost", HE.onClick \_ -> DeletePos (fromMaybe 0 s.pos) ] [ HH.text "✕" ]
      ]

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
          [ HH.span [ cls "crumb-static" ] [ HH.text ("Results for \"" <> q <> "\"") ]
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
        [ HH.button [ cls "grow", HE.onClick \_ -> Browse d ] [ HH.text ("📁 " <> Mpd.basename d) ]
        , HH.button [ cls "ghost", HE.onClick \_ -> AddPath d ] [ HH.text "+" ]
        ]
    Playlist p ->
      if st.role == Host then
        HH.li [ cls "dir" ]
          [ HH.button [ cls "grow", HE.onClick \_ -> Command ("load " <> Mpd.quote p) ] [ HH.text ("📄 " <> p) ] ]
      else HH.text ""
    File s ->
      HH.li [ cls "song" ]
        ( [ HH.button [ cls "grow", HE.onClick \_ -> AddPath s.file ]
              [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
              , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
              ]
          , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
          ]
            <> (if st.role == Host then [ HH.button [ cls "ghost", HE.onClick \_ -> PlayPath s.file ] [ HH.text "▶" ] ] else [ HH.span [ cls "plus" ] [ HH.text "+" ] ])
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

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls = HP.class_ <<< HH.ClassName

classes :: forall r i. Array String -> HP.IProp (class :: String | r) i
classes = HP.classes <<< map HH.ClassName