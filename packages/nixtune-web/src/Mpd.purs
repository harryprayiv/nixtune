-- | The MPD protocol, as much of it as the page needs: quoting a command
-- | argument, and reading the key: value lines of a response into the
-- | records the page shows.
-- |
-- | A response is the lines between a command and its terminating "OK" or
-- | "ACK ..." line. The page collects those lines per connection; these
-- | functions only read a complete block.
module Mpd
  ( PlayState(..)
  , Quality(..)
  , Format
  , Status
  , Song
  , Entry(..)
  , emptyStatus
  , isEnd
  , isGreeting
  , isError
  , parseStatus
  , parseSongs
  , parseEntries
  , parseStats
  , parseList
  , parseSticker
  , parseStickers
  , quote
  , songTitle
  , songLine
  , fileFormat
  , streamFormat
  , basename
  , extension
  , clock
  ) where

import Prelude

import Data.Array (catMaybes, foldl, snoc)
import Data.Array as Array
import Data.Int (floor, fromString)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number as Number
import Data.String (Pattern(..), Replacement(..), indexOf, joinWith, replaceAll, splitAt, stripPrefix)
import Data.String as String
import Data.Foldable (lookup)
import Data.Tuple (Tuple(..))

data PlayState = Playing | Paused | Stopped

derive instance eqPlayState :: Eq PlayState

-- | Whether a file keeps every sample it started with. Decided from the
-- | container, which is all the page has: MPD's own quality figures are
-- | about what the decoder is handing the DAC, not about the file.
data Quality = Lossless | Lossy

derive instance eqQuality :: Eq Quality

-- | How a file is labelled on the page: what to print, and whether that
-- | counts as lossless.
type Format = { label :: String, quality :: Quality }

type Status =
  { state :: PlayState
  , volume :: Maybe Int
  , elapsed :: Number
  , duration :: Number
  , song :: Maybe Int
  , random :: Boolean
  , repeat :: Boolean
  , single :: Boolean
  , consume :: Boolean
  , updating :: Boolean
  -- What the decoder is actually producing, as MPD's "audio" line:
  -- samplerate:bits:channels, with "f" or "dsd64" in the bits field for
  -- a float or DSD stream. Absent when nothing is playing.
  , audio :: Maybe String
  , bitrate :: Maybe Int
  , error :: Maybe String
  }

emptyStatus :: Status
emptyStatus =
  { state: Stopped
  , volume: Nothing
  , elapsed: 0.0
  , duration: 0.0
  , song: Nothing
  , random: false
  , repeat: false
  , single: false
  , consume: false
  , updating: false
  , audio: Nothing
  , bitrate: Nothing
  , error: Nothing
  }

type Song =
  { file :: String
  , title :: Maybe String
  , artist :: Maybe String
  , album :: Maybe String
  , name :: Maybe String
  , pos :: Maybe Int
  , id :: Maybe Int
  , duration :: Number
  }

-- | One line of an lsinfo listing.
data Entry
  = Dir String
  | File Song
  | Playlist String

-- | The line that ends a response block.
isEnd :: String -> Boolean
isEnd l = l == "OK" || isError l

isError :: String -> Boolean
isError l = stripPrefix (Pattern "ACK ") l /= Nothing

-- | The first line MPD sends on a new connection.
isGreeting :: String -> Boolean
isGreeting l = stripPrefix (Pattern "OK MPD ") l /= Nothing

-- | "key: value" into a pair. Lines without the separator are dropped.
pair :: String -> Maybe (Tuple String String)
pair l = case indexOf (Pattern ": ") l of
  Nothing -> Nothing
  Just i ->
    let
      { before, after } = splitAt i l
    in
      Just (Tuple before (String.drop 2 after))

pairs :: Array String -> Array (Tuple String String)
pairs = catMaybes <<< map pair

parseStatus :: Array String -> Status
parseStatus ls =
  { state: case lookup "state" ps of
      Just "play" -> Playing
      Just "pause" -> Paused
      _ -> Stopped
  -- MPD reports volume -1 when the output has no mixer at all. That is
  -- not a level, so it reads as absent and the page shows no volume
  -- control rather than a bar sitting at minus one.
  , volume: lookup "volume" ps >>= fromString >>= \v -> if v < 0 then Nothing else Just v
  , elapsed: number "elapsed"
  , duration: number "duration"
  , song: lookup "song" ps >>= fromString
  , random: lookup "random" ps == Just "1"
  , repeat: lookup "repeat" ps == Just "1"
  , single: lookup "single" ps == Just "1"
  , consume: lookup "consume" ps == Just "1"
  , updating: lookup "updating_db" ps /= Nothing
  , audio: lookup "audio" ps
  , bitrate: lookup "bitrate" ps >>= fromString
  , error: lookup "error" ps
  }
  where
  ps = pairs ls
  number k = fromMaybe 0.0 (lookup k ps >>= Number.fromString)

