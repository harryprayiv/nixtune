module CoordinatorSpec (spec) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Generators
import Nixtune.Room.Clock (Duration (..), Instant (..), Millis (..), milliseconds)
import Nixtune.Room.Coordinator
import Nixtune.Room.Name (RoomName)
import Nixtune.Room.Outputs (Action (..))
import Nixtune.Room.Protocol
import Nixtune.Room.State
import Test.Hspec
import Test.QuickCheck

at :: Int64 -> Instant
at ms = let Duration us = milliseconds ms in Instant us

-- | Run timed events (milliseconds) from boot; the final state and the
-- effects of every step.
scenario :: RoomName -> [(Int64, Event)] -> (RoomState, [[Effect]])
scenario name = foldl go (initialState name, [])
  where
    go (st, acc) (t, e) = let (st', es) = step testConfig (at t) e st in (st', acc <> [es])

req :: Int -> Request -> Event
req n = Requested (ReplyTo n)

ok :: Int -> Effect
ok n = Reply (ReplyTo n) (Right ())

no :: Int -> Refusal -> Effect
no n why = Reply (ReplyTo n) (Left why)

-- | A source with a held follower: the lab, holding the kitchen.
labHoldingKitchen :: [(Int64, Event)]
labHoldingKitchen =
  [ (0, MpdPlaying True)
  , (1, req 1 (ReqHold kitchen))
  , (500, PlayerAvailable kitchen)
  ]

-- | The kitchen, following the lab.
kitchenFollowingLab :: [(Int64, Event)]
kitchenFollowingLab =
  [ (0, MpdPlaying True)
  , (1, req 2 (ReqFollow lab))
  , (300, HoldAnswered lab (Right ()))
  ]

