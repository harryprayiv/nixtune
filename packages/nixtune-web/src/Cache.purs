-- | The library index, kept in the browser between visits.
-- |
-- | The whole-library column lists are the slowest things the page asks
-- | for. MPD walks its whole database and answers with one line per
-- | distinct value and one per sort key, which for a library of seventy
-- | thousand tracks is tens of thousands of lines to send, receive, parse
-- | and order.
-- |
-- | They are also the things that change least often. Only a library
-- | rescan can change them, and MPD says when that last happened: `stats`
-- | carries db_update, a unix timestamp. So each list is written to
-- | localStorage under that stamp, already in the page's order, and a
-- | visit whose stamp matches draws the column with no request and no
-- | sort at all.
-- |
-- | Nothing here is load bearing. Every read can come back empty and
-- | every write can fail, and in both cases the page asks MPD the way it
-- | always did.
module Cache where

import Prelude

import Browse (TagValue)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), isJust)
import Data.String (Pattern(..), joinWith, split, stripPrefix)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Exception (try)
import Web.HTML (window)
import Web.HTML.Window (localStorage)
import Web.Storage.Storage (Storage)
import Web.Storage.Storage as Storage

-- | Every key this page has ever written starts with this.
family :: String
family = "nixtune.cache."

-- | Bumped when the shape of what is stored changes, so an entry written
-- | by an older page is never read back by a newer one. v1 held bare
-- | values; v2 holds each value with its sort key and year.
version :: String
version = "v2"

prefix :: String
prefix = family <> version <> "."

keyFor :: String -> Int -> String
keyFor name stamp = prefix <> name <> "." <> show stamp

-- | One value per line, its three fields separated by the unit separator
-- | (U+001F). The MPD protocol is newline delimited, so a tag value cannot
-- | contain a newline, and a tag holding a unit separator is not a thing
-- | any tagger writes. Far cheaper to read back than JSON for ten
-- | thousand records.
sep :: String
sep = "\x1F"

encode :: TagValue -> String
encode v = v.display <> sep <> v.key <> sep <> maybe' v.year
  where
  maybe' = case _ of
    Just y -> show y
    Nothing -> ""

decode :: String -> Maybe TagValue
decode line = case split (Pattern sep) line of
  [ display, key, year ] -> Just { display, key, year: Int.fromString year }
  _ -> Nothing

read :: String -> Int -> Effect (Maybe (Array TagValue))
read name stamp =
  if stamp <= 0 then pure Nothing
  else do
    s <- window >>= localStorage
    got <- attempt (Storage.getItem (keyFor name stamp) s)
    pure $ case got of
      Just (Just "") -> Nothing
      Just (Just raw) ->
        -- One malformed line means the entry is not ours or is damaged,
        -- and the honest answer is a miss.
        let
          lines = split (Pattern "\n") raw
          values = Array.mapMaybe decode lines
        in
          if Array.length values == Array.length lines then Just values else Nothing
      _ -> Nothing

-- | Writing is best effort: quota, a private window and blocked site
-- | data all throw, and none of them is worth an error on the page.
write :: String -> Int -> Array TagValue -> Effect Unit
write name stamp values =
  if stamp <= 0 || Array.null values then pure unit
  else do
    s <- window >>= localStorage
    prune s stamp
    _ <- attempt (Storage.setItem (keyFor name stamp) (joinWith "\n" (map encode values)) s)
    pure unit

-- | Drop every entry of ours that is not under this stamp and this
-- | version. A rescan otherwise leaves the old index behind for good, and
-- | an entry from an older version of the page is dead weight in a store
-- | of a few megabytes.
prune :: Storage -> Int -> Effect Unit
prune s stamp = do
  n <- Storage.length s
  keys <- traverse (\i -> Storage.key i s) (Array.range 0 (n - 1))
  let
    ours = Array.filter (\k -> isJust (stripPrefix (Pattern family) k)) (Array.catMaybes keys)
    current k = case stripPrefix (Pattern prefix) k of
      Nothing -> false
      Just rest -> case Array.last (split (Pattern ".") rest) of
        Just st -> st == show stamp
        Nothing -> false
  _ <- traverse (\k -> attempt (Storage.removeItem k s)) (Array.filter (not <<< current) ours)
  pure unit

attempt :: forall a. Effect a -> Effect (Maybe a)
attempt act = do
  r <- try act
  pure case r of
    Right a -> Just a
    Left _ -> Nothing