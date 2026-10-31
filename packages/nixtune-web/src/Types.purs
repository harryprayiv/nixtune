-- | What the page is, as data: the two roles, the three connections, the
-- | state the component carries, and every constant the rest of the
-- | modules agree on. Nothing here does anything; it is the vocabulary
-- | the other modules are written in, so it depends on none of them
-- | except Browse, which is the tag browser's own vocabulary.
module Types where

import Prelude

import Browse (Axis, Browser, emptyBrowser, tagOf)
import Caps (Caps, Station)
import Data.Array as Array
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.Foldable (lookup)
import Data.String (Pattern(..), indexOf, split, trim)
import Data.Tuple (Tuple)
import Halogen as H
import Mpd (Entry, Song, Status)
import Mpd as Mpd
import Web.Event.Event (Event)
import Web.UIEvent.MouseEvent (MouseEvent)
import Web.Socket.WebSocket (WebSocket)
import Web.UIEvent.KeyboardEvent (KeyboardEvent)

-- | Which page this is. The host page has the transport, the queue, the
-- | volume and the QR code; the guest page has now playing and the
-- | library. Both reach the same websocket, so this is what the page
-- | offers, not what the player enforces.
data Role = Host | Guest

derive instance eqRole :: Eq Role

data View = NowPlaying | Queue | Library | Radio | Qr

derive instance eqView :: Eq View

-- | How the library is being looked at. The folder tree is what MPD
-- | indexes; the tag browser is what a person actually chooses music by.
data BrowseMode = Tags | Folders

derive instance eqBrowseMode :: Eq BrowseMode

-- | The three connections to MPD.
-- |
-- |   Cmd    transport, the queue, status, attribution
-- |   Idle   parked in MPD's idle command, told what changed
-- |   Lib    the library: browsing, the tag columns, search
-- |
-- | MPD answers one command at a time per connection, in order. Lib
-- | exists because of that: queueing a track makes MPD report a playlist
-- | change, the page answers by refetching the queue, and on a queue of
-- | a few hundred that reply is large. With one connection the next
-- | click on an artist waits behind it and the page looks dead, which
-- | invites a second click and a third. On its own connection a library
-- | query is never behind anything but another library query.
data Conn = Cmd | Idle | Lib

derive instance eqConn :: Eq Conn

-- | What a reply on a connection is for.
data Req
  = RStatus
  | RCurrent
  | RQueue
  | RStats
  | RBrowse String
  | RSearch String
  | RStickers
  | RVetoes
  -- One of the replies that make up a column, with the generation it
  -- was asked at. A column narrowed by several values is several `list`
  -- commands, so several replies build one column and each has to be
  -- recognisable as belonging to the request that is still current.
  | RTagValues Axis Int
  -- A window of the track list: the generation, and the row the window
  -- starts at in the whole result.
  | RTracks Int Int
  -- How many tracks one of the track queries matches: the generation,
  -- and which query it is.
  | RTrackCount Int Int
  | RFire

-- | One connection: its socket, whether MPD has greeted on it, the lines
-- | of the reply being collected, and the unfinished tail of the last
-- | message. websocat frames messages by TCP read, not by line, so one
-- | message may hold a whole reply or end in the middle of a line.
-- | `asked` is this connection's own queue of outstanding requests, in
-- | the order they were sent, so a reply is read against the right one.
-- | `queued` is what was asked for before MPD had greeted on this
-- | connection. The three sockets open together and greet whenever they
-- | greet, so a request made in the reply to one of them can arrive
-- | before another is ready; without this it was dropped silently, and
-- | the column it was for simply never loaded.
type Link =
  { socket :: WebSocket
  , ready :: Boolean
  , lines :: Array String
  , partial :: String
  , asked :: Array Req
  , queued :: Array { req :: Req, line :: String }
  }

-- | A queue row being dragged.
-- |
-- | The rows are measured once, when the drag starts, and not again: the
-- | list is not reordered under the finger, it is only drawn as though it
-- | had been, so the geometry the drag is reckoned against stays still.
-- | One `move` goes to MPD when the finger lifts, and the real order
-- | arrives back through the idle connection like any other change.
-- |
-- |   from     the row the drag started on, by index
-- |   startY   where the pointer went down, and where it is now
-- |   mids     the vertical middle of every row, at the moment of grabbing
-- |   advance  how far a displaced row moves: one row plus the gap
-- |   subs     the document listeners that run for the length of the drag
type Drag =
  { from :: Int
  , startY :: Number
  , y :: Number
  , mids :: Array Number
  , advance :: Number
  , subs :: Array H.SubscriptionId
  }

type State =
  { caps :: Maybe Caps
  , role :: Role
  , nickname :: String
  , view :: View
  , cmd :: Maybe Link
  , idle :: Maybe Link
  , lib :: Maybe Link
  , status :: Status
  , current :: Maybe Song
  , queue :: Array Song
  , songs :: Int
  -- MPD's db_update: the unix time of the last database update, and
  -- the key the browser's copy of the library index is stored under.
  , dbStamp :: Int
  , path :: String
  , query :: String
  , searched :: Maybe String
  , entries :: Array Entry
  , addedBy :: Array (Tuple String String)
  -- Who has voted against what, read from the nixtune.vetoes sticker.
  -- The value is the voters' nicknames, comma separated, so the count
  -- is distinct browsers rather than taps.
  , vetoes :: Array (Tuple String String)
  , error :: Maybe String
  , ticks :: Int
  -- Where the bar is being held. Shown immediately and kept until MPD
  -- reports that level back, so the thumb does not snap to a stale value
  -- between the command and the report.
  , volDraft :: Maybe Int
  -- The last level actually sent, and whether the sender is running. A
  -- drag produces an event per pixel; the sender turns that into one
  -- write per glide step, with the last value always sent.
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
  -- Which cover file name is being tried for the current track. A
  -- library names them several ways and none of them is guaranteed, so
  -- the page walks the list as each one fails to load and shows nothing
  -- once the list runs out.
  , artTry :: Int
  -- The queue row under the finger, while one is being dragged.
  , drag :: Maybe Drag
  -- The tag browser or the folder tree.
  , mode :: BrowseMode
  -- The tag browser: its columns, their selections and the track list.
  , browser :: Browser
  }

