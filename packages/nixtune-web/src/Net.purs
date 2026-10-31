-- | The sockets. Two to MPD through websocat, and one to the volume
-- | helper when the host has one. Opening them, remembering what was
-- | asked on the command connection, and the handful of requests the
-- | rest of the page sends by name.
module Net where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Array (snoc)
import Data.Either (hush)
import Data.Maybe (Maybe(..), maybe)
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
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
  setLink conn (Just { socket, ready: false, lines: [], partial: "", asked: [], queued: [] })

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

-- | What the page asks for the moment a connection comes up. The queue
-- | itself is NOT here: `status` carries its length, which is all any
-- | view but the Queue needs, and fetching a few hundred entries nobody
-- | is looking at is what made browsing stall after queueing a track.
refreshAll :: forall o m. MonadAff m => M o m Unit
refreshAll = do
  send Cmd RStatus "status"
  send Cmd RCurrent "currentsong"
  send Cmd RStats "stats"

browse :: forall o m. MonadAff m => String -> M o m Unit
browse p = send Lib (RBrowse p) ("lsinfo " <> Mpd.quote p)
