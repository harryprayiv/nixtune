-- | Queueing tracks from a YouTube link: what the page sends to the helper
-- | in nix/module/youtube.nix, and what it makes of the replies.
-- |
-- | The helper does the work on the player: it checks the link, fetches
-- | the audio into the library on the NAS, has MPD index it and adds it to
-- | the queue, one video at a time, in playlist order for a playlist. The
-- | page sends one line and shows what comes back. Each track reaches the
-- | queue view the way every change does, through MPD's idle connection,
-- | so nothing here touches the queue.
-- |
-- | The replies, one per line (youtube.nix has the full description):
-- |
-- |   playlist <n>            a playlist, of which n videos will be fetched
-- |   fetching <id> <i>/<n>   video i of n is being fetched
-- |   added <uri>             it is in the queue
-- |   skip <id> <reason>      it is not, and why
-- |   done <added>/<n>        the request is finished
-- |   err <reason>            the request queued nothing at all
module Youtube
  ( submit
  , received
  , opened
  , closed
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), drop, indexOf, split, take, trim)
import Data.Tuple (Tuple(..))
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Mpd as Mpd
import Net (connectYoutube)
import Types (M, State)
import Web.Event.Event (Event, preventDefault)
import Web.Socket.WebSocket as WS

-- | The field was submitted. One request at a time from this page: the
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
      H.modify_ _
        { ytBusy = true
        , ytCount = { at: 0, total: 0 }
        , ytNote = Just "Sending the link to the player."
        }
    _ -> H.modify_ _ { ytNote = Just "The player's YouTube helper is not reachable." }

-- | A message from the helper. websocat frames by read rather than by
-- | line, but the helper writes one short line per reply and nothing
-- | else, so a message is one or more whole lines.
received :: forall o m. String -> M o m Unit
received raw = for_ (Array.filter (_ /= "") (map trim (split (Pattern "\n") raw))) line
  where
  line l = case firstWord l of
    Tuple "playlist" n ->
      let
        total = fromMaybe 0 (Int.fromString n)
      in
        H.modify_ _
          { ytCount = { at: 0, total }
          , ytNote = Just ("Found " <> show total <> " videos. Each joins the end of the queue as it lands on the NAS.")
          }
    Tuple "fetching" rest ->
      let
        count = fromMaybe { at: 1, total: 1 } (fraction (secondWord rest))
      in
        H.modify_ _
          { ytCount = count
          , ytNote = Just
              ( if count.total > 1 then "Downloading " <> show count.at <> " of " <> show count.total <> "."
                else "Downloading. The track joins the end of the queue when it is on the NAS."
              )
          }
    Tuple "added" uri ->
      H.modify_ \st -> st { ytNote = Just (counted st "Queued" <> Mpd.basename uri) }
    Tuple "skip" rest ->
      H.modify_ \st -> st { ytNote = Just (counted st (if st.ytCount.total > 1 then "Skipped" else "Not queued") <> secondWord rest) }
    Tuple "done" tally ->
      let
        result = fromMaybe { at: 0, total: 0 } (fraction tally)
      in
        H.modify_ \st -> st
          { ytBusy = false
          , ytText = if result.at > 0 then "" else st.ytText
          , ytNote =
              if result.total > 1 then Just ("Queued " <> show result.at <> " of " <> show result.total <> " from the playlist.")
              else st.ytNote
          }
    Tuple "err" why ->
      H.modify_ _ { ytBusy = false, ytNote = Just ("Not queued: " <> why) }
    _ -> pure unit

-- | "Queued: ", or "Queued 3 of 12: " while a playlist is under way.
counted :: State -> String -> String
counted st word =
  if st.ytCount.total > 1 then word <> " " <> show st.ytCount.at <> " of " <> show st.ytCount.total <> ": "
  else word <> ": "

-- | A line's first word and the rest of it.
firstWord :: String -> Tuple String String
firstWord l = case indexOf (Pattern " ") l of
  Just i -> Tuple (take i l) (drop (i + 1) l)
  Nothing -> Tuple l ""

-- | Everything after the first word: the video id is dropped from
-- | "<id> <i>/<n>" and from "<id> <reason>".
secondWord :: String -> String
secondWord l = case firstWord l of
  Tuple _ rest -> rest

-- | "3/12" as three of twelve.
fraction :: String -> Maybe { at :: Int, total :: Int }
fraction s = case split (Pattern "/") s of
  [ a, b ] -> do
    at <- Int.fromString a
    total <- Int.fromString b
    pure { at, total }
  _ -> Nothing

opened :: forall o m. M o m Unit
opened = H.modify_ \st -> st { ytLink = map (_ { ready = true }) st.ytLink }

-- | The socket went away: whatever was under way will not report back on
-- | it, so the field is freed, and the socket is opened again. The helper
-- | does not stop when its connection closes; it finishes the request, so
-- | the rest of a playlist still arrives in the queue.
closed :: forall o m. MonadAff m => M o m Unit
closed = do
  busy <- H.gets _.ytBusy
  H.modify_ _ { ytLink = Nothing, ytBusy = false }
  when busy (H.modify_ _ { ytNote = Just "The connection to the helper dropped. The player carries on, so the tracks still arrive in the queue." })
  H.liftAff (delay (Milliseconds 2000.0))
  path <- H.gets (\st -> st.caps >>= _.youtubePath)
  for_ path connectYoutube