initial :: State
initial =
  { caps: Nothing
  , role: Guest
  , nickname: ""
  , view: NowPlaying
  , cmd: Nothing
  , idle: Nothing
  , lib: Nothing
  , status: Mpd.emptyStatus
  , current: Nothing
  , queue: []
  , songs: 0
  , dbStamp: 0
  , path: ""
  , query: ""
  , searched: Nothing
  , entries: []
  , addedBy: []
  , vetoes: []
  , error: Nothing
  , ticks: 0
  , volDraft: Nothing
  , volSent: Nothing
  , volSending: false
  , volBeforeMute: Nothing
  , volText: Nothing
  , seekDraft: Nothing
  , volLink: Nothing
  , artTry: 0
  , drag: Nothing
  , mode: Tags
  , browser: emptyBrowser 800.0
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
  | GrabRow Int Event
  | DragRow Event
  | DropRow
  | GripKey Int KeyboardEvent
  | VolOpened
  | VolClosed
  | ArtMissing
  | DragSeek String
  | CommitSeek String
  | Browse String
  | SetMode BrowseMode
  | ToggleGenreColumn
  -- A click on a value row: plain, shift or with the platform's
  -- modifier, which the handler reads off the event.
  | Choose Axis String MouseEvent
  -- The All row, or a chip on a phone: clear one column's selection.
  | ClearColumn Axis
  | JumpTo Axis String
  | Scrolled Axis Event
  | ScrolledTracks Event
  -- The window changed size, or a view with lists in it was opened:
  -- measure the lists again.
  | Measure
  | Veto String (Maybe Int)
  | AddFilter
  | PlayFilter
  | SetQuery String
  | Search Event
  | PlayStation Station
  | AddPath String
  | PlayPath String
  | PlayPos Int
  | DeletePos Int
  | UpdateLibrary

-- | The monad every handler and helper runs in.
type M o m = H.HalogenM State Action () o m

idleCommand :: String
idleCommand = "idle player mixer playlist options database update sticker"

stickerName :: String
stickerName = "nixtune.added_by"

vetoName :: String
vetoName = "nixtune.vetoes"

nicknameKey :: String
nicknameKey = "nixtune.nickname"

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

-- | How far one step of the glide moves, and how long a step lasts. A
-- | press or a drag sets the target; the level walks to it rather than
-- | jumping, which is gentler on speakers and reads as deliberate rather
-- | than abrupt. A full-scale move takes about half a second.
volumeGlideStep :: Int
volumeGlideStep = 4

volumeGlideMs :: Number
volumeGlideMs = 40.0

maxVolumeOf :: State -> Int
maxVolumeOf st = maybe 100 _.maxVolume st.caps

-- | The level to show: the press just made, else what MPD last reported.
shownVolume :: State -> Maybe Int
shownVolume st = case st.volDraft of
  Just v -> Just v
  Nothing -> st.status.volume

-- | Has MPD reported the level the page asked for, give or take a step.
arrived :: Maybe Int -> Maybe Int -> Boolean
arrived want got = case want, got of
  Just a, Just b -> a - b <= 1 && b - a <= 1
  _, _ -> false

-- | A sticker request whose failure is not worth a banner. A player whose
-- | sticker database is missing answers this with an error, and the only
-- | consequence is that nobody's name appears beside a queue entry.
isSticker :: Req -> Boolean
isSticker = case _ of
  RStickers -> true
  RVetoes -> true
  _ -> false

-- | Every attribution in the database, in one command.
stickerFind :: String
stickerFind = "sticker find song \"\" " <> stickerName

-- | Every vote in the database, likewise.
vetoFind :: String
vetoFind = "sticker find song \"\" " <> vetoName

-- | Who has voted against a track. The sticker holds nicknames
-- | separated by commas; a nickname is two words from the page's own
-- | lists and can never contain one.
votersAgainst :: State -> String -> Array String
votersAgainst st uri = case lookup uri st.vetoes of
  Nothing -> []
  Just raw -> Array.filter (_ /= "") (map trim (split (Pattern ",") raw))

-- | How many votes it takes.
vetoLimit :: State -> Int
vetoLimit st = maybe 3 _.vetoes st.caps

partyOn :: State -> Boolean
partyOn st = maybe false _.party st.caps

isStream :: String -> Boolean
isStream uri = isJust (indexOf (Pattern "://") uri)

-- | The scroll element of one column and of the track list, so a
-- | handler can move them and measure them.
colRef :: Axis -> H.RefLabel
colRef axis = H.RefLabel ("col-" <> tagOf axis)

tracksRef :: H.RefLabel
tracksRef = H.RefLabel "tracks"