-- | What the page is, as data: the two roles, the two connections, the
-- | state the component carries, and every constant the rest of the
-- | modules agree on. Nothing here does anything; it is the vocabulary
-- | the other modules are written in, so it depends on none of them.
module Types where

import Prelude

import Caps (Caps, Station)
import Data.Array as Array
import Data.Enum (enumFromTo)
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Foldable (foldl, lookup, sum)
import Data.String (Pattern(..), Replacement(..), indexOf, replaceAll, split, toUpper, trim)
import Data.String.Common (joinWith)
import Data.String.CodeUnits as CodeUnits
import Data.Tuple (Tuple(..), snd)
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

-- | A column of the tag browser. Each column holds a set of selected
-- | values, each column is narrowed by the columns to its left, and the
-- | track list below is narrowed by all three. A column with nothing
-- | selected constrains nothing, so the browser is a filter that only
-- | ever subtracts and never a gate that has to be opened first.
data Axis = AxGenre | AxArtist | AxAlbum

derive instance eqAxis :: Eq Axis

-- | The columns in order, left to right. The genre column is not always
-- | drawn, so this is the full chain and callers skip what is hidden.
axisOrder :: Array Axis
axisOrder = [ AxGenre, AxArtist, AxAlbum ]

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

-- | What a reply on the command connection is for.
data Req
  = RStatus
  | RCurrent
  | RQueue
  | RStats
  | RBrowse String
  | RSearch String
  | RStickers
  | RVetoes
  -- A column's values, with the generation they were asked at. A column
  -- is now the union of one `list` per value selected to its left, so
  -- several replies build one column and each has to be recognisable as
  -- belonging to the selection that is still current.
  | RTagValues Axis Int
  -- A window of the track list: the generation, and the row the window
  -- starts at in the whole result.
  | RTracks Int Int
  -- How many tracks one of the track queries matches: the generation,
  -- and which query it is. The totals are summed, and the per-query
  -- counts are what map a row number onto a query and an offset in it.
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
  -- The tracks the columns narrow to, which is the whole library when
  -- nothing is picked. Only the pages scrolled to are held: the count
  -- comes from MPD separately, so the scrollbar is the real length from
  -- the first paint and the rest arrives as it is reached.
  , tagTracks :: Array Song
  , tracksTotal :: Int
  -- Which row the held run starts at. The page keeps one contiguous
  -- run rather than a sparse map: scrolling on extends it, and a jump
  -- that lands outside it starts a new run there, so a drag of the
  -- scrollbar to the far end costs one request and not three hundred.
  , tracksFrom :: Int
  , tracksPending :: Boolean
  , vpTracks :: Viewport
  -- The queries the current selection comes to, and how many tracks
  -- each matches. MPD's filters have AND and NOT and no OR, so a
  -- selection of three artists is three queries whose results are read
  -- one after another as one list. An empty array means no filter at
  -- all, which is the whole library.
  , trackQueries :: Array TrackQuery
  -- Which selection the held rows belong to. A reply tagged with an
  -- older one answers a question nobody is asking any more.
  , tracksGen :: Int
  -- What is selected in each column. Several values at once, in the
  -- column's own order, and empty meaning "no constraint from here".
  , selGenre :: Array String
  , selArtist :: Array String
  , selAlbum :: Array String
  -- The row a shift click extends from, per column: the last row that
  -- was clicked without shift.
  , anchorGenre :: Maybe String
  , anchorArtist :: Maybe String
  , anchorAlbum :: Maybe String
  -- Which selection each column's values belong to, and how many of
  -- its replies are still outstanding. A column built from several
  -- `list` commands is only finished when the last of them lands, and
  -- a reply from before the last click has to be thrown away rather
  -- than unioned into a column it does not belong to.
  , colGen :: Triple
  , colPend :: Triple
  -- Where each column is scrolled to and how tall it is, which is all
  -- the page needs to work out which rows are worth drawing.
  , vpGenre :: Viewport
  , vpArtist :: Viewport
  , vpAlbum :: Viewport
  }

-- | One query behind the track list, and how many tracks it matches.
type TrackQuery = { terms :: String, count :: Int }

-- | One number per column.
type Triple = { genre :: Int, artist :: Int, album :: Int }

zeroTriple :: Triple
zeroTriple = { genre: 0, artist: 0, album: 0 }

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
  , genreColumn: false
  , genres: []
  , artists: []
  , albums: []
  , tagTracks: []
  , tracksTotal: 0
  , tracksFrom: 0
  , tracksPending: false
  , vpTracks: emptyViewport
  , trackQueries: []
  , tracksGen: 0
  , selGenre: []
  , selArtist: []
  , selAlbum: []
  , anchorGenre: Nothing
  , anchorArtist: Nothing
  , anchorAlbum: Nothing
  , colGen: zeroTriple
  , colPend: zeroTriple
  , vpGenre: emptyViewport
  , vpArtist: emptyViewport
  , vpAlbum: emptyViewport
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
  | Choose Axis String MouseEvent
  | JumpTo Axis String
  | Scrolled Axis Event
  | ScrolledTracks Event
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

