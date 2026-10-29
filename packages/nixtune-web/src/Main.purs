-- | The player's page.
-- |
-- | Two websockets to MPD, each bridged by websocat to the daemon's TCP
-- | port. One carries commands and their replies, in order, so the page
-- | keeps a queue of what it asked and reads each reply against the head
-- | of that queue. The other sits in MPD's `idle` command and is told what
-- | changed; the page then asks the first connection for the new status.
-- | Nothing is polled: a change on the DAC, from AirPlay, from a phone's
-- | MPD client or from this page, arrives the same way.
-- |
-- | What the page may show is read once from capabilities.json, which Nix
-- | wrote when the host was built: a renderer that is off has no badge, a
-- | host with no library has no library tab, the volume slider stops at the
-- | declared maximum.
module Main (main) where

import Prelude

import Caps (Caps, Station)
import Caps as Caps
import Control.Monad.Except (runExcept)
import Data.Array (elem, head, length, null, snoc, take, uncons, (:))
import Data.Array as Array
import Data.Either (Either(..), hush)
import Data.Int (fromString, toNumber)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (Pattern(..), joinWith, split)
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
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
import Web.HTML (window)
import Web.HTML.Location as Location
import Web.HTML.Window (location)
import Web.Socket.Event.EventTypes as WSE
import Web.Socket.Event.MessageEvent as ME
import Web.Socket.WebSocket (WebSocket)
import Web.Socket.WebSocket as WS

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

data View = NowPlaying | Queue | Library | Radio

derive instance eqView :: Eq View

-- | The two connections.
data Conn = Cmd | Idle

derive instance eqConn :: Eq Conn

-- | What a reply on the command connection is for.
data Req = RStatus | RCurrent | RQueue | RBrowse String | RFire

type Link = { socket :: WebSocket, ready :: Boolean, lines :: Array String }

type State =
  { caps :: Maybe Caps
  , view :: View
  , cmd :: Maybe Link
  , idle :: Maybe Link
  , asked :: Array Req
  , status :: Status
  , current :: Maybe Song
  , queue :: Array Song
  , path :: String
  , entries :: Array Entry
  , error :: Maybe String
  }

initial :: State
initial =
  { caps: Nothing
  , view: NowPlaying
  , cmd: Nothing
  , idle: Nothing
  , asked: []
  , status: Mpd.emptyStatus
  , current: Nothing
  , queue: []
  , path: ""
  , entries: []
  , error: Nothing
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
  | Browse String
  | PlayStation Station
  | AddPath String
  | PlayPath String
  | PlayPos Int
  | DeletePos Int

idleCommand :: String
idleCommand = "idle player mixer playlist options database"

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
        H.modify_ _ { caps = Just caps }
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
        when (Mpd.isError l) (H.modify_ _ { error = Just l })
        case conn of
          Idle -> do
            changed block
            send Idle RFire idleCommand
          Cmd -> case uncons st.asked of
            Nothing -> pure unit
            Just { head: req, tail } -> do
              H.modify_ _ { asked = tail }
              reply req block
    | otherwise -> modifyLink conn \k -> k { lines = snoc k.lines l }
  Tick -> H.modify_ \st ->
    if st.status.state == Playing && st.status.duration > 0.0 && st.status.elapsed < st.status.duration then
      st { status = st.status { elapsed = st.status.elapsed + 1.0 } }
    else st
  Open v -> do
    H.modify_ _ { view = v }
    when (v == Library) do
      p <- H.gets _.path
      browse p
  Command c -> send Cmd RFire c
  SetVolume s -> do
    top <- H.gets (maybe 100 _.maxVolume <<< _.caps)
    case fromString s of
      Just v -> send Cmd RFire ("setvol " <> show (clamp 0 top v))
      Nothing -> pure unit
  Browse p -> browse p
  PlayStation s -> do
    send Cmd RFire "clear"
    send Cmd RFire ("add " <> Mpd.quote s.url)
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }
  AddPath p -> send Cmd RFire ("add " <> Mpd.quote p)
  PlayPath p -> do
    send Cmd RFire "clear"
    send Cmd RFire ("add " <> Mpd.quote p)
    send Cmd RFire "play"
    H.modify_ _ { view = NowPlaying }
  PlayPos n -> send Cmd RFire ("play " <> show n)
  DeletePos n -> send Cmd RFire ("delete " <> show n)

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

browse :: forall o m. MonadAff m => String -> M o m Unit
browse p = send Cmd (RBrowse p) ("lsinfo " <> Mpd.quote p)

-- | The idle connection's reply: which subsystems changed.
changed :: forall o m. MonadAff m => Array String -> M o m Unit
changed block = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  when (elem "changed: playlist" block) (send Cmd RQueue "playlistinfo")
  when (elem "changed: database" block) do
    st <- H.get
    when (st.view == Library) (browse st.path)

-- | A command connection's reply, read against what was asked.
reply :: forall o m. Req -> Array String -> M o m Unit
reply req block = case req of
  RStatus -> H.modify_ _ { status = Mpd.parseStatus block }
  RCurrent -> H.modify_ _ { current = head (Mpd.parseSongs block) }
  RQueue -> H.modify_ _ { queue = Mpd.parseSongs block }
  RBrowse p -> H.modify_ _ { path = p, entries = Mpd.parseEntries block }
  RFire -> pure unit

-- ---------------------------------------------------------------- rendering

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.main_
  [ HH.header [ cls "top" ]
      [ HH.div [ cls "brand" ]
          [ HH.span [ classes [ "dot", if online then "on" else "off" ] ] []
          , HH.span_ [ HH.text "nixtune" ]
          , HH.span [ cls "host" ] [ HH.text (maybe "" _.hostname st.caps) ]
          ]
      , HH.div [ cls "badges" ] (map badge renderers)
      ]
  , HH.nav [ cls "tabs" ]
      ( [ tab NowPlaying "Now playing", tab Queue ("Queue" <> count) ]
          <> (if hasLibrary then [ tab Library "Library" ] else [])
          <> (if null stations then [] else [ tab Radio "Radio" ])
      )
  , HH.section [ cls "page" ] $ case st.view of
      NowPlaying -> nowPlaying st
      Queue -> queueView st
      Library -> libraryView st
      Radio -> radioView stations
  , errorView st.error
  ]
  where
  online = maybe false _.ready st.cmd
  renderers = Array.filter (_ /= "mpd") (maybe [] _.modules st.caps)
  hasLibrary = maybe false _.library st.caps
  stations = maybe [] _.stations st.caps
  count = if null st.queue then "" else " (" <> show (length st.queue) <> ")"
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

nowPlaying :: forall m. State -> Array (H.ComponentHTML Action () m)
nowPlaying st =
  [ HH.div [ cls "now" ]
      [ HH.div [ cls "title" ] [ HH.text (maybe "Nothing queued" Mpd.songTitle st.current) ]
      , HH.div [ cls "line" ] [ HH.text (maybe "" Mpd.songLine st.current) ]
      , if st.status.duration > 0.0 then progress st.status else HH.text ""
      ]
  , HH.div [ cls "controls" ]
      [ HH.button [ HE.onClick \_ -> Command "previous" ] [ HH.text "⏮" ]
      , HH.button [ cls "primary big", HE.onClick \_ -> Command playPause ] [ HH.text playGlyph ]
      , HH.button [ HE.onClick \_ -> Command "stop" ] [ HH.text "⏹" ]
      , HH.button [ HE.onClick \_ -> Command "next" ] [ HH.text "⏭" ]
      ]
  , HH.div [ cls "modes" ]
      [ toggle "Random" st.status.random ("random " <> flag st.status.random)
      , toggle "Repeat" st.status.repeat ("repeat " <> flag st.status.repeat)
      ]
  , case st.status.volume of
      Just v ->
        HH.label [ cls "volume" ]
          [ HH.span_ [ HH.text ("Volume " <> show v) ]
          , HH.input
              [ HP.type_ HP.InputRange
              , HP.min 0.0
              , HP.max (toNumber top)
              , HP.step (HP.Step 1.0)
              , HP.value (show v)
              , HE.onValueInput SetVolume
              ]
          ]
      Nothing -> HH.text ""
  , if st.status.updating then HH.p [ cls "note" ] [ HH.text "Updating the library." ] else HH.text ""
  ]
  where
  top = maybe 100 _.maxVolume st.caps
  playPause = case st.status.state of
    Playing -> "pause 1"
    Paused -> "pause 0"
    Stopped -> "play"
  playGlyph = if st.status.state == Playing then "⏸" else "▶"
  flag b = if b then "0" else "1"
  toggle label on command =
    HH.button
      [ classes ([ "mode" ] <> (if on then [ "on" ] else []))
      , HE.onClick \_ -> Command command
      ]
      [ HH.text label ]

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
          , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
          ]
      , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
      , HH.button [ cls "ghost", HE.onClick \_ -> DeletePos (fromMaybe 0 s.pos) ] [ HH.text "✕" ]
      ]

libraryView :: forall m. State -> Array (H.ComponentHTML Action () m)
libraryView st =
  [ HH.div [ cls "crumbs" ] (crumb "" "Library" : Array.mapWithIndex part parts)
  , if st.path == "" then HH.text ""
    else HH.div [ cls "row-actions" ]
      [ HH.button [ HE.onClick \_ -> AddPath st.path ] [ HH.text "Add all" ]
      , HH.button [ cls "primary", HE.onClick \_ -> PlayPath st.path ] [ HH.text "Play all" ]
      ]
  , if null st.entries then HH.p [ cls "empty" ] [ HH.text "Nothing here. If the library is empty, the NAS may not be mounted yet." ]
    else HH.ul [ cls "list" ] (map entry st.entries)
  ]
  where
  parts = if st.path == "" then [] else split (Pattern "/") st.path
  part i name = crumb (joinWith "/" (take (i + 1) parts)) name
  crumb target label =
    HH.button [ cls "crumb", HE.onClick \_ -> Browse target ] [ HH.text label ]
  entry = case _ of
    Dir d ->
      HH.li [ cls "dir" ]
        [ HH.button [ cls "grow", HE.onClick \_ -> Browse d ] [ HH.text ("📁 " <> Mpd.basename d) ]
        , HH.button [ cls "ghost", HE.onClick \_ -> AddPath d ] [ HH.text "+" ]
        ]
    Playlist p ->
      HH.li [ cls "dir" ]
        [ HH.button [ cls "grow", HE.onClick \_ -> Command ("load " <> Mpd.quote p) ] [ HH.text ("📄 " <> p) ] ]
    File s ->
      HH.li [ cls "song" ]
        [ HH.button [ cls "grow", HE.onClick \_ -> AddPath s.file ]
            [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
            , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
            ]
        , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
        , HH.button [ cls "ghost", HE.onClick \_ -> PlayPath s.file ] [ HH.text "▶" ]
        ]

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

errorView :: forall w i. Maybe String -> HH.HTML w i
errorView = case _ of
  Just e -> HH.p [ cls "error" ] [ HH.text e ]
  Nothing -> HH.text ""

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls = HP.class_ <<< HH.ClassName

classes :: forall r i. Array String -> HP.IProp (class :: String | r) i
classes = HP.classes <<< map HH.ClassName
