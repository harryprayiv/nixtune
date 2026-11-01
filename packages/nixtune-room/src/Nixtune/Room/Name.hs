-- | Room names, as services.nixtune.multiroom.room declares them:
-- strMatching "[a-z][a-z0-9-]*". The only way to make a 'RoomName' is
-- 'mkRoomName', so every name the coordinator holds has passed that check.
module Nixtune.Room.Name
  ( RoomName
  , mkRoomName
  , roomNameText
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text

newtype RoomName = RoomName Text
  deriving stock (Eq, Ord, Show)

mkRoomName :: Text -> Maybe RoomName
mkRoomName t = case Text.uncons t of
  Just (c, rest)
    | isAsciiLower c && Text.all allowed rest -> Just (RoomName t)
  _ -> Nothing
  where
    allowed x = isAsciiLower x || isDigit x || x == '-'

roomNameText :: RoomName -> Text
roomNameText (RoomName t) = t
