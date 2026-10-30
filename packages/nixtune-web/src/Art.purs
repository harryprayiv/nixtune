-- | Cover images, from the cache the player builds.
-- |
-- | MPD's own albumart and readpicture commands answer with binary, which
-- | a text-mode websocket cannot carry, so the pictures are extracted on
-- | the player instead (nix/module/art.nix) into a tree that mirrors the
-- | library, one cover.jpg per album directory, whether the picture was a
-- | file beside the audio or a frame inside it. That is why there is one
-- | name to ask for here rather than a list of the names a ripper might
-- | have used: the cache settles that question before the page is
-- | involved.
module Art where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..), replaceAll)
import Data.String as String
import Types (State, isStream)

-- | The names tried, in order. The cache writes exactly one, so an album
-- | with no art costs a single 404 and the page stops asking.
artNames :: Array String
artNames = [ "cover.jpg" ]

-- | The URL of the cover to try for a track, or Nothing when the host
-- | serves no art, the track is a stream, or every name has been tried.
artUrl :: State -> Maybe String
artUrl st = do
  base <- st.caps >>= _.artPath
  song <- st.current
  name <- Array.index artNames st.artTry
  if isStream song.file then Nothing
  else case String.lastIndexOf (Pattern "/") song.file of
    Nothing -> Nothing
    Just i -> Just (base <> "/" <> escapePath (String.take i song.file) <> "/" <> name)

-- | A library path as a URL path. The browser percent-encodes spaces and
-- | the rest on its own, but not these three, which change what the URL
-- | means rather than how it looks.
escapePath :: String -> String
escapePath =
  replaceAll (Pattern "%") (Replacement "%25")
    >>> replaceAll (Pattern "#") (Replacement "%23")
    >>> replaceAll (Pattern "?") (Replacement "%3F")
