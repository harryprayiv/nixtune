-- | The tag browser as data: up to three columns, the track list under
-- | them, and the arithmetic over both. Nothing here performs an effect.
-- | Tags performs the requests this module works out, and Library draws
-- | what it describes.
-- |
-- | The model is the column browser of the classic iTunes library view.
-- | Each column lists the distinct values of one tag, narrowed by the
-- | selection in every column to its left and by the search text. Each
-- | column has an All row at the top; an empty selection means All. A
-- | selection change in a column resets every column to its right to All,
-- | so the selections always describe one path through the library. The
-- | track list is what every selection and the search narrow to, and with
-- | none of them that is the whole library.
-- |
-- | The artist column is AlbumArtist. MPD falls back to Artist for a file
-- | without one, in `list` and in filters alike, so a compilation is one
-- | row and an album tagged only with a track artist still appears.
-- |
-- | ORDER IS THE PAGE'S. `list` prints its values in byte order, which is
-- | case sensitive and puts every lower case initial after Z. Every column
-- | is therefore ordered here, by its *Sort tag where the file has one and
-- | by the value otherwise, with the browser's locale-aware comparison, so
-- | "dEUS" sits among the Ds and "The Beatles" tagged "Beatles, The" sits
-- | among the Bs. The letter rail is worked out against the same order,
-- | so its letters always land where the eye expects them.
module Browse where

import Prelude

import Data.Array as Array
import Data.Enum (enumFromTo)
import Data.Foldable (lookup)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.String (joinWith, toLower)
import Data.String as String
import Data.String.CodeUnits as CodeUnits
import Data.String.Common (localeCompare)
import Filter as Filter
import Mpd (Song)
import Mpd as Mpd

-- | The three axes. AxArtist is the album artist.
data Axis = AxGenre | AxArtist | AxAlbum

derive instance eqAxis :: Eq Axis

-- | The columns in order, left to right. The genre column is not always
-- | drawn, so this is the full chain and `shownAxes` is what is on screen.
axisOrder :: Array Axis
axisOrder = [ AxGenre, AxArtist, AxAlbum ]

-- | One distinct value of a column: what is drawn, what it is ordered
-- | by, and for an album the year it is ordered by first.
type TagValue = { display :: String, key :: String, year :: Maybe Int }

-- | A scrollable list's scroll position and how much of it is on screen.
type Viewport = { top :: Number, height :: Number }

-- | One column.
-- |
-- |   values    the column's values in the page's order
-- |   selected  the displayed values picked here; empty means All
-- |   anchor    the last value clicked without shift, which a shift click
-- |             extends from
-- |   gen       which request the values answer; a reply tagged with an
-- |             older one is thrown away
-- |   pending   whether the current request is still out; the column
-- |             keeps showing its previous values until it lands
-- |   byYear    the values are in year order, which the letter rail does
-- |             not apply to
type Column =
  { values :: Array TagValue
  , selected :: Array String
  , anchor :: Maybe String
  , gen :: Int
  , pending :: Boolean
  , byYear :: Boolean
  , vp :: Viewport
  }

-- | The track list. Only one contiguous run of rows is held, starting
-- | at `from`: scrolling on extends it, and a jump that lands outside
-- | it starts a new run there.
-- |
-- |   total     how many tracks the list is of: `count` for a filter,
-- |             the song count from `stats` for the whole library, and
-- |             corrected by any page that comes back short
-- |   counted   whether total is known rather than awaited
-- |   picked    what the user has selected in the list, by URI rather
-- |             than by row, so a selection survives scrolling away and
-- |             back and the rows being refetched
-- |   anchor    the row a shift click extends from
type Tracks =
  { rows :: Array Song
  , from :: Int
  , pending :: Boolean
  , total :: Int
  , counted :: Boolean
  , gen :: Int
  , vp :: Viewport
  , picked :: Array String
  , anchor :: Maybe Int
  }

-- | The whole browser.
-- |
-- |   genreColumn  whether the chain starts at genre or at artist. It
-- |                starts at artist because this library has hundreds of
-- |                distinct genre strings, most of them spellings of each
-- |                other.
-- |   query        the committed search text, which narrows every column
-- |                and the track list
-- |   regex        whether MPD answered the startup probe for regular
-- |                expression filters. Without them a column can only
-- |                hold one selected value, because MPD has no other way
-- |                to say "this or that" in one command.
type Browser =
  { genreColumn :: Boolean
  , genre :: Column
  , artist :: Column
  , album :: Column
  , tracks :: Tracks
  , query :: Maybe String
  , regex :: Boolean
  }

-- | A fresh column or list, before anything has been asked for. The
-- | height is a guess at the viewport, which the page replaces with a
-- | measurement as soon as the element exists.
emptyColumn :: Number -> Column
emptyColumn height =
  { values: []
  , selected: []
  , anchor: Nothing
  , gen: 0
  , pending: false
  , byYear: false
  , vp: { top: 0.0, height }
  }

emptyTracks :: Number -> Tracks
emptyTracks height =
  { rows: []
  , from: 0
  , pending: false
  , total: 0
  , counted: false
  , gen: 0
  , vp: { top: 0.0, height }
  , picked: []
  , anchor: Nothing
  }

emptyBrowser :: Number -> Browser
emptyBrowser height =
  { genreColumn: false
  , genre: emptyColumn height
  , artist: emptyColumn height
  , album: emptyColumn height
  , tracks: emptyTracks height
  , query: Nothing
  , regex: false
  }

columnOf :: Axis -> Browser -> Column
columnOf axis br = case axis of
  AxGenre -> br.genre
  AxArtist -> br.artist
  AxAlbum -> br.album

setColumn :: Axis -> Column -> Browser -> Browser
setColumn axis col br = case axis of
  AxGenre -> br { genre = col }
  AxArtist -> br { artist = col }
  AxAlbum -> br { album = col }

modifyColumn :: Axis -> (Column -> Column) -> Browser -> Browser
modifyColumn axis f br = setColumn axis (f (columnOf axis br)) br

-- | A column with no selection, no contents and its scroll at the top,
-- | keeping only its viewport height and its generation. This is what a
-- | column to the right of a change becomes before it is asked for again.
cleared :: Column -> Column
cleared col = (emptyColumn col.vp.height) { gen = col.gen }

-- | The columns on screen, in order.
shownAxes :: Browser -> Array Axis
shownAxes br = Array.filter (\a -> a /= AxGenre || br.genreColumn) axisOrder

-- | The columns that narrow this one: everything to its left that is on
-- | screen. A genre column that is switched off is out of the chain
-- | entirely rather than a hidden constraint.
leftOf :: Axis -> Browser -> Array Axis
leftOf axis br = Array.takeWhile (_ /= axis) (shownAxes br)

-- | The columns this one narrows: everything to its right.
rightOf :: Axis -> Browser -> Array Axis
rightOf axis br = Array.drop 1 (Array.dropWhile (_ /= axis) (shownAxes br))

-- ---------------------------------------------------------------------
-- Tags and filters

-- | The tag a filter matches against, and the one `list` is asked for.
filterTag :: Axis -> String
filterTag = case _ of
  AxGenre -> "genre"
  AxArtist -> "albumartist"
  AxAlbum -> "album"

-- | The label MPD puts on the value lines of a `list` reply.
listLabel :: Axis -> String
listLabel = case _ of
  AxGenre -> "Genre"
  AxArtist -> "AlbumArtist"
  AxAlbum -> "Album"

-- | The label of the sort key MPD groups the values under, if any.
keyLabel :: Axis -> Maybe String
keyLabel = case _ of
  AxGenre -> Nothing
  AxArtist -> Just "AlbumArtistSort"
  AxAlbum -> Just "AlbumSort"

-- | A short stable name for an axis: element refs and the browser's store.
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

pluralOf :: Axis -> String
pluralOf = case _ of
  AxGenre -> "genres"
  AxArtist -> "artists"
  AxAlbum -> "albums"

-- | What one column's selection contributes to a filter, if anything.
selectionTerm :: Axis -> Browser -> Maybe Filter.Term
selectionTerm axis br = Filter.anyOf (filterTag axis) (columnOf axis br).selected

-- | What the search text contributes, if anything.
queryTerm :: Browser -> Maybe Filter.Term
queryTerm br = map Filter.contains br.query

