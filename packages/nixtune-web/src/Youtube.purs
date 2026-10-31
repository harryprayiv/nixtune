-- | Queueing a track from a YouTube link: what the page sends to the
-- | helper in nix/module/youtube.nix, and what it makes of the replies.
-- |
-- | The helper does the work on the player: it checks the link, fetches
-- | the audio into the library on the NAS, has MPD index it and adds it to
-- | the queue. The page sends one line and shows what comes back. The new
-- | track reaches the queue view the way every change does, through MPD's
-- | idle connection, so nothing here touches the queue.
module Youtube
  ( submit
  , received
  , opened
  , closed
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), split, stripPrefix, trim)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Mpd as Mpd
import Net (connectYoutube)
import Types (M)
import Web.Event.Event (Event, preventDefault)
import Web.Socket.WebSocket as WS

-- | The field was submitted. One fetch at a time from this page: the
-- | helper runs them one at a time anyway, and a second link sent while
-- | the first is downloading would only queue behind it with no word on
-- | the page about which reply belongs to which.
submit :: forall o m. MonadAff m => Event -> M o m Unit
submit ev = do
  liftEffect (preventDefault ev)
  st <- H.get
  let
    url = trim st.ytText
  unless (url == "" || st.ytBusy) $ case st.ytLink of
    Just k | k.ready -> do
      liftEffect (WS.sendString k.socket ("get " <> url))
      H.modify_ _ { ytBusy = true, ytNote = Just "Sending the link to the player." }
    _ -> H.modify_ _ { ytNote = Just "The player's YouTube helper is not reachable." }

-- | A message from the helper. websocat frames by read rather than by
-- | line, but the helper writes one short line per reply and nothing
-- | else, so a message is one or more whole lines.
received :: forall o m. String -> M o m Unit
received raw = for_ (Array.filter (_ /= "") (map trim (split (Pattern "\n") raw))) line
  where
  line l = case stripPrefix (Pattern "fetching ") l, stripPrefix (Pattern "added ") l, stripPrefix (Pattern "err ") l of
    Just _, _, _ ->
      H.modify_ _ { ytNote = Just "Downloading. The track joins the end of the queue when it is on the NAS." }
    _, Just uri, _ ->
      H.modify_ _ { ytBusy = false, ytText = "", ytNote = Just ("Queued: " <> Mpd.basename uri) }
    _, _, Just why ->
      H.modify_ _ { ytBusy = false, ytNote = Just ("Not queued: " <> why) }
    _, _, _ -> pure unit

opened :: forall o m. M o m Unit
opened = H.modify_ \st -> st { ytLink = map (_ { ready = true }) st.ytLink }

-- | The socket went away: whatever was under way will not report back on
-- | it, so the field is freed, and the socket is opened again.
closed :: forall o m. MonadAff m => M o m Unit
closed = do
  busy <- H.gets _.ytBusy
  H.modify_ _ { ytLink = Nothing, ytBusy = false }
  when busy (H.modify_ _ { ytNote = Just "The connection to the helper dropped. The track may still arrive in the queue." })
  H.liftAff (delay (Milliseconds 2000.0))
  path <- H.gets (\st -> st.caps >>= _.youtubePath)
  for_ path connectYoutube