-- | Who the browser is: the role, taken from the path the page was opened
-- | at, and the nickname a guest is given on first visit and keeps in
-- | localStorage. The nickname is how a host sees who queued what; it is
-- | a label, not a credential.
module Nick where

import Prelude

import Data.Array (length)
import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Effect (Effect)
import Effect.Random (randomInt)
import Types (Role(..), nicknameKey)
import Web.HTML (window)
import Web.HTML.Location as Location
import Web.HTML.Window (localStorage, location)
import Web.Storage.Storage as Storage

-- | Which page this is, from the path it was opened at.
roleFromPath :: String -> Effect Role
roleFromPath hostPath = do
  loc <- window >>= location
  p <- Location.pathname loc
  pure (if p == hostPath || p == hostPath <> "/" then Host else Guest)

-- | The nickname kept in this browser, made up on the first visit.
nicknameFor :: Effect String
nicknameFor = do
  storage <- window >>= localStorage
  kept <- Storage.getItem nicknameKey storage
  case kept of
    Just n -> pure n
    Nothing -> do
      a <- randomInt 0 (length adjectives - 1)
      b <- randomInt 0 (length animals - 1)
      let
        n = fromMaybe "quiet" (Array.index adjectives a) <> " " <> fromMaybe "otter" (Array.index animals b)
      Storage.setItem nicknameKey n storage
      pure n

adjectives :: Array String
adjectives =
  [ "amber", "brisk", "calm", "dusty", "early", "fuzzy", "gentle", "hollow"
  , "ivory", "jolly", "keen", "lucky", "mellow", "nimble", "olive", "plaid"
  , "quiet", "rusty", "sleepy", "tidy", "upbeat", "velvet", "witty", "zesty"
  ]

animals :: Array String
animals =
  [ "otter", "heron", "badger", "lynx", "moose", "finch", "newt", "ibis"
  , "puffin", "stoat", "tapir", "wren", "yak", "marten", "coot", "dingo"
  , "egret", "gecko", "hare", "kiwi", "loon", "mole", "osprey", "quail"
  ]
