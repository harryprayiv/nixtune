-- | The saved-playlist parts of the host's Queue view: the switch between
-- | the queue and the playlists, the save-as field under the queue, the
-- | list of saved playlists, and one playlist open for editing. State in,
-- | markup out; Playlists performs what the buttons name.
module PlaylistView
  ( paneSwitch
  , saveForm
  , savedView
  , editView
  ) where

import Prelude

import Data.Array (length, null)
import Data.Array as Array
import Data.Maybe (Maybe(..), maybe)
import Data.String (take)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Mpd as Mpd
import Reorder (rowRef, rowShift)
import Types (Action(..), PlArm(..), QueuePane(..), State)
import Ui (classes, cls, formatBadge, iconSized)
import Web.Event.Event (EventType(..))

-- | Queue or Playlists, with whatever else belongs on that row after it.
paneSwitch :: forall m. State -> Array (H.ComponentHTML Action () m) -> H.ComponentHTML Action () m
paneSwitch st rest =
  HH.div [ cls "modeswitch" ]
    ( [ HH.div [ cls "seg" ]
          [ seg (st.pane == PaneQueue) PaneQueue ("Queue" <> count st.status.queueLength)
          , seg (st.pane /= PaneQueue) PaneSaved ("Playlists" <> count (length st.saved))
          ]
      , HH.div [ cls "grow-space" ] []
      ]
        <> rest
    )
  where
  count n = if n == 0 then "" else " (" <> show n <> ")"
  seg on p label =
    HH.button
      [ classes ([ "segbtn" ] <> (if on then [ "on" ] else []))
      , HE.onClick \_ -> SetPane p
      ]
      [ HH.text label ]

-- | The queue as a new playlist, or over an old one in two presses.
saveForm :: forall m. State -> Array (H.ComponentHTML Action () m)
saveForm st =
  [ HH.div [ cls "libtop" ]
      [ HH.form [ cls "search", HE.onSubmit SaveQueue ]
          [ HH.input
              [ HP.type_ HP.InputText
              , HP.placeholder "Save the queue as a playlist"
              , HP.value st.plName
              , HE.onValueInput PlNameText
              ]
          , HH.button
              [ HP.type_ HP.ButtonSubmit
              , classes (if replacing then [ "mode", "clear", "armed" ] else [])
              , HP.disabled (st.plName == "" || st.status.queueLength == 0)
              ]
              [ HH.text (if replacing then "Replace" else "Save") ]
          ]
      ]
  ]
    <> noteOf st
  where
  replacing = case st.plArmed of
    Just { arm: ArmReplace _ } -> true
    _ -> false

-- | The playlists saved on the player.
savedView :: forall m. State -> Array (H.ComponentHTML Action () m)
savedView st =
  noteOf st
    <>
      [ if null st.saved then HH.p [ cls "empty" ] [ HH.text "No saved playlists yet. Build a queue, then save it from the Queue tab." ]
        else HH.ul [ cls "list" ] (map row st.saved)
      ]
  where
  row p =
    HH.li [ cls "song" ]
      [ HH.button [ cls "grow", HP.title "Open to edit", HE.onClick \_ -> SetPane (PaneEdit p.name) ]
          [ HH.div [ cls "title" ] [ HH.text p.name ]
          , HH.div [ cls "line" ] [ HH.text (if p.modified == "" then "" else "saved " <> take 10 p.modified) ]
          ]
      , HH.button [ cls "ghost icon-btn", HP.title "Play: replace the queue with this", HE.onClick \_ -> PlayPlaylist p.name ] [ iconSized "sm" "play" ]
      , HH.button [ cls "ghost icon-btn", HP.title "Add to the end of the queue", HE.onClick \_ -> AddPlaylist p.name ] [ iconSized "sm" "plus" ]
      , deleteButton st p.name (iconSized "sm" "x")
      ]

