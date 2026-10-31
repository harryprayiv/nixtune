-- | The sockets. Three to MPD through websocat, and one to the volume
-- | helper when the host has one. Opening them, buffering what arrives on
-- | them, remembering what was asked, and the handful of requests the
-- | rest of the page sends by name.
-- |
-- | THE BUFFER IS NOT COMPONENT STATE, and that is the single most
-- | important thing in this module. Halogen renders the whole page
-- | synchronously on every state update whose result is a new value
-- | (Halogen.Aff.Driver.Eval, the State case). A reply to `list artist`
-- | on this library is around ten thousand lines; accumulating those
-- | through the state meant ten thousand renders for one reply, and
-- | opening the Library took the best part of a minute with the player
-- | answering in under a second. The partial tail and the lines of the
-- | reply being collected therefore live in Refs, which are written
-- | through liftEffect and never through modify_, so a whole reply costs
-- | exactly one render: the one that shows the result.
module Net where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Array (snoc)
import Data.Array as Array
import Data.Either (hush)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (Pattern(..), split, stripSuffix)
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import Foreign (readString)
import Halogen as H
import Halogen.Query.Event as HQE
import Mpd as Mpd
import Types (Action(..), Conn(..), Link, M, Req(..), State)
import Web.HTML (window)
import Web.HTML.Location as Location
import Web.HTML.Window (location)
import Web.Socket.Event.EventTypes as WSE
import Web.Socket.Event.MessageEvent as ME
import Web.Socket.WebSocket as WS

-- | A path on this host as a websocket URL, with the scheme the page was
-- | served over.
socketUrl :: String -> Effect String
socketUrl path = do
  loc <- window >>= location
  proto <- Location.protocol loc
  host <- Location.host loc
  pure ((if proto == "https:" then "wss://" else "ws://") <> host <> path)

connect :: forall o m. MonadAff m => Conn -> M o m Unit
connect conn = do
  st <- H.modify \s -> s { sockets = s.sockets + 1 }
  let
    serial = st.sockets
    path = maybe "/ws" _.websocketPath st.caps
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  partial <- liftEffect (Ref.new "")
  block <- liftEffect (Ref.new "")
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just (Opened conn serial)))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just (Closed conn serial)))
  void $ H.subscribe $ HQE.eventListener WSE.onMessage target \ev -> do
    me <- ME.fromEvent ev
    s <- hush (runExcept (readString (ME.data_ me)))
    pure (Chunk conn serial s)
  setLink conn (Just { socket, serial, ready: false, asked: [], queued: [], partial, block })

-- | This connection's socket, when the event that arrived came from the
-- | socket the connection is actually using.
liveLink :: Conn -> Int -> State -> Maybe Link
liveLink conn serial st = case linkOf conn st of
  Just k | k.serial == serial -> Just k
  _ -> Nothing

-- | Drop a connection and open another in its place.
-- |
-- | MPD has no way to cancel a command it has started, and it answers one
-- | command at a time per connection in the order they arrived. So a
-- | click that lands while a large listing is in flight waits for that
-- | listing, and then for everything queued behind it, before the player
-- | even reads what the click asked for. Closing the socket is the
-- | cancel: the replies to the work nobody wants any more are never
-- | delivered, and what the click asked for goes out on a connection with
-- | nothing in front of it. Requests made before the new socket has
-- | greeted are held by `send` and flushed by the greeting, so nothing is
-- | lost in the gap.
reopen :: forall o m. MonadAff m => Conn -> M o m Unit
reopen conn = do
  st <- H.get
  for_ (linkOf conn st) \k -> liftEffect (WS.close k.socket)
  setLink conn Nothing
  connect conn
  where
  for_ m f = maybe (pure unit) f m

-- | Is this connection waiting on anything. A click only has to cancel
-- | when there is something to cancel.
busy :: Conn -> State -> Boolean
busy conn st = case linkOf conn st of
  Just k -> not (Array.null k.asked) || not (Array.null k.queued)
  Nothing -> false

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

