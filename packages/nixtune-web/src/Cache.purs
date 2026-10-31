-- | The library index, kept in the browser between visits.
-- |
-- | `list artist` is the slowest thing the page asks for. MPD walks its
-- | whole database and answers with one line per distinct name, which
-- | for a library of seventy thousand tracks is around ten thousand
-- | lines to send, receive and parse. Measured cold at over a second.
-- |
-- | It is also the thing that changes least often. Only a library rescan
-- | can change it, and MPD says when that last happened: `stats` carries
-- | db_update, a unix timestamp. So the list is written to localStorage
-- | under that stamp, and a visit whose stamp matches draws the column
-- | with no request at all.
-- |
-- | Nothing here is load bearing. Every read can come back empty and
-- | every write can fail, and in both cases the page asks MPD the way it
-- | always did.
module Cache where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), joinWith, split, stripPrefix)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Exception (try)
import Web.HTML (window)
import Web.HTML.Window (localStorage)
import Web.Storage.Storage (Storage)
import Web.Storage.Storage as Storage

-- | Bumped when the shape of what is stored changes, so an entry written
-- | by an older page is never read back by a newer one.
version :: String
version = "v1"

prefix :: String
prefix = "nixtune.cache." <> version <> "."

keyFor :: String -> Int -> String
keyFor name stamp = prefix <> name <> "." <> show stamp

-- | Values are newline joined. The MPD protocol is newline delimited, so
-- | a tag value cannot contain one, which makes this unambiguous and far
-- | cheaper to parse than JSON for a flat list of ten thousand strings.
read :: String -> Int -> Effect (Maybe (Array String))
read name stamp =
  if stamp <= 0 then pure Nothing
  else do
    s <- window >>= localStorage
    got <- attempt (Storage.getItem (keyFor name stamp) s)
    pure $ case got of
      Just (Just "") -> Nothing
      Just (Just raw) -> Just (split (Pattern "\n") raw)
      _ -> Nothing

-- | Writing is best effort: quota, a private window and blocked site
-- | data all throw, and none of them is worth an error on the page.
write :: String -> Int -> Array String -> Effect Unit
write name stamp values =
  if stamp <= 0 || Array.null values then pure unit
  else do
    s <- window >>= localStorage
    prune s stamp
    _ <- attempt (Storage.setItem (keyFor name stamp) (joinWith "\n" values) s)
    pure unit

-- | Drop every entry of ours under a stamp other than this one. A rescan
-- | otherwise leaves the old index behind for good, and two of these
-- | lists is most of what a browser will store for one origin.
prune :: Storage -> Int -> Effect Unit
prune s stamp = do
  n <- Storage.length s
  keys <- traverse (\i -> Storage.key i s) (Array.range 0 (n - 1))
  let
    ours = Array.mapMaybe identity keys
    stale = Array.filter isStale ours
    isStale k = case stripPrefix (Pattern prefix) k of
      Nothing -> false
      Just rest -> not (Array.any (\nm -> keyFor nm stamp == k) (names rest))
    -- The name is whatever sits between the prefix and the stamp, so a
    -- key is matched against the current stamp under its own name
    -- rather than by taking the string apart.
    names rest = case Array.init (split (Pattern ".") rest) of
      Just parts -> [ joinWith "." parts ]
      Nothing -> []
  _ <- traverse (\k -> attempt (Storage.removeItem k s)) stale
  pure unit

attempt :: forall a. Effect a -> Effect (Maybe a)
attempt act = do
  r <- try act
  pure case r of
    Right a -> Just a
    Left _ -> Nothing