-- | One playlist, open: its name to change, what can be done with it,
-- | and its rows to reorder or remove.
editView :: forall m. State -> String -> Array (H.ComponentHTML Action () m)
editView st name =
  [ HH.div [ cls "crumbs" ]
      [ HH.button [ cls "crumb", HE.onClick \_ -> SetPane PaneSaved ] [ HH.text "Playlists" ]
      , HH.span [ cls "crumb crumb-static" ] [ HH.text name ]
      ]
  , HH.div [ cls "libtop" ]
      [ HH.form [ cls "search", HE.onSubmit RenamePlaylist ]
          [ HH.input
              [ HP.type_ HP.InputText
              , HP.placeholder "Playlist name"
              , HP.value st.plRename
              , HE.onValueInput RenameText
              ]
          , HH.button [ HP.type_ HP.ButtonSubmit, HP.disabled (st.plRename == name || st.plRename == "") ] [ HH.text "Rename" ]
          ]
      ]
  , HH.div [ cls "row-actions" ]
      [ HH.span [ cls "count" ] [ HH.text (tally (length st.plSongs)) ]
      , HH.div [ cls "grow-space" ] []
      , HH.button [ HP.disabled (null st.plSongs), HE.onClick \_ -> AddPlaylist name ] [ HH.text "Add to queue" ]
      , HH.button
          [ HP.disabled (st.status.queueLength == 0)
          , HP.title "Add every track in the queue to the end of this playlist"
          , HE.onClick \_ -> AppendQueueTo name
          ]
          [ HH.text "Append the queue" ]
      , HH.button [ cls "primary", HP.disabled (null st.plSongs), HE.onClick \_ -> PlayPlaylist name ] [ HH.text "Play" ]
      , deleteButton st name (HH.text "Delete playlist")
      ]
  ]
    <> noteOf st
    <>
      [ if not (Array.any (\p -> p.name == name) st.saved) && not (null st.saved) then
          HH.p [ cls "empty" ] [ HH.text "This playlist is not on the player any more." ]
        else if null st.plSongs then
          HH.p [ cls "empty" ] [ HH.text "This playlist is empty. Queue some tracks and use Append the queue." ]
        else
          HH.ul [ classes ([ "list" ] <> (if st.drag /= Nothing then [ "dragging" ] else [])) ] (Array.mapWithIndex row st.plSongs)
      ]
  where
  tally n = if n == 1 then "1 track" else show n <> " tracks"
  held = map _.from st.drag
  -- The rows carry the queue's refs and drag handlers: only one of the
  -- two lists is ever on the page, and Main sends a drag in an open
  -- playlist to playlistmove instead of move.
  row i s =
    HH.li
      ( [ HP.ref (rowRef i)
        , classes ([ "song" ] <> (if held == Just i then [ "held" ] else []))
        ]
          <> ( case rowShift st.drag i of
                 0.0 -> []
                 dy -> [ HP.style ("transform: translateY(" <> show dy <> "px)") ]
             )
      )
      [ HH.button
          [ cls "grip"
          , HP.title "Drag to reorder, or focus and use the arrow keys"
          , HE.handler (EventType "pointerdown") (GrabRow i)
          , HE.onKeyDown (GripKey i)
          ]
          [ iconSized "sm" "grip" ]
      , HH.div [ cls "grow" ]
          [ HH.div [ cls "title" ] [ HH.text (Mpd.songTitle s) ]
          , HH.div [ cls "line" ] [ HH.text (Mpd.songLine s) ]
          ]
      , formatBadge s.file
      , HH.span [ cls "time" ] [ HH.text (if s.duration > 0.0 then Mpd.clock s.duration else "") ]
      , HH.button [ cls "ghost icon-btn", HP.title "Remove from this playlist", HE.onClick \_ -> PlRemove i ] [ iconSized "sm" "x" ]
      ]

-- | Delete, in two presses. In the list it is the row's ×; in an open
-- | playlist, where every row has a × that removes one track, it says
-- | what it deletes.
deleteButton :: forall m. State -> String -> H.ComponentHTML Action () m -> H.ComponentHTML Action () m
deleteButton st name idle =
  HH.button
    [ classes ([ "mode", "clear" ] <> (if armed then [ "armed" ] else []))
    , HP.title (if armed then "Press again to delete " <> name else "Delete this playlist")
    , HE.onClick \_ -> DeletePlaylist name
    ]
    [ if armed then HH.text "Press again to delete" else idle ]
  where
  armed = map _.arm st.plArmed == Just (ArmDelete name)

noteOf :: forall m. State -> Array (H.ComponentHTML Action () m)
noteOf st = maybe [] (\n -> [ HH.p [ cls "note" ] [ HH.text n ] ]) st.plNote