-- | The YouTube helper's socket. Unlike the volume socket its replies
-- | are read: the helper says when a fetch starts, when the track is in
-- | the queue, and why when it is not.
connectYoutube :: forall o m. MonadAff m => String -> M o m Unit
connectYoutube path = do
  url <- liftEffect (socketUrl path)
  socket <- liftEffect (WS.create url [])
  let
    target = WS.toEventTarget socket
  void $ H.subscribe $ HQE.eventListener WSE.onOpen target (const (Just YtOpened))
  void $ H.subscribe $ HQE.eventListener WSE.onClose target (const (Just YtClosed))
  void $ H.subscribe $ HQE.eventListener WSE.onMessage target \ev -> do
    me <- ME.fromEvent ev
    s <- hush (runExcept (readString (ME.data_ me)))
    pure (YtChunk s)
  H.modify_ _ { ytLink = Just { socket, ready: false } }

linkOf :: Conn -> State -> Maybe Link
linkOf = case _ of
  Cmd -> _.cmd
  Idle -> _.idle
  Lib -> _.lib

setLink :: forall o m. Conn -> Maybe Link -> M o m Unit
setLink conn l = H.modify_ $ case conn of
  Cmd -> _ { cmd = l }
  Idle -> _ { idle = l }
  Lib -> _ { lib = l }

modifyLink :: forall o m. Conn -> (Link -> Link) -> M o m Unit
modifyLink conn f = H.modify_ $ case conn of
  Cmd -> \st -> st { cmd = map f st.cmd }
  Idle -> \st -> st { idle = map f st.idle }
  Lib -> \st -> st { lib = map f st.lib }

-- | What one message off the wire turns into: the complete lines it
-- | finished, with the unfinished tail left in the Ref for the next one.
-- |
-- | websocat frames by TCP read and not by line, so a message may carry
-- | several lines, part of one, or the end of one and the start of
-- | another. Only the tail is ever re-split, so this stays linear in the
-- | size of the reply however it is chopped up.
takeLines :: Link -> String -> Effect (Array String)
takeLines k raw = do
  held <- Ref.read k.partial
  let
    pieces = split (Pattern "\n") (held <> raw)
    complete = fromMaybe [] (Array.init pieces)
  Ref.write (fromMaybe "" (Array.last pieces)) k.partial
  pure (Array.filter (_ /= "") (map (\l -> fromMaybe l (stripSuffix (Pattern "\r") l)) complete))

-- | Add one line to the reply being collected. A string grows in place in
-- | every engine this runs on, where an array would be copied whole for
-- | every line of a ten thousand line reply.
pushLine :: Link -> String -> Effect Unit
pushLine k l = Ref.modify_ (_ <> l <> "\n") k.block

-- | The reply that just ended, as its lines, and the buffer emptied ready
-- | for the next one.
takeBlock :: Link -> Effect (Array String)
takeBlock k = do
  text <- Ref.read k.block
  Ref.write "" k.block
  pure (Array.filter (_ /= "") (split (Pattern "\n") text))

-- | One line to MPD, on the connection that owns that kind of work. The
-- | request joins that connection's own queue, so its reply is read
-- | against it and not against something another connection asked for.
-- | The idle connection sends only `idle` and keeps no queue.
send :: forall o m. MonadAff m => Conn -> Req -> String -> M o m Unit
send conn req line = do
  st <- H.get
  case linkOf conn st of
    -- Not greeted yet: hold it rather than drop it, and the greeting
    -- flushes what has piled up.
    Just k | not k.ready -> modifyLink conn \l -> l { queued = snoc l.queued { req, line } }
    Just k -> do
      liftEffect (WS.sendString k.socket line)
      when (conn /= Idle) (modifyLink conn \l -> l { asked = snoc l.asked req })
    _ -> pure unit

-- | What the page asks for the moment the command connection comes up.
-- | The queue itself is NOT here: `status` carries its length, which is
-- | all any view but the Queue needs, and fetching a few hundred entries
-- | nobody is looking at is what made browsing stall after queueing a
-- | track.
refreshAll :: forall o m. MonadAff m => M o m Unit
refreshAll = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  send Cmd RStats "stats"
  -- Whether MPD can match a regular expression. Multi-value selections
  -- in the tag browser depend on it; the answer changes only with a
  -- different MPD build, so it is asked once per connection.
  send Cmd RProbe "find \"(title =~ '^$')\" window 0:1"

browse :: forall o m. MonadAff m => String -> M o m Unit
browse p = send Lib (RBrowse p) ("lsinfo " <> Mpd.quote p)