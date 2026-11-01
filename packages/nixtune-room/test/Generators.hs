-- | The home the tests run in, and random runs of events against one
-- room's coordinator.
module Generators
  ( room
  , kitchen
  , lab
  , livingRoom
  , attic
  , home
  , testConfig
  , Run (..)
  , Stepped (..)
  , runEvents
  , genRun
  )
where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Nixtune.Room.Clock (Duration (..), Instant (..), Millis (..), milliseconds, minutes, seconds)
import Nixtune.Room.Coordinator
import Nixtune.Room.Name (RoomName, mkRoomName)
import Nixtune.Room.Protocol
import Nixtune.Room.State (RoomState, initialState)
import Test.QuickCheck

room :: Text -> RoomName
room t = fromMaybe (error ("bad test room name " <> show t)) (mkRoomName t)

kitchen, lab, livingRoom, attic :: RoomName
kitchen = room "kitchen"
lab = room "lab"
livingRoom = room "living-room"
-- | Not declared anywhere.
attic = room "attic"

home :: [RoomName]
home = [kitchen, lab, livingRoom]

-- | The three rooms, with acoustics that make the alignment non-trivial:
-- from the kitchen the lab is 9 ms away and the living room 14 ms.
testConfig :: Config
testConfig =
  Config
    { peers = Map.fromList [(kitchen, Millis 0), (lab, Millis 0), (livingRoom, Millis 2)]
    , acoustics =
        Map.fromList
          [ (kitchen, Map.fromList [(kitchen, Millis 1), (lab, Millis 9), (livingRoom, Millis 14)])
          , (lab, Map.fromList [(lab, Millis 1), (kitchen, Millis 9)])
          , (livingRoom, Map.fromList [(livingRoom, Millis 2), (kitchen, Millis 14)])
          ]
    , audienceGrace = seconds 10
    , orphanTimeout = minutes 3
    , playerReadyTimeout = seconds 10
    , maxSuspension = minutes 30
    }

-- | A run: the room, and timed events in order. Each request carries its
-- own ReplyTo, numbered from 1.
data Run = Run
  { runRoom :: RoomName
  , runEvents' :: [(Instant, Event)]
  }
  deriving stock (Show)

data Stepped = Stepped
  { before' :: RoomState
  , event :: Event
  , now' :: Instant
  , after' :: RoomState
  , effects :: [Effect]
  }
  deriving stock (Show)

runEvents :: Run -> [Stepped]
runEvents (Run name evs) = go (initialState name) evs
  where
    go _ [] = []
    go st ((t, e) : rest) =
      let (st', es) = step testConfig t e st
       in Stepped st e t st' es : go st' rest

genRoomName :: Gen RoomName
genRoomName = frequency [(9, elements home), (1, pure attic)]

genRequest :: Gen Request
genRequest =
  oneof
    [ ReqFollow <$> genRoomName
    , pure ReqOwn
    , pure ReqSilence
    , ReqHold <$> genRoomName
    , ReqRelease <$> genRoomName
    , ReqSuspend <$> genRoomName
    , ReqPin <$> genRoomName
    , pure ReqUnpin
    , ReqInterruptionStarts <$> arbitraryBoundedEnum
    , ReqInterruptionEnds <$> arbitraryBoundedEnum
    ]

genEvent :: Gen (Int -> Event)
genEvent =
  frequency
    [ (6, (\req n -> Requested (ReplyTo n) req) <$> genRequest)
    , (2, (\r x _ -> HoldAnswered r x) <$> genRoomName <*> genAnswer)
    , (2, (\r v _ -> PeerProbed r v) <$> genRoomName <*> genView)
    , (3, (\r _ -> PlayerAvailable r) <$> genRoomName)
    , (2, (\r _ -> PlayerGone r) <$> genRoomName)
    , (2, (\b _ -> MpdPlaying b) <$> arbitrary)
    , (4, pure (const Tick))
    ]
  where
    genAnswer = frequency [(3, pure (Right ())), (1, Left <$> arbitraryBoundedEnum)]
    genView =
      frequency
        [ (1, pure Nothing)
        , (3, fmap Just (PeerView <$> (Set.fromList <$> sublistOf home) <*> frequency [(4, pure Nothing), (1, Just <$> genRoomName)]))
        ]

-- | Up to 60 events, a few milliseconds to several minutes apart, so that
-- deadlines, grace periods and orphan timeouts all get crossed.
genRun :: Gen Run
genRun = do
  name <- elements home
  n <- chooseInt (1, 60)
  gaps <- vectorOf n (frequency [(6, chooseInt64 (1, 2000)), (3, chooseInt64 (2000, 15000)), (1, chooseInt64 (15000, 300000))])
  mk <- vectorOf n genEvent
  let times = scanl1 (+) gaps
      evs = zipWith3 (\t f i -> (at t, f i)) times mk [1 ..]
  pure (Run name evs)
  where
    at t = let Duration us = milliseconds t in Instant us
    chooseInt64 (a, b) = fromIntegral <$> chooseInt (a, b)
