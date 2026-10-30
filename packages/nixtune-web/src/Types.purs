-- | What the page is, as data: the two roles, the two connections, the
-- | state the component carries, and every constant the rest of the
-- | modules agree on. Nothing here does anything; it is the vocabulary
-- | the other modules are written in, so it depends on none of them.
module Types where

import Prelude

import Caps (Caps, Station)
import Data.Array as Array
import Data.Enum (enumFromTo)
import Data.Maybe (Maybe(..), isJust, maybe)
import Data.String (Pattern(..), indexOf, toUpper, trim)
import Data.String.CodeUnits as CodeUnits
import Data.Tuple (Tuple)
import Halogen as H
import Mpd (Entry, Song, Status)
import Mpd as Mpd
import Web.Event.Event (Event)
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

-- | A column of the tag browser. The chain runs left to right and a
-- | choice clears everything to its right, so the browser is a path
-- | rather than a set of filters that can disagree with each other.
data Axis = AxGenre | AxArtist | AxAlbum

derive instance eqAxis :: Eq Axis

-- | The two connections. One carries commands and reads their replies in
-- | order; the other sits in MPD's idle command and is told what changed.
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
  | RStickers
  | RTagValues Axis
  | RTagTracks
  | RFire

-- | One connection: its socket, whether MPD has greeted on it, the lines
-- | of the reply being collected, and the unfinished tail of the last
-- | message. websocat frames messages by TCP read, not by line, so one
-- | message may hold a whole reply or end in the middle of a line.
type Link = { socket :: WebSocket, ready :: Boolean, lines :: Array String, partial :: String }

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
  -- The tag browser. `mode` picks it or the folder tree; `genreColumn`
  -- says whether the chain starts at genre or at artist. It starts at
  -- artist because a library of this age has hundreds of distinct genre
  -- strings, most of them spellings of each other, and a column of
  -- hundreds is not a way of choosing anything.
  , mode :: BrowseMode
  , genreColumn :: Boolean
  , genres :: Array String
  , artists :: Array String
  , albums :: Array String
  , tagTracks :: Array Song
  , selGenre :: Maybe String
  , selArtist :: Maybe String
  , selAlbum :: Maybe String
  -- One first-letter filter per column. Filtering rather than scrolling:
  -- it needs no element measurement and no FFI, it works the same on a
  -- phone and a desktop, and over tens of thousands of artists it is the
  -- faster way to arrive anywhere.
  , letterGenre :: Maybe String
  , letterArtist :: Maybe String
  , letterAlbum :: Maybe String
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
  , artTry: 0
  , drag: Nothing
  , mode: Tags
  , genreColumn: false
  , genres: []
  , artists: []
  , albums: []
  , tagTracks: []
  , selGenre: Nothing
  , selArtist: Nothing
  , selAlbum: Nothing
  , letterGenre: Nothing
  , letterArtist: Nothing
  , letterAlbum: Nothing
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
  | Pick Axis (Maybe String)
  | PickLetter Axis (Maybe String)
  | AddAlbum
  | PlayAlbum
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
  _ -> false

-- | Every attribution in the database, in one command.
stickerFind :: String
stickerFind = "sticker find song \"\" " <> stickerName

isStream :: String -> Boolean
isStream uri = isJust (indexOf (Pattern "://") uri)

-- | A column longer than this gets a letter rail. Below it the rail is
-- | more work to read than the list it would filter.
letterRailThreshold :: Int
letterRailThreshold = 40

-- | The letter a tag value files under: its first character in upper
-- | case, or "#" when that is not A to Z. A leading article is NOT
-- | stripped. MPD sorts by the value it holds, and a page that silently
-- | reindexes disagrees with its own search results.
initialOf :: String -> String
initialOf s = case CodeUnits.uncons (toUpper (trim s)) of
  Just { head: c } | c >= 'A' && c <= 'Z' -> CodeUnits.singleton c
  _ -> "#"

alphabet :: Array String
alphabet = Array.cons "#" (map CodeUnits.singleton (enumFromTo 'A' 'Z'))

-- | A column narrowed to one initial, or whole when no letter is picked.
underLetter :: Maybe String -> Array String -> Array String
underLetter Nothing xs = xs
underLetter (Just l) xs = Array.filter (\x -> initialOf x == l) xs

-- | Which letters a column actually has entries under, so the rail can
-- | grey out the rest instead of offering an empty result.
lettersPresent :: Array String -> Array String
lettersPresent xs = Array.nub (map initialOf xs)

-- | The letter picked for one column.
letterOf :: Axis -> State -> Maybe String
letterOf axis st = case axis of
  AxGenre -> st.letterGenre
  AxArtist -> st.letterArtist
  AxAlbum -> st.letterAlbum

-- | The values in one column, before the letter filter.
valuesOf :: Axis -> State -> Array String
valuesOf axis st = case axis of
  AxGenre -> st.genres
  AxArtist -> st.artists
  AxAlbum -> st.albums

-- | What is selected in one column.
selectionOf :: Axis -> State -> Maybe String
selectionOf axis st = case axis of
  AxGenre -> st.selGenre
  AxArtist -> st.selArtist
  AxAlbum -> st.selAlbum

-- | The MPD tag name for a column.
tagOf :: Axis -> String
tagOf = case _ of
  AxGenre -> "genre"
  AxArtist -> "artist"
  AxAlbum -> "album"

axisLabel :: Axis -> String
axisLabel = case _ of
  AxGenre -> "Genre"
  AxArtist -> "Artist"
  AxAlbum -> "Album"