-- | How many votes it takes, and whether this browser has cast one.
vetoLimit :: State -> Int
vetoLimit st = maybe 3 _.vetoes st.caps

partyOn :: State -> Boolean
partyOn st = maybe false _.party st.caps

isStream :: String -> Boolean
isStream uri = isJust (indexOf (Pattern "://") uri)

-- | A column longer than this gets a letter rail. Below it the rail is
-- | more work to read than the list it would filter.
letterRailThreshold :: Int
letterRailThreshold = 40

-- | A column shows every entry it has. Only the rows inside the scroll
-- | viewport are put in the page, with a blank block above and below
-- | standing in for the rest, so the scrollbar is the true length of the
-- | list and the DOM holds a few dozen nodes instead of twelve thousand.
-- |
-- | That is what makes this work: the page has to know how tall a row is
-- | rather than measure every one. index.html sets the same number on
-- | .val, and the two have to agree.
rowHeight :: Number
rowHeight = 40.0

-- | Rows drawn above and below the viewport, so a fast scroll does not
-- | show a gap before the next frame lands.
overscan :: Int
overscan = 8

-- | A column's scroll position and how much of it is on screen.
type Viewport = { top :: Number, height :: Number }

-- | Before a column has been scrolled or measured. The height is
-- | deliberately larger than any column gets, so the first paint
-- | overdraws rather than leaving the bottom of a tall column blank
-- | until the first scroll event.
emptyViewport :: Viewport
emptyViewport = { top: 0.0, height: 760.0 }

viewportOf :: Axis -> State -> Viewport
viewportOf axis st = case axis of
  AxGenre -> st.vpGenre
  AxArtist -> st.vpArtist
  AxAlbum -> st.vpAlbum

-- | The scroll element of one column, so a new selection can put it
-- | back at the top.
colRef :: Axis -> H.RefLabel
colRef axis = H.RefLabel ("col-" <> tagOf axis)

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

-- | Where a letter starts in a column, so the rail can scroll to it.
-- | The rail moves the column; it never hides any of it.
firstUnder :: String -> Array String -> Maybe Int
firstUnder l = Array.findIndex (\v -> initialOf v == l)

-- | Where to put a column after its contents have been replaced: at the
-- | first row that is still selected, or at the top when nothing is.
-- |
-- | Scrolling to the top is the wrong answer once the column keeps a
-- | selection, because the row that was just clicked is then somewhere
-- | below the fold and has to be hunted for. Scrolling to it instead
-- | means the selection is the first thing on screen and everything
-- | earlier in the alphabet is one scroll back.
scrollRowFor :: Axis -> Array String -> State -> Int
scrollRowFor axis values st =
  fromMaybe 0 (Array.head (Array.mapMaybe (\v -> Array.elemIndex v values) (selectedIn axis st)))

-- | Which letters a column actually has entries under, so the rail can
-- | grey out the rest instead of scrolling nowhere.
lettersPresent :: Array String -> Array String
lettersPresent xs = Array.nub (map initialOf xs)

-- | The values in one column, before the letter filter.
valuesOf :: Axis -> State -> Array String
valuesOf axis st = case axis of
  AxGenre -> st.genres
  AxArtist -> st.artists
  AxAlbum -> st.albums

-- | What is selected in one column. Empty means this column is not
-- | narrowing anything.
selectedIn :: Axis -> State -> Array String
selectedIn axis st = case axis of
  AxGenre -> st.selGenre
  AxArtist -> st.selArtist
  AxAlbum -> st.selAlbum

setSelected :: Axis -> Array String -> State -> State
setSelected axis vs = case axis of
  AxGenre -> _ { selGenre = vs }
  AxArtist -> _ { selArtist = vs }
  AxAlbum -> _ { selAlbum = vs }

anchorIn :: Axis -> State -> Maybe String
anchorIn axis st = case axis of
  AxGenre -> st.anchorGenre
  AxArtist -> st.anchorArtist
  AxAlbum -> st.anchorAlbum

setAnchor :: Axis -> Maybe String -> State -> State
setAnchor axis v = case axis of
  AxGenre -> _ { anchorGenre = v }
  AxArtist -> _ { anchorArtist = v }
  AxAlbum -> _ { anchorAlbum = v }

