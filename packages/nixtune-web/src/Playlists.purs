-- | Saved playlists: MPD's stored playlists, made and edited from the
-- | host's Queue view. This module performs the commands; PlaylistView
-- | draws them.
-- |
-- | A stored playlist is a file in MPD's playlist directory, which is in
-- | its state directory and outlives the queue, a restart and a reboot.
-- | Every change here is one MPD command against that file, and nothing
-- | is shown changed until MPD says it is: the commands that write a
-- | stored playlist raise the stored_playlist idle event, and the idle
-- | connection's answer to it (Main.changed) asks for the list and the
-- | open playlist again. That keeps two pages open on the same playlist
-- | in step, which a copy edited in the page would not.
-- |
-- |   save NAME [replace|append]   the queue as a playlist
-- |   load NAME                    a playlist onto the end of the queue
-- |   playlistmove NAME FROM TO    reorder one row
-- |   playlistdelete NAME POS      remove one row
-- |   rename OLD NEW, rm NAME      the playlist itself
-- |
-- | load and listplaylistinfo go through MPD's playlist plugins, which
-- | is why database.nix turns m3u and extm3u back on.
module Playlists
  ( refresh
  , setPane
  , editing
  , savedReply
  , songsReply
  , saveQueue
  , play
  , append
  , appendQueue
  , delete
  , rename
  , remove
  , move
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), contains, indexOf, splitAt, trim)
import Data.String as String
import Data.String.Common (localeCompare)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Mpd as Mpd
import Net (send)
import Types
  ( Conn(..)
  , M
  , PlArm(..)
  , QueuePane(..)
  , Req(..)
  , SavedPlaylist
  , State
  , clearConfirmMs
  )
import Web.Event.Event (Event, preventDefault)

-- | The playlist open for editing, if one is.
editing :: State -> Maybe String
editing st = case st.pane of
  PaneEdit n -> Just n
  _ -> Nothing

-- | Ask for the saved list, and for the open playlist's tracks.
refresh :: forall o m. MonadAff m => M o m Unit
refresh = do
  st <- H.get
  send Cmd RSaved "listplaylists"
  for_ (editing st) \n -> send Cmd (RPlaylistSongs n) ("listplaylistinfo " <> Mpd.quote n)

-- | Another pane. Opening a playlist starts its rename field at its
-- | name and its rows empty, so the previous playlist's rows are never
-- | shown under this one's name while the reply is on its way.
setPane :: forall o m. MonadAff m => QueuePane -> M o m Unit
setPane p = do
  H.modify_ \st -> st
    { pane = p
    , plArmed = Nothing
    , plNote = Nothing
    , plSongs = if p == st.pane then st.plSongs else []
    , plRename = case p of
        PaneEdit n -> n
        _ -> st.plRename
    }
  refresh

-- | listplaylists: "playlist: NAME" lines, each followed by its
-- | "Last-Modified:". Ordered by name the way the library columns are.
savedReply :: forall o m. Array String -> M o m Unit
savedReply block = H.modify_ _ { saved = Array.sortBy (\a b -> localeCompare a.name b.name) (parse block) }
  where
  parse :: Array String -> Array SavedPlaylist
  parse = Array.foldl step []
  step acc l = case keyValue l of
    Just { key: "playlist", value } -> Array.snoc acc { name: value, modified: "" }
    Just { key: "Last-Modified", value } -> case Array.unsnoc acc of
      Just { init, last } -> Array.snoc init (last { modified = value })
      Nothing -> acc
    _ -> acc

-- | One playlist's tracks, kept only while that playlist is the one open.
songsReply :: forall o m. String -> Array String -> M o m Unit
songsReply name block = H.modify_ \st ->
  if editing st == Just name then st { plSongs = Mpd.parseSongs block } else st

keyValue :: String -> Maybe { key :: String, value :: String }
keyValue l = case indexOf (Pattern ": ") l of
  Just i ->
    let
      { before, after } = splitAt i l
    in
      Just { key: before, value: String.drop 2 after }
  Nothing -> Nothing

-- | A name MPD will take: not empty, and without the characters it
-- | refuses in a playlist name. Nothing when it will.
badName :: String -> Maybe String
badName n
  | n == "" = Just "Give the playlist a name."
  | contains (Pattern "/") n = Just "A playlist name cannot contain a slash."
  | otherwise = Nothing

exists :: State -> String -> Boolean
exists st n = Array.any (\p -> p.name == n) st.saved

