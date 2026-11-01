-- | The parts of MPD's text protocol nixtune-room uses: responses as
-- key/value pairs ending in OK or ACK, the player state from @status@,
-- and the outputs from @outputs@.
module Nixtune.Mpd.Protocol
  ( Response (..)
  , Output (..)
  , PlayState (..)
  , pair
  , playState
  , parseOutputs
  , outputNamed
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | A complete response: the key/value lines before OK, or the ACK line.
data Response
  = Done [(Text, Text)]
  | Failed Text
  deriving stock (Eq, Show)

data Output = Output
  { outputId :: Int
  , outputName :: Text
  , outputEnabled :: Bool
  }
  deriving stock (Eq, Show)

data PlayState = Playing | Paused | Stopped
  deriving stock (Eq, Show)

-- | One response line, "key: value".
pair :: Text -> Maybe (Text, Text)
pair line = case Text.breakOn ": " line of
  (k, v) | not (Text.null v) -> Just (k, Text.drop 2 v)
  _ -> Nothing

playState :: [(Text, Text)] -> Maybe PlayState
playState kv = case lookup "state" kv of
  Just "play" -> Just Playing
  Just "pause" -> Just Paused
  Just "stop" -> Just Stopped
  _ -> Nothing

-- | @outputs@ lists each output as a run of lines starting at outputid.
parseOutputs :: [(Text, Text)] -> [Output]
parseOutputs = go
  where
    go (("outputid", i) : rest) =
      let (fields, more) = break ((== "outputid") . fst) rest
       in case (readMaybe (Text.unpack i), lookup "outputname" fields, lookup "outputenabled" fields) of
            (Just n, Just name, Just en) -> Output n name (en == "1") : go more
            _ -> go more
    go (_ : rest) = go rest
    go [] = []

outputNamed :: Text -> [Output] -> Maybe Output
outputNamed name = find ((== name) . outputName)