-- | Which columns narrow this one: everything to its left that is on
-- | screen. The genre column being switched off takes it out of the
-- | chain entirely rather than leaving it as a hidden constraint.
leftOf :: Axis -> State -> Array Axis
leftOf axis st = Array.filter shown case axis of
  AxGenre -> []
  AxArtist -> [ AxGenre ]
  AxAlbum -> [ AxGenre, AxArtist ]
  where
  shown a = a /= AxGenre || st.genreColumn

-- | Which columns this one narrows: everything to its right that is on
-- | screen. Those are the ones a click here has to ask for again.
rightOf :: Axis -> State -> Array Axis
rightOf axis st = Array.filter shown case axis of
  AxGenre -> [ AxArtist, AxAlbum ]
  AxArtist -> [ AxAlbum ]
  AxAlbum -> []
  where
  shown a = a /= AxGenre || st.genreColumn

-- | What to the left of this column narrows it, with the values each of
-- | those columns has selected. Empty means this column lists the whole
-- | library.
narrowedFrom :: Axis -> State -> Array (Tuple Axis (Array String))
narrowedFrom axis st =
  Array.filter (\(Tuple _ vs) -> not (Array.null vs))
    (map (\a -> Tuple a (selectedIn a st)) (leftOf axis st))

-- | The commands one column is built from: `list <tag>` on its own when
-- | nothing narrows it, and otherwise one per combination of the values
-- | selected to its left, because MPD's filters have no OR. The replies
-- | are unioned as they arrive.
listCommands :: Axis -> State -> Array String
listCommands axis st = case productOf (map snd (dimsOf (narrowedFrom axis st))) of
  [] -> [ "list " <> tagOf axis ]
  cs -> map (\c -> "list " <> tagOf axis <> " " <> c) cs
  where
  dimsOf = map \(Tuple a vs) -> Tuple a (map (\v -> tagOf a <> " " <> quoteArg v) vs)

-- | Every combination of one value per dimension, each written out as
-- | one filter's worth of terms. No dimensions is no combinations, which
-- | callers read as "no filter" rather than as "matches nothing".
productOf :: Array (Array String) -> Array String
productOf dims = case Array.filter (not <<< Array.null) dims of
  [] -> []
  ds -> foldl step [ "" ] ds
  where
  step acc ts = do
    a <- acc
    t <- ts
    pure (if a == "" then t else a <> " " <> t)

-- | The tag name MPD labels a column's values with in a `list` reply,
-- | which is capitalised where the argument to `list` is not.
listLabel :: Axis -> String
listLabel = case _ of
  AxGenre -> "Genre"
  AxArtist -> "Artist"
  AxAlbum -> "Album"

-- | Which generation a column's values belong to, and how many of its
-- | replies have still to arrive.
genOf :: Axis -> State -> Int
genOf axis st = case axis of
  AxGenre -> st.colGen.genre
  AxArtist -> st.colGen.artist
  AxAlbum -> st.colGen.album

pendOf :: Axis -> State -> Int
pendOf axis st = case axis of
  AxGenre -> st.colPend.genre
  AxArtist -> st.colPend.artist
  AxAlbum -> st.colPend.album

setGen :: Axis -> Int -> State -> State
setGen axis n st = st { colGen = write axis n st.colGen }

setPend :: Axis -> Int -> State -> State
setPend axis n st = st { colPend = write axis n st.colPend }

write :: Axis -> Int -> Triple -> Triple
write axis n t = case axis of
  AxGenre -> t { genre = n }
  AxArtist -> t { artist = n }
  AxAlbum -> t { album = n }

-- | Is this column waiting for its reply. A column that has been asked
-- | for and has not arrived says so, because an empty box that will fill
-- | in a moment looks exactly like a click that did nothing, and the
-- | answer to a click that did nothing is to click again.
waitingFor :: Axis -> State -> Boolean
waitingFor axis st = pendOf axis st > 0

-- | How many tracks one request brings back. Small enough that the
-- | first page is instant on a library of any size, large enough that
-- | an ordinary scroll does not ask twice a second.
trackPage :: Int
trackPage = 200

-- | A track row is two lines, and a fixed height is what lets the list
-- | be drawn a slice at a time.
trackHeight :: Number
trackHeight = 58.0

tracksRef :: H.RefLabel
tracksRef = H.RefLabel "tracks"

-- | How many queries one selection may come to before the exact form
-- | is given up on. Thirty-two covers every selection a person makes by
-- | hand in three columns.
maxTrackQueries :: Int
maxTrackQueries = 32