-- | The save-as field was submitted. A new name saves at once. A name
-- | already saved arms the button, and only a second press within a few
-- | seconds replaces that playlist with the queue.
saveQueue :: forall o m. MonadAff m => Event -> M o m Unit
saveQueue ev = do
  liftEffect (preventDefault ev)
  st <- H.get
  let
    name = trim st.plName
  case badName name of
    Just why -> note why
    Nothing
      | st.status.queueLength == 0 -> note "The queue is empty, so there is nothing to save."
      | exists st name ->
          if armedFor (ArmReplace name) st then do
            send Cmd RFire ("save " <> Mpd.quote name <> " replace")
            H.modify_ _ { plArmed = Nothing, plName = "", plNote = Just ("Replaced " <> name <> " with the queue.") }
          else do
            arm (ArmReplace name)
            note ("A playlist called " <> name <> " is already saved. Press Save again to replace it with the queue.")
      | otherwise -> do
          send Cmd RFire ("save " <> Mpd.quote name)
          H.modify_ _ { plName = "", plNote = Just ("Saved the queue as " <> name <> ".") }

-- | Replace the queue with a playlist and start it.
play :: forall o m. MonadAff m => String -> M o m Unit
play name = do
  send Cmd RFire "clear"
  send Cmd RFire ("load " <> Mpd.quote name)
  send Cmd RFire "play"
  H.modify_ _ { pane = PaneQueue, plArmed = Nothing, plNote = Just ("Playing " <> name <> ".") }

-- | A playlist onto the end of the queue.
append :: forall o m. MonadAff m => String -> M o m Unit
append name = do
  send Cmd RFire ("load " <> Mpd.quote name)
  note ("Added " <> name <> " to the end of the queue.")

-- | The queue onto the end of a playlist, which is how tracks get into
-- | one that already exists: queue them, then append.
appendQueue :: forall o m. MonadAff m => String -> M o m Unit
appendQueue name = do
  st <- H.get
  if st.status.queueLength == 0 then note "The queue is empty, so there is nothing to add."
  else do
    send Cmd RFire ("save " <> Mpd.quote name <> " append")
    note ("Added the queue to the end of " <> name <> ".")

-- | Delete a playlist, in two presses. The tracks are not touched; only
-- | the list of them goes.
delete :: forall o m. MonadAff m => String -> M o m Unit
delete name = do
  st <- H.get
  if armedFor (ArmDelete name) st then do
    send Cmd RFire ("rm " <> Mpd.quote name)
    H.modify_ \s -> s
      { plArmed = Nothing
      , pane = if editing s == Just name then PaneSaved else s.pane
      , plNote = Just ("Deleted " <> name <> ".")
      }
  else arm (ArmDelete name)

-- | The rename field of the open playlist was submitted.
rename :: forall o m. MonadAff m => Event -> M o m Unit
rename ev = do
  liftEffect (preventDefault ev)
  st <- H.get
  for_ (editing st) \old -> do
    let
      new = trim st.plRename
    case badName new of
      Just why -> note why
      Nothing
        | new == old -> pure unit
        | exists st new -> note ("A playlist called " <> new <> " is already saved.")
        | otherwise -> do
            send Cmd RFire ("rename " <> Mpd.quote old <> " " <> Mpd.quote new)
            H.modify_ _ { pane = PaneEdit new, plRename = new, plArmed = Nothing, plNote = Just ("Renamed " <> old <> " to " <> new <> ".") }

-- | One row out of the open playlist.
remove :: forall o m. MonadAff m => Int -> M o m Unit
remove pos = do
  st <- H.get
  for_ (editing st) \n -> send Cmd RFire ("playlistdelete " <> Mpd.quote n <> " " <> show pos)

-- | One row of the open playlist to another position, from a drag or an
-- | arrow key.
move :: forall o m. MonadAff m => Int -> Int -> M o m Unit
move from to = do
  st <- H.get
  for_ (editing st) \n ->
    when (from /= to) (send Cmd RFire ("playlistmove " <> Mpd.quote n <> " " <> show from <> " " <> show to))

note :: forall o m. String -> M o m Unit
note s = H.modify_ _ { plNote = Just s }

armedFor :: PlArm -> State -> Boolean
armedFor a st = map _.arm st.plArmed == Just a

-- | Arm a replace or a delete, and disarm it after clearConfirmMs unless
-- | a later press has armed something else since.
arm :: forall o m. MonadAff m => PlArm -> M o m Unit
arm a = do
  st <- H.modify \s -> s { plArmed = Just { arm: a, press: s.plTick + 1 }, plTick = s.plTick + 1 }
  let
    press = st.plTick
  void $ H.fork do
    H.liftAff (delay (Milliseconds clearConfirmMs))
    H.modify_ \s -> if map _.press s.plArmed == Just press then s { plArmed = Nothing } else s