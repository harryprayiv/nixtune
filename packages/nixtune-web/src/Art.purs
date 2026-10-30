-- | Cover images, straight out of the library over HTTP.
-- |
-- | MPD's own albumart and readpicture commands answer with binary, which
-- | a text-mode websocket cannot carry, so nginx serves the image files
-- | that sit beside the audio (nix/module/ui.nix). Nothing is read out of
-- | tags: an album whose art is embedded in the files and has no cover
-- | file beside them shows none.
module Art where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..), replaceAll)
import Data.String as String
import Types (State, isStream)

-- | The cover file names a library might use, in the order they are
-- | tried. Case matters on the filesystem the library lives on, so the
-- | capitalised spellings are listed too.
artNames :: Array String
artNames =
  [ "cover.jpg"
  , "cover.jpeg"
  , "cover.png"
  , "folder.jpg"
  , "front.jpg"
  , "Cover.jpg"
  , "Folder.jpg"
  ]

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