spec :: Spec
spec = do
  describe "a source room" $ do
    it "moves to its own server when the first follower asks to be held" $ do
      let (_, es) = scenario lab (take 2 labHoldingKitchen)
      last es
        `shouldBe` [ Act EnableFifo
                   , Act DisableAlsa
                   , Act HoldOwnPlayer
                   , ServerHold kitchen
                   , SendDelays (Map.fromList [(lab, Millis 0)])
                   , StatusChanged
                   ]
    it "answers the hold once the player is available, and aligns for itself" $ do
      let (st, es) = scenario lab labHoldingKitchen
      last es
        `shouldBe` [ ok 1
                   , SendDelays (Map.fromList [(lab, Millis 8), (kitchen, Millis 0)])
                   , StatusChanged
                   ]
      path st `shouldBe` OwnServer
    it "goes back to the direct path after the grace period, without pausing MPD" $ do
      let (st, es) = scenario lab (labHoldingKitchen <> [(2000, PlayerGone kitchen), (13000, Tick)])
      last es `shouldBe` [Act ReleaseOwnPlayer, Act EnableAlsa, Act DisableFifo, StatusChanged]
      path st `shouldBe` Direct
      concat es `shouldNotContain` [PauseMpd]
    it "keeps streaming through a reconnect inside the grace period" $ do
      let (st, _) =
            scenario lab (labHoldingKitchen <> [(2000, PlayerGone kitchen), (5000, PlayerAvailable kitchen), (13000, Tick)])
      path st `shouldBe` OwnServer
    it "keeps the group playing when AirPlay takes its own speaker" $ do
      let (st, es) = scenario lab (labHoldingKitchen <> [(1000, req 3 (ReqInterruptionStarts AirPlay))])
      last es
        `shouldBe` [ Act ReleaseOwnPlayer
                   , ok 3
                   , SendDelays (Map.fromList [(kitchen, Millis 0)])
                   , StatusChanged
                   ]
      fifoOutput (outputs st) `shouldBe` True
    it "takes its speaker back into the group when AirPlay ends" $ do
      let (st, es) =
            scenario lab (labHoldingKitchen <> [(1000, req 3 (ReqInterruptionStarts AirPlay)), (9000, req 4 (ReqInterruptionEnds AirPlay))])
      take 2 (last es) `shouldBe` [Act HoldOwnPlayer, ok 4]
      path st `shouldBe` OwnServer
    it "keeps a suspended follower and still streams for it" $ do
      let (st, _) =
            scenario lab (labHoldingKitchen <> [(1000, req 5 (ReqSuspend kitchen)), (1500, PlayerGone kitchen), (20000, Tick)])
      Map.lookup kitchen (members st) `shouldSatisfy` maybe False isSuspended
      path st `shouldBe` OwnServer
    it "refuses a player that never becomes available" $ do
      let (st, es) = scenario lab [(0, req 1 (ReqHold kitchen)), (11000, Tick)]
      last es `shouldContain` [no 1 PlayerNotReady, ServerRelease kitchen]
      Map.member kitchen (members st) `shouldBe` False

  describe "a following room" $ do
    it "pauses its own MPD, frees the DAC, then asks the source to hold it" $ do
      let (_, es) = scenario kitchen (take 2 kitchenFollowingLab)
      last es `shouldBe` [PauseMpd, Act DisableAlsa, Act (AskHold lab), StatusChanged]
    it "replies once the source has answered" $ do
      let (st, es) = scenario kitchen kitchenFollowingLab
      last es `shouldBe` [ok 2, StatusChanged]
      path st `shouldBe` PeerServer lab
    it "goes back to its own queue when the source refuses" $ do
      let (st, es) = scenario kitchen (take 2 kitchenFollowingLab <> [(300, HoldAnswered lab (Left PlayerNotReady))])
      last es `shouldBe` [Act (AskRelease lab), Act EnableAlsa, no 2 PlayerNotReady, StatusChanged]
      path st `shouldBe` Direct
    it "falls back to its own queue after the orphan timeout" $ do
      let (st, es) =
            scenario kitchen (kitchenFollowingLab <> [(400, MpdPlaying False), (1000, PeerProbed lab Nothing), (182000, Tick)])
      last es `shouldBe` [Act (AskRelease lab), Act EnableAlsa, StatusChanged]
      path st `shouldBe` Direct
    it "asks to be held again when a source that came back no longer lists it" $ do
      let (_, es) = scenario kitchen (kitchenFollowingLab <> [(1000, PeerProbed lab (Just (PeerView mempty Nothing)))])
      last es `shouldBe` [Act (AskHold lab)]
    it "follows its source to the room it moved to" $ do
      let (st, es) = scenario kitchen (kitchenFollowingLab <> [(1000, PeerProbed lab (Just (PeerView mempty (Just livingRoom))))])
      last es `shouldBe` [Act (AskHold livingRoom), StatusChanged]
      path st `shouldBe` PeerServer livingRoom
    it "is suspended in its source during AirPlay and held again after" $ do
      let (st, es) =
            scenario kitchen (kitchenFollowingLab <> [(1000, req 3 (ReqInterruptionStarts AirPlay)), (5000, req 4 (ReqInterruptionEnds AirPlay))])
      drop (length es - 2) es `shouldBe` [[Act (AskSuspend lab), ok 3, StatusChanged], [Act (AskHold lab), ok 4, StatusChanged]]
      path st `shouldBe` PeerServer lab
    it "abandons a follow still waiting on its source when AirPlay starts" $ do
      let (st, es) = scenario kitchen (take 2 kitchenFollowingLab <> [(50, MpdPlaying False), (100, req 3 (ReqInterruptionStarts AirPlay))])
      last es `shouldBe` [Act (AskSuspend lab), no 2 RoomInterrupted, Act (AskRelease lab), ok 3, StatusChanged]
      fmap resumeIntent (resumption <$> interruption st) `shouldBe` Just Own

  describe "a room alone" $ do
    it "pauses and resumes MPD around AirPlay, as nixtune does without multiroom" $ do
      let (st, es) =
            scenario kitchen [(0, MpdPlaying True), (10, req 1 (ReqInterruptionStarts AirPlay)), (20, MpdPlaying False), (5000, req 2 (ReqInterruptionEnds AirPlay))]
      es !! 1 `shouldBe` [PauseMpd, Act DisableAlsa, ok 1, StatusChanged]
      last es `shouldBe` [Act EnableAlsa, ResumeMpd, ok 2, StatusChanged]
      path st `shouldBe` Direct
    it "treats silence with nobody listening as own and paused" $ do
      let (st, es) = scenario kitchen [(0, MpdPlaying True), (10, req 1 ReqSilence)]
      last es `shouldBe` [PauseMpd, ok 1]
      intent st `shouldBe` Own
    it "refuses to follow itself, an undeclared room, or anything while interrupted" $ do
      let (_, es) =
            scenario kitchen [(0, req 1 (ReqFollow kitchen)), (1, req 2 (ReqFollow attic)), (2, req 3 (ReqInterruptionStarts Upnp)), (3, req 4 (ReqFollow lab))]
      map (filter isReply) es `shouldBe` [[no 1 IsSelf], [no 2 UnknownRoom], [ok 3], [no 4 RoomInterrupted]]

  describe "every random run" $ do
    it "never leaves a room silent with nobody listening" $
      everyStep $ \s ->
        let st = after' s
         in intent st /= Silent || streaming st || isJust (interruption st)
    it "never follows itself" $
      everyStep $ \s -> currentSource (after' s) =/= Just (self (after' s))
    it "keeps a pending follow and its intent in agreement" $
      everyStep $ \s -> case pendingFollow (after' s) of
        Nothing -> property True
        Just p -> intent (after' s) === Following (pendingTarget p)
    it "answers each request at most once" $
      property $
        forAll genRun $ \r ->
          let replies = [n | s <- runEvents r, Reply (ReplyTo n) _ <- effects s]
           in length replies === Map.size (Map.fromList [(n, ()) | n <- replies])
    it "answers a request in its own step unless it waits on a peer or a player" $
      everyStep $ \s -> case event s of
        Requested (ReplyTo n) rq ->
          let replied = [() | Reply (ReplyTo m) _ <- effects s, m == n]
              waiting = case rq of
                ReqFollow _ -> fmap pendingReply (pendingFollow (after' s)) == Just (ReplyTo n)
                ReqHold f -> case Map.lookup f (members (after' s)) of
                  Just (Joining _ (ReplyTo m)) -> m == n
                  _ -> False
                _ -> False
           in counterexample (show rq) (length replied + (if waiting then 1 else 0) === 1)
        _ -> property True
    it "aligns exactly the rooms in the group" $
      everyStep $ \s ->
        let st = after' s
            ms = focusMembers st
         in Map.keysSet (appliedDelays st) === (if streaming st then ms else mempty)
    it "puts a room back where it was after an interruption" $
      property $
        forAll genRun $ \r ->
          let steps = runEvents r
              st = if null steps then initialState (runRoom r) else after' (last steps)
              t = if null steps then Instant 0 else now' (last steps)
              (st1, _) = step testConfig t (req 9001 (ReqInterruptionStarts AirPlay)) st
              (st2, _) = step testConfig t (req 9002 (ReqInterruptionEnds AirPlay)) st1
           in not (isInterrupted st) && pendingFollow st == Nothing ==>
                (intent st2, members st2) === (intent st, members st)
  where
    isReply (Reply _ _) = True
    isReply _ = False
    isSuspended (Suspended _) = True
    isSuspended _ = False

everyStep :: Testable p => (Stepped -> p) -> Property
everyStep f = property $ forAll genRun $ \r -> conjoin [counterexample (show s) (f s) | s <- runEvents r]
