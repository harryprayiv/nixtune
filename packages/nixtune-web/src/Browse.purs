-- | The tag browser as data: three columns, the track list under them,
-- | and the arithmetic over both. Nothing here performs an effect. Tags
-- | performs the requests this module works out, and Page draws what it
-- | describes.
-- |
-- | The model is the column browser of the classic iTunes library view.
-- | Each column lists the distinct values of one tag, narrowed by the
-- | selection in every column to its left. Each column has an All row at
-- | the top; an empty selection means All, which narrows nothing. A
-- | selection change in a column resets every column to its right to
-- | All, so the three selections always describe one path through the
-- | library and can never disagree with each other. The track list is
-- | what every selection together narrows to, and with nothing selected
-- | that is the whole library.
module Browse where

import Prelude

import Data.Array as Array
import Data.Enum (enumFromTo)
import Data.Foldable (foldl, sum)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith, toLower, toUpper, trim)
import Data.String.CodeUnits as CodeUnits
import Mpd (Song)
import Mpd as Mpd

data Axis = AxGenre | AxArtist | AxAlbum

derive instance eqAxis :: Eq Axis

-- | The columns in order, left to right. The genre column is not always
-- | drawn, so this is the full chain and `shownAxes` is what is on screen.
axisOrder :: Array Axis
axisOrder = [ AxGenre, AxArtist, AxAlbum ]

-- | A scrollable list's scroll position and how much of it is on screen.
type Viewport = { top :: Number, height :: Number }

-- | One column.
-- |
-- |   values    what MPD listed, in the order it listed them
-- |   selected  the values picked here; empty means All
-- |   anchor    the last row clicked without shift, which a shift click
-- |             extends from
-- |   gen       which request the values answer; a reply tagged with an
-- |             older one is thrown away
-- |   pending   how many replies the current request still waits for
-- |   expected  how many commands the current request was, which decides
-- |             whether the replies need merging
-- |   arriving  the replies collected so far; values is replaced only
-- |             when the last one lands, so a column being refreshed
-- |             keeps showing what it had until the new list is complete
type Column =
  { values :: Array String
  , selected :: Array String
  , anchor :: Maybe String
  , gen :: Int
  , pending :: Int
  , expected :: Int
  , arriving :: Array String
  , vp :: Viewport
  }

-- | One query behind the track list, and how many tracks it matches.
type TrackQuery = { terms :: String, count :: Int }

-- | The track list. Only one contiguous run of rows is held, starting
-- | at `from`: scrolling on extends it, and a jump that lands outside
-- | it starts a new run there.
type Tracks =
  { rows :: Array Song
  , from :: Int
  , pending :: Boolean
  , queries :: Array TrackQuery
  , gen :: Int
  , vp :: Viewport
  }

-- | The whole browser. `genreColumn` says whether the chain starts at
-- | genre or at artist. It starts at artist because a library of this
-- | age has hundreds of distinct genre strings, most of them spellings
-- | of each other, and a column of hundreds is not a way of choosing
-- | anything; the column is there for when the question really is
-- | "what reggae do I have".
type Browser =
  { genreColumn :: Boolean
  , genre :: Column
  , artist :: Column
  , album :: Column
  , tracks :: Tracks
  }

-- | A fresh column or list, before anything has been asked for. The
-- | height is a guess at the viewport, which the page replaces with a
-- | measurement as soon as the element exists; until then the guess is
-- | the window's height, so the first paint overdraws rather than
-- | stopping short of the bottom of a tall column.
emptyColumn :: Number -> Column
emptyColumn height =
  { values: []
  , selected: []
  , anchor: Nothing
  , gen: 0
  , pending: 0
  , expected: 0
  , arriving: []
  , vp: { top: 0.0, height }
  }

emptyTracks :: Number -> Tracks
emptyTracks height =
  { rows: []
  , from: 0
  , pending: false
  , queries: []
  , gen: 0
  , vp: { top: 0.0, height }
  }