-- | Songs from playlistinfo or currentsong: each begins at a "file:" line
-- | and runs to the next one.
parseSongs :: Array String -> Array Song
parseSongs ls = finish (foldl step { current: Nothing, done: [] } (pairs ls))
  where
  step acc (Tuple k v) = case k, acc.current of
    "file", Just s -> { current: Just (newSong v), done: snoc acc.done s }
    "file", Nothing -> { current: Just (newSong v), done: acc.done }
    _, Just s -> acc { current = Just (field k v s) }
    _, Nothing -> acc
  finish acc = case acc.current of
    Just s -> snoc acc.done s
    Nothing -> acc.done

newSong :: String -> Song
newSong file =
  { file
  , title: Nothing
  , artist: Nothing
  , album: Nothing
  , name: Nothing
  , pos: Nothing
  , id: Nothing
  , duration: 0.0
  }

field :: String -> String -> Song -> Song
field k v s = case k of
  "Title" -> s { title = Just v }
  "Artist" -> s { artist = Just v }
  "Album" -> s { album = Just v }
  "Name" -> s { name = Just v }
  "Pos" -> s { pos = fromString v }
  "Id" -> s { id = fromString v }
  "duration" -> s { duration = fromMaybe 0.0 (Number.fromString v) }
  _ -> s

-- | An lsinfo listing: directories, playlists and files, in MPD's order.
-- | A file's tags follow its "file:" line, the same shape as parseSongs.
parseEntries :: Array String -> Array Entry
parseEntries ls = flush (foldl step { current: Nothing, done: [] } (pairs ls))
  where
  step acc (Tuple k v) = case k of
    "directory" -> { current: Nothing, done: snoc (flush acc) (Dir v) }
    "playlist" -> { current: Nothing, done: snoc (flush acc) (Playlist v) }
    "file" -> { current: Just (newSong v), done: flush acc }
    _ -> case acc.current of
      Just s -> acc { current = Just (field k v s) }
      Nothing -> acc
  flush acc = case acc.current of
    Just s -> snoc acc.done (File s)
    Nothing -> acc.done

-- | The song count from a `stats` reply; zero when absent.
parseStats :: Array String -> Int
parseStats ls = fromMaybe 0 (lookup "songs" (pairs ls) >>= fromString)

-- | The value of a `sticker get song <uri> <name>` reply, whose one line is
-- | "sticker: <name>=<value>". Nothing when the song has no such sticker,
-- | which MPD reports as an error rather than an empty reply.
parseSticker :: Array String -> Maybe String
parseSticker ls = case lookup "sticker" (pairs ls) of
  Just kv -> case indexOf (Pattern "=") kv of
    Just i -> Just (String.drop (i + 1) kv)
    Nothing -> Nothing
  Nothing -> Nothing

-- | A `list <tag> ...` reply: one "<Tag>: value" line per distinct
-- | value, in MPD's own order. Empty values are dropped, because a file
-- | with no genre answers with an empty string and an empty row in a
-- | column is not selectable.
parseList :: String -> Array String -> Array String
parseList tag ls =
  Array.filter (_ /= "") (map (\(Tuple _ v) -> v) (Array.filter (\(Tuple k _) -> k == tag) (pairs ls)))

-- | A `sticker find song "" <name>` reply: alternating "file: <uri>" and
-- | "sticker: <name>=<value>" lines, one pair for every song in the
-- | database that carries the sticker.
-- |
-- | One command in place of one request per queue entry. At a few hundred
-- | entries the per-song form put a few hundred round trips on the command
-- | connection every time the queue changed, which is long enough to make
-- | the page look broken while it caught up.
parseStickers :: Array String -> Array (Tuple String String)
parseStickers ls = (foldl step { uri: Nothing, done: [] } (pairs ls)).done
  where
  step acc (Tuple k v) = case k of
    "file" -> acc { uri = Just v }
    "sticker" -> case acc.uri, indexOf (Pattern "=") v of
      Just u, Just i -> acc { done = snoc acc.done (Tuple u (String.drop (i + 1) v)) }
      _, _ -> acc
    _ -> acc

