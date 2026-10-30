-- | The MPD protocol, as much of it as the page needs: quoting a command
-- | argument, and reading the key: value lines of a response into the
-- | records the page shows.
-- |
-- | A response is the lines between a command and its terminating "OK" or
-- | "ACK ..." line. The page collects those lines per connection; these
-- | functions only read a complete block.
module Mpd
  ( PlayState(..)
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
  , parseSticker
  , quote
  , songTitle
  , songLine
  , basename
  , clock
  ) where

import Prelude

import Data.Array (catMaybes, foldl, snoc)
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