emptyBrowser :: Number -> Browser
emptyBrowser height =
  { genreColumn: false
  , genre: emptyColumn height
  , artist: emptyColumn height
  , album: emptyColumn height
  , tracks: emptyTracks height
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
-- | keeping only its viewport height. This is what a column to the
-- | right of a change becomes before it is asked for again.
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

-- | The terms the selected values of these columns contribute, one
-- | dimension per column that has a selection. Each term is ready to
-- | follow `list`, `find` or `count`.
constraints :: Array Axis -> Browser -> Array (Array String)
constraints axes br = Array.filter (not <<< Array.null) (map terms axes)
  where
  terms axis = map (\v -> tagOf axis <> " " <> Mpd.quote v) (columnOf axis br).selected

-- | Is this column narrowed by nothing, so that it lists the whole
-- | library. Those are the lists worth keeping in the browser's store.
isPlain :: Axis -> Browser -> Boolean
isPlain axis br = Array.null (constraints (leftOf axis br) br)

-- | The commands one column is built from: `list <tag>` on its own when
-- | nothing narrows it, and otherwise one per combination of the values
-- | selected to its left, because MPD's filters have no OR. The replies
-- | are unioned as they arrive.
listCommands :: Axis -> Browser -> Array String
listCommands axis br = case combos (constraints (leftOf axis br) br) of
  [] -> [ "list " <> tagOf axis ]
  cs -> map (\c -> "list " <> tagOf axis <> " " <> c) cs

-- | The queries the track list is of, each one a filter ready to follow
-- | `find`, `findadd` or `count`. An empty array means no filter at all,
-- | which is the whole library.
trackCombos :: Browser -> Array String
trackCombos br = combos (constraints (shownAxes br) br)

-- | How many queries one selection may come to before the exact form is
-- | given up on. Thirty-two covers every selection a person makes by
-- | hand in three columns.
maxQueries :: Int
maxQueries = 32

-- | Every combination of one term per dimension, each written out as one
-- | filter. No dimensions is no combinations, which callers read as "no
-- | filter" rather than as "matches nothing".
-- |
-- | MPD's filter language has AND and NOT and no OR. Two selected artists
-- | are therefore two queries, not one filter, and two genres with three
-- | artists are six. The combinations are mutually exclusive, so their
-- | counts add up and their rows read as one list laid end to end.
-- |
-- | Past `maxQueries` the product is abandoned for the rightmost
-- | dimension on its own, ANDed with whichever dimensions to its left
-- | hold exactly one term. That is bounded by the rows actually selected
-- | rather than by their product, and it differs from the exact answer
-- | only where a value in the rightmost column also belongs to something
-- | outside the selection to its left, which in a music library means a
-- | compilation filed under two artists.
combos :: Array (Array String) -> Array String
combos dims = case dims of
  [] -> []
  _ -> if Array.length exact <= maxQueries then exact else fallback
  where
  exact = foldl step [ "" ] dims
  step acc ts = do
    a <- acc
    t <- ts
    pure (if a == "" then t else a <> " " <> t)

  fallback = Array.take maxQueries (map (\t -> if prefix == "" then t else prefix <> " " <> t) rightmost)
  rightmost = fromMaybe [] (Array.last dims)
  prefix = joinWith " " (Array.concat (map (\d -> if Array.length d == 1 then d else []) (fromMaybe [] (Array.init dims))))

-- | The tag name MPD takes in a command, and the one it labels the values
-- | with in a `list` reply, which is capitalised where the argument is
-- | not.
tagOf :: Axis -> String
tagOf = case _ of
  AxGenre -> "genre"
  AxArtist -> "artist"
  AxAlbum -> "album"

listLabel :: Axis -> String
listLabel = case _ of
  AxGenre -> "Genre"
  AxArtist -> "Artist"
  AxAlbum -> "Album"

axisLabel :: Axis -> String
axisLabel = listLabel

pluralOf :: Axis -> String
pluralOf = case _ of
  AxGenre -> "genres"
  AxArtist -> "artists"
  AxAlbum -> "albums"

-- | What the track list is of, said in words. One value is named; more
-- | than one is counted, because three dozen artist names is not a
-- | heading.
trackScope :: Browser -> String
trackScope br = case parts of
  [] -> "The whole library"
  _ -> joinWith ", " parts
  where
  parts = Array.mapMaybe describe (shownAxes br)
  describe a = case (columnOf a br).selected of
    [] -> Nothing
    [ v ] -> Just v
    vs -> Just (show (Array.length vs) <> " " <> pluralOf a)

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

-- | A union of several `list` replies, in one order. MPD's own order is
-- | kept when a column is one reply; only a union has to be sorted, and
-- | then this is the order available. Case is ignored so that the
-- | letter rail's groups are contiguous.
union :: Array String -> Array String
union = Array.sortBy (comparing toLower) <<< Array.nub

-- ---------------------------------------------------------------------
-- Rows and the slice of them that is drawn

-- | What is in a column's list: the All row, then one row per value.
data ColRow = AllRow | ValueRow String

-- | A column shows every entry it has. Only the rows inside the scroll
-- | viewport are put in the page, with a blank block above and below
-- | standing in for the rest, so the scrollbar is the true length of the
-- | list and the DOM holds a few dozen nodes instead of twelve thousand.
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
rowOfValue v col = (_ + 1) <$> Array.elemIndex v col.values

-- | The row of the first selected value that the column still holds.
selectionRow :: Column -> Maybe Int
selectionRow col = Array.head (Array.mapMaybe (\v -> rowOfValue v col) col.selected)

-- | The value drawn at the top of the viewport, which a refresh keeps
-- | in place when the column has no selection to pin instead.
topValue :: Column -> Maybe String
topValue col = Array.index col.values (Int.floor (col.vp.top / rowHeight) - 1)

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
-- | more work to read than the list it would move.
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

-- | The row where a letter starts in a column, so the rail can scroll
-- | to it. The rail moves the column; it never hides any of it.
firstUnder :: String -> Column -> Maybe Int
firstUnder l col = (_ + 1) <$> Array.findIndex (\v -> initialOf v == l) col.values

-- | Which letters a column actually has entries under, so the rail can
-- | grey out the rest instead of scrolling nowhere.
lettersPresent :: Column -> Array String
lettersPresent col = Array.nub (map initialOf col.values)

-- ---------------------------------------------------------------------
-- The track list

-- | How many tracks one request brings back. Small enough that the
-- | first page is instant on a library of any size, large enough that
-- | an ordinary scroll does not ask twice a second.
trackPage :: Int
trackPage = 200

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

-- | How many tracks the list is of: the per-query counts added up. With
-- | no filter there is one query, for the whole library, whose count is
-- | the song count from `stats`, because there is no filter expression
-- | that `count` will accept for "everything".
tracksTotal :: Tracks -> Int
tracksTotal t = sum (map _.count t.queries)

-- | The row the held run ends at, exclusive.
heldTo :: Tracks -> Int
heldTo t = t.from + Array.length t.rows