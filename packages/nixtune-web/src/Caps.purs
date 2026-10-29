-- | What this host was built with: capabilities.json, written by the Nix
-- | module (nix/module/ui.nix) at build time and served beside the page.
-- | The page shows a module only if it is listed here, so a renderer that
-- | is off in Nix has no tab, badge or button.
module Caps
  ( Caps
  , Station
  , fetch
  ) where

import Prelude

import Affjax.ResponseFormat as ResponseFormat
import Affjax.Web as AX
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError)
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Maybe (Maybe)
import Effect.Aff (Aff)

type Station = { name :: String, url :: String }

type Caps =
  { hostname :: String
  , hardware ::
      { profile :: String
      , output :: String
      , card :: Maybe String
      , mixer :: Maybe String
      }
  , modules :: Array String
  , library :: Boolean
  , stations :: Array Station
  , websocketPath :: String
  , maxVolume :: Int
  }

fetch :: Aff (Either String Caps)
fetch = do
  r <- AX.get ResponseFormat.json "capabilities.json"
  pure $ case r of
    Left e -> Left (AX.printError e)
    Right res -> lmap printJsonDecodeError (decodeJson res.body)