-- | The queries the current selection comes to, each one a filter ready
-- | to follow `find` or `count`.
-- |
-- | MPD's filter language has AND and NOT and no OR. Two selected
-- | artists are therefore two queries, not one filter, and two genres
-- | with three artists are six. Every combination of one value per
-- | selected column is one query; the combinations are mutually
-- | exclusive, so the counts add up and the rows read as one list laid
-- | end to end.
-- |
-- | An empty array means no filter at all. There is deliberately no
-- | term meaning "everything": MPD rejects `base ""` with "Bad URI",
-- | and every other filter that matches all songs is a substring
-- | search, which `count` will not take. The callers handle that case
-- | instead, with `stats` for the total and `search any ""` for the
-- | listing.
-- |
-- | Past `maxTrackQueries` the product is abandoned for the rightmost
-- | selected column on its own, ANDed with whichever columns to its
-- | left hold exactly one value. That is bounded by the rows actually
-- | selected rather than by their product, and it differs from the
-- | exact answer only where a value in the rightmost column also
-- | belongs to something outside the selection to its left, which in a
-- | music library means a compilation filed under two artists.
trackCombos :: State -> Array String
trackCombos st = case dims of
  [] -> []
  _ -> if Array.length exact <= maxTrackQueries then exact else fallback
  where
  dims =
    Array.filter (not <<< Array.null)
      [ if st.genreColumn then terms AxGenre else []
      , terms AxArtist
      , terms AxAlbum
      ]
  terms axis = map (\v -> tagOf axis <> " " <> quoteArg v) (selectedIn axis st)

  exact = productOf dims

  fallback =
    Array.take maxTrackQueries
      (map (\t -> if prefix == "" then t else prefix <> " " <> t) rightmost)
    where
    rightmost = fromMaybe [] (Array.last dims)
    prefix =
      joinWith " "
        ( Array.concat
            (map (\d -> if Array.length d == 1 then d else []) (fromMaybe [] (Array.init dims)))
        )

-- | Which query a row of the whole result falls in, how far into that
-- | query it is, and how many of its rows are left. Queries that match
-- | nothing are stepped over, so a combination that happens to be empty
-- | does not stall the list.
queryAt :: Int -> Array TrackQuery -> Maybe { index :: Int, offset :: Int, left :: Int }
queryAt row qs = go 0 row
  where
  go i n = case Array.index qs i of
    Nothing -> Nothing
    Just q
      | n < q.count -> Just { index: i, offset: n, left: q.count - n }
      | otherwise -> go (i + 1) (n - q.count)

-- | How many tracks the whole selection matches: the per-query counts,
-- | added up.
totalOf :: Array TrackQuery -> Int
totalOf = sum <<< map _.count

-- | Whether the queries have been reduced, so the list can say that the
-- | selection was too wide to answer exactly.
combosReduced :: State -> Boolean
combosReduced st = Array.length (trackCombos st) >= maxTrackQueries

-- | What the track list is of, said in words. One value is named; more
-- | than one is counted, because three dozen artist names is not a
-- | heading.
trackScope :: State -> String
trackScope st = case parts of
  [] -> "The whole library"
  _ -> joinWith ", " parts
  where
  parts = Array.mapMaybe describe (Array.filter shown axisOrder)
  shown a = a /= AxGenre || st.genreColumn
  describe a = case selectedIn a st of
    [] -> Nothing
    [ v ] -> Just v
    vs -> Just (show (Array.length vs) <> " " <> plural a)
  plural = case _ of
    AxGenre -> "genres"
    AxArtist -> "artists"
    AxAlbum -> "albums"

-- | Local copy of Mpd.quote, which Types cannot import without a cycle.
quoteArg :: String -> String
quoteArg v = "\"" <> replaceAll (Pattern "\"") (Replacement "\\\"") (replaceAll (Pattern "\\") (Replacement "\\\\") v) <> "\""

waitingForTracks :: State -> Boolean
waitingForTracks st = st.tracksPending

-- | The column a choice is being made in: the first in the chain with
-- | nothing selected yet, or the album column once everything is chosen.
-- |
-- | Side by side this changes nothing, because every column is on screen.
-- | Stacked on a phone it is the whole navigation model: only this column
-- | is drawn, and the choices already made appear above it as chips that
-- | go back (index.html decides which of the two applies, by width).
activeAxis :: State -> Axis
activeAxis st =
  if st.genreColumn && Array.null st.selGenre then AxGenre
  else if Array.null st.selArtist then AxArtist
  else AxAlbum

-- | The values between two entries of a column, in the column's own
-- | order, which is what a shift click means.
spanBetween :: String -> String -> Array String -> Array String
spanBetween a b values = case Array.elemIndex a values, Array.elemIndex b values of
  Just i, Just j -> Array.slice (min i j) (max i j + 1) values
  _, _ -> [ b ]

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