-- | A command argument: backslash and double quote escaped, the whole thing
-- | quoted.
quote :: String -> String
quote s = "\"" <> replaceAll (Pattern "\"") (Replacement "\\\"") (replaceAll (Pattern "\\") (Replacement "\\\\") s) <> "\""

-- | What to call a song: its title, or a stream's name, or its file name.
songTitle :: Song -> String
songTitle s = case s.title, s.name of
  Just t, _ -> t
  Nothing, Just n -> n
  Nothing, Nothing -> basename s.file

-- | The second line under a title: artist and album when known.
songLine :: Song -> String
songLine s = joinWith " · " (catMaybes [ s.artist, s.album ])

basename :: String -> String
basename f = case String.lastIndexOf (Pattern "/") f of
  Just i -> String.drop (i + 1) f
  Nothing -> f

-- | The file extension, lower case and without the dot. Empty when the
-- | last path component has none.
extension :: String -> String
extension f =
  let
    b = basename f
  in
    case String.lastIndexOf (Pattern ".") b of
      Just i | i > 0 -> String.toLower (String.drop (i + 1) b)
      _ -> ""

-- | What a file is, from its extension. Nothing for a stream URL and for
-- | an extension not listed, so an unrecognised file gets no badge rather
-- | than a wrong one.
-- |
-- | The extension is all the page has to go on. MPD does not report a
-- | codec per file in a listing, and reading the container would mean
-- | fetching the file. It is right often enough to sort a library by, and
-- | the figures under the title while a track plays come from the decoder
-- | rather than from this.
fileFormat :: String -> Maybe Format
fileFormat f
  | indexOf (Pattern "://") f /= Nothing = Nothing
  | otherwise = case extension f of
      "flac" -> lossless "FLAC"
      "wav" -> lossless "WAV"
      "aiff" -> lossless "AIFF"
      "aif" -> lossless "AIFF"
      "alac" -> lossless "ALAC"
      "ape" -> lossless "APE"
      "wv" -> lossless "WavPack"
      "dsf" -> lossless "DSD"
      "dff" -> lossless "DSD"
      "mp3" -> lossy "MP3"
      "ogg" -> lossy "Vorbis"
      "oga" -> lossy "Vorbis"
      "opus" -> lossy "Opus"
      "aac" -> lossy "AAC"
      "wma" -> lossy "WMA"
      -- .m4a is AAC far more often than it is ALAC, and the name does
      -- not say which. Labelled by its container and not claimed to be
      -- lossless either way.
      "m4a" -> lossy "M4A"
      "mp4" -> lossy "M4A"
      _ -> Nothing
  where
  lossless label = Just { label, quality: Lossless }
  lossy label = Just { label, quality: Lossy }

-- | MPD's audio line, samplerate:bits:channels, as something short:
-- | "16/44.1", "24/96", "DSD/2822.4". Nothing when it is not that shape.
streamFormat :: String -> Maybe String
streamFormat a = case String.split (Pattern ":") a of
  [ rate, bits, _ ] -> case fromString rate of
    Nothing -> Nothing
    Just r -> case fromString bits of
      Just _ -> Just (bits <> "/" <> khz r)
      -- "dsd" and "f" (float) appear where a bit depth would be.
      Nothing -> Just (String.toUpper bits <> "/" <> khz r)
  _ -> Nothing
  where
  -- One decimal, and no trailing ".0": 44100 reads 44.1, 48000 reads 48.
  khz r =
    let
      tenths = (r + 50) / 100
      whole = Int.toStringAs Int.decimal (tenths / 10)
      frac = tenths `mod` 10
    in
      if frac == 0 then whole else whole <> "." <> Int.toStringAs Int.decimal frac

-- | Seconds as m:ss or h:mm:ss.
clock :: Number -> String
clock n =
  let
    total = floor n
    h = total / 3600
    m = (total `mod` 3600) / 60
    s = total `mod` 60
    two x = if x < 10 then "0" <> Int.toStringAs Int.decimal x else Int.toStringAs Int.decimal x
  in
    if h > 0 then Int.toStringAs Int.decimal h <> ":" <> two m <> ":" <> two s
    else Int.toStringAs Int.decimal m <> ":" <> two s