-- | The filter one column is listed under: the selections to its left
-- | and the search.
columnFilter :: Axis -> Browser -> Maybe String
columnFilter axis br =
  Filter.conjoin (Array.mapMaybe (\a -> selectionTerm a br) (leftOf axis br) <> Array.fromFoldable (queryTerm br))

-- | The filter the track list is of: every selection and the search.
-- | Nothing is the whole library.
trackFilter :: Browser -> Maybe String
trackFilter br =
  Filter.conjoin (Array.mapMaybe (\a -> selectionTerm a br) (shownAxes br) <> Array.fromFoldable (queryTerm br))

-- | Is this column narrowed by nothing, so that it lists the whole
-- | library. Those are the lists worth keeping in the browser's store.
isPlain :: Axis -> Browser -> Boolean
isPlain axis br = isNothing (columnFilter axis br)

-- | Whether the album column is ordered by year: when an artist is
-- | selected, so the column reads as that artist's discography. Across
-- | the whole library year order is not a way of finding anything.
yearOrdered :: Axis -> Browser -> Boolean
yearOrdered axis br = axis == AxAlbum && not (Array.null br.artist.selected)

-- | The one command a column is built from, whatever is selected. The
-- | group keyword brings the sort key, and for a discography the date,
-- | in the same reply. MPD reads `group` pairs from the end of the line,
-- | and the first one it reads is the outermost; that order changes only
-- | how the reply is nested, which `Mpd.parseGrouped` does not depend on.
listCommand :: Axis -> Browser -> String
listCommand axis br =
  joinWith " " (Array.filter (_ /= "") [ "list", filterTag axis, maybe' (columnFilter axis br), groups ])
  where
  maybe' = fromMaybe "" <<< map Mpd.quote
  groups = case axis of
    AxGenre -> ""
    AxArtist -> "group albumartistsort"
    AxAlbum -> if yearOrdered axis br then "group albumsort group date" else "group albumsort"

-- | A `list` reply as a column's values, in the page's order. Empty
-- | values are dropped: MPD lists the songs that lack the tag under "",
-- | and an empty row is not something to choose. A value that arrives
-- | under more than one sort key, because its files are tagged
-- | inconsistently, appears once, under the key that sorts first.
columnValues :: Axis -> Boolean -> Array String -> Array TagValue
columnValues axis byYear block =
  Array.nubBy (\a b -> compare a.display b.display) (Array.sortBy order values)
  where
  values = Array.mapMaybe toValue (Mpd.parseGrouped (listLabel axis) block)
  toValue g
    | g.value == "" = Nothing
    | otherwise =
        Just
          { display: g.value
          , key: case keyLabel axis >>= \l -> lookup l g.context of
              Just k | k /= "" -> k
              _ -> g.value
          , year: if byYear then lookup "Date" g.context >>= yearOf else Nothing
          }
  order = if byYear then byYearThenKey else byKey

-- | The first four characters of a Date tag, when they are a year.
yearOf :: String -> Maybe Int
yearOf d = case Int.fromString (String.take 4 d) of
  Just y | String.length (String.take 4 d) == 4 && y > 0 -> Just y
  _ -> Nothing

byKey :: TagValue -> TagValue -> Ordering
byKey a b = localeCompare a.key b.key <> localeCompare a.display b.display

-- | A dated album before an undated one; then by year; then by key.
byYearThenKey :: TagValue -> TagValue -> Ordering
byYearThenKey a b = case a.year, b.year of
  Just x, Just y -> compare x y <> byKey a b
  Just _, Nothing -> LT
  Nothing, Just _ -> GT
  Nothing, Nothing -> byKey a b

-- | What the track list is of, said in words. One value is named; more
-- | than one is counted, because three dozen artist names is not a
-- | heading.
trackScope :: Browser -> String
trackScope br = case parts <> search of
  [] -> "The whole library"
  ps -> joinWith ", " ps
  where
  parts = Array.mapMaybe describe (shownAxes br)
  describe a = case (columnOf a br).selected of
    [] -> Nothing
    [ v ] -> Just v
    vs -> Just (show (Array.length vs) <> " " <> pluralOf a)
  search = case br.query of
    Just q -> [ "matching \"" <> q <> "\"" ]
    Nothing -> []

-- | The column a choice is being made in: the first in the chain with
-- | nothing selected, or the last column once everything is chosen.
-- |
-- | Side by side this changes nothing, because every column is on screen.
-- | Stacked on a phone it is the whole navigation model: only this column
-- | is drawn, and the choices already made appear above it as chips that
-- | go back (index.html decides which of the two applies, by width).
activeAxis :: Browser -> Axis
activeAxis br =
  fromMaybe AxAlbum
    (Array.find (\a -> Array.null (columnOf a br).selected) (shownAxes br) `orElse` Array.last (shownAxes br))

-- | The first of two answers that is one.
orElse :: forall a. Maybe a -> Maybe a -> Maybe a
orElse a b = case a of
  Just _ -> a
  Nothing -> b

-- | The values between two entries of a column, in the column's own
-- | order, which is what a shift click means.
spanBetween :: String -> String -> Array String -> Array String
spanBetween a b values = case Array.elemIndex a values, Array.elemIndex b values of
  Just i, Just j -> Array.slice (min i j) (max i j + 1) values
  _, _ -> [ b ]

-- | Add a value to a selection or take it out, which is what a click
-- | with the platform's modifier means.
toggled :: String -> Array String -> Array String
toggled v vs = if Array.elem v vs then Array.filter (_ /= v) vs else Array.snoc vs v

-- ---------------------------------------------------------------------
-- Rows and the slice of them that is drawn

-- | What is in a column's list: the All row, then one row per value.
data ColRow = AllRow | ValueRow TagValue

-- | A column shows every entry it has. Only the rows inside the scroll
-- | viewport are put in the page, with a blank block above and below
-- | standing in for the rest, so the scrollbar is the true length of the
-- | list and the DOM holds a few dozen nodes instead of ten thousand.
-- |
-- | That is what makes this work: the page has to know how tall a row is
-- | rather than measure every one. index.html sets the same numbers on
-- | .val and .tracks li, and the two have to agree.
rowHeight :: Number
rowHeight = 40.0

-- | A track row is two lines.
trackHeight :: Number
trackHeight = 58.0

-- | Rows drawn above and below the viewport, so a fast scroll does not
-- | show a gap before the next frame lands.
overscan :: Int
overscan = 8

-- | How many rows a column has, the All row included.
rowCount :: Column -> Int
rowCount col = Array.length col.values + 1

rowAt :: Column -> Int -> Maybe ColRow
rowAt col i
  | i == 0 = Just AllRow
  | otherwise = ValueRow <$> Array.index col.values (i - 1)

-- | Which row a value sits on.
rowOfValue :: String -> Column -> Maybe Int
rowOfValue v col = (_ + 1) <$> Array.findIndex (\x -> x.display == v) col.values

-- | The row of the first selected value that the column still holds.
selectionRow :: Column -> Maybe Int
selectionRow col = Array.head (Array.mapMaybe (\v -> rowOfValue v col) col.selected)

-- | The value drawn at the top of the viewport, which a refresh keeps
-- | in place when the column has no selection to pin instead.
topValue :: Column -> Maybe String
topValue col = _.display <$> Array.index col.values (Int.floor (col.vp.top / rowHeight) - 1)

-- | Which rows of a list of `total` rows at `pitch` pixels each are
-- | inside the viewport, with the overscan on both sides.
type Slice = { first :: Int, count :: Int }

sliceFor :: Viewport -> Number -> Int -> Slice
sliceFor vp pitch total = { first, count: last - first }
  where
  first = clamp 0 total (Int.floor (vp.top / pitch) - overscan)
  last = clamp 0 total (Int.ceil ((vp.top + vp.height) / pitch) + overscan)

-- | The row under the top edge of the viewport.
topRow :: Viewport -> Number -> Int
topRow vp pitch = Int.floor (vp.top / pitch)

-- ---------------------------------------------------------------------
-- The letter rail

-- | A column longer than this gets a letter rail. Below it the rail is
-- | more work to read than the list it would move. A column in year order
-- | never gets one.
letterRailThreshold :: Int
letterRailThreshold = 40

hasRail :: Column -> Boolean
hasRail col = not col.byYear && Array.length col.values > letterRailThreshold

-- | # then A to Z. # is everything that sorts before A: digits and
-- | punctuation. Anything that sorts after Z is reached from Z.
alphabet :: Array String
alphabet = Array.cons "#" (map CodeUnits.singleton (enumFromTo 'A' 'Z'))

-- | The index in a column's values where a letter's section starts: the
-- | first value whose key sorts at or after that letter, by the same
-- | comparison the column is ordered by. A binary search, since the
-- | column is sorted. The bound is the lower case letter, because the
-- | locale order puts "a" before "A" and a value that is exactly "a"
-- | belongs under A.
sectionStart :: String -> Array TagValue -> Int
sectionStart l values
  | l == "#" = 0
  | otherwise = go 0 (Array.length values)
  where
  bound = toLower l
  go lo hi
    | lo >= hi = lo
    | otherwise =
        let
          mid = (lo + hi) / 2
        in
          case Array.index values mid of
            Just v | localeCompare v.key bound == LT -> go (mid + 1) hi
            _ -> go lo mid

-- | Where each letter's section starts and ends, in rail order.
type Section = { letter :: String, start :: Int, end :: Int }

sections :: Column -> Array Section
sections col = Array.zipWith (\l s -> { letter: l, start: s.start, end: s.end }) alphabet bounds
  where
  n = Array.length col.values
  starts = map (\l -> sectionStart l col.values) alphabet
  ends = Array.snoc (Array.drop 1 starts) n
  bounds = Array.zipWith (\s e -> { start: s, end: max s e }) starts ends

-- | The row a letter's button scrolls to, counting the All row, when the
-- | letter has anything under it.
firstUnder :: String -> Column -> Maybe Int
firstUnder l col = do
  s <- Array.find (\x -> x.letter == l) (sections col)
  if s.end > s.start then Just (s.start + 1) else Nothing

-- | Which letters have anything under them, so the rail can grey out the
-- | rest instead of scrolling nowhere.
lettersPresent :: Column -> Array String
lettersPresent col = map _.letter (Array.filter (\s -> s.end > s.start) (sections col))

-- | The letter whose section holds the row at the top of the viewport.
letterAt :: Column -> Maybe String
letterAt col = _.letter <$> Array.find (\s -> s.start <= i && i < s.end) (sections col)
  where
  i = topRow col.vp rowHeight - 1

-- ---------------------------------------------------------------------
-- The track list

-- | How many tracks one request brings back. Small enough that the
-- | first page is instant on a library of any size, large enough that
-- | an ordinary scroll does not ask twice a second.
trackPage :: Int
trackPage = 200

-- | The row the held run ends at, exclusive.
heldTo :: Tracks -> Int
heldTo t = t.from + Array.length t.rows

-- | The track drawn at one row of the whole result, when that row is in
-- | the run being held.
trackAt :: Tracks -> Int -> Maybe Song
trackAt t row = Array.index t.rows (row - t.from)

isPicked :: Tracks -> Song -> Boolean
isPicked t s = Array.elem s.file t.picked

-- | What a click on a track row selects.
-- |
-- | Plain picks that one row, the platform's modifier adds or removes
-- | it, and shift takes the run between the anchor and this row. A shift
-- | range covers the rows actually held: the user had to scroll past
-- | both ends to click them, so in practice that is the whole range, and
-- | a row the page has never seen is one it has no URI for.
pickedBy :: Tracks -> Int -> Boolean -> Boolean -> Array String
pickedBy t row shift extend = case trackAt t row of
  Nothing -> t.picked
  Just s
    | shift -> rangeFrom (fromMaybe row t.anchor) row
    | extend -> toggled s.file t.picked
    | otherwise -> [ s.file ]
  where
  rangeFrom a b =
    Array.nub (Array.mapMaybe (map _.file <<< trackAt t) (Array.range (min a b) (max a b)))

pickedCount :: Tracks -> Int
pickedCount t = Array.length t.picked

-- | The picked tracks in the order the list shows them, so a queue built
-- | by selecting an album's second, fourth and fifth tracks arrives in
-- | that order rather than in the order they were clicked.
inListOrder :: Tracks -> Array String
inListOrder t = Array.filter (\u -> Array.elem u t.picked) (map _.file t.rows)