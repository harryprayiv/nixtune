module FocusSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Generators
import Nixtune.Room.Clock (Millis (..))
import Nixtune.Room.Coordinator (Config (..))
import Nixtune.Room.Focus
import Nixtune.Room.Name (RoomName)
import Test.Hspec
import Test.QuickCheck

delaysFor :: RoomName -> [RoomName] -> Map.Map RoomName Millis
delaysFor f ms = alignedDelays (peers testConfig) (acoustics testConfig) f (Set.fromList ms)

spec :: Spec
spec = describe "acoustic alignment" $ do
  it "gives the farthest room no added delay and the focus room the most" $
    -- From the kitchen: kitchen 1 ms, lab 9 ms, living room 14 ms; living
    -- room also has outputDelay 2.
    delaysFor kitchen [kitchen, lab, livingRoom]
      `shouldBe` Map.fromList [(kitchen, Millis 13), (lab, Millis 5), (livingRoom, Millis 2)]
  it "treats a room with no declared travel as if it were the focus" $
    -- From the lab, the living room is not declared: it plays like the lab.
    delaysFor lab [lab, livingRoom]
      `shouldBe` Map.fromList [(lab, Millis 0), (livingRoom, Millis 2)]
  it "never sends a negative delay, and the focus waits at least as long as anyone" $
    property $
      forAll (elements home) $ \f ->
        forAll (sublistOf home) $ \others ->
          let ms = f : filter (/= f) others
              ds = delaysFor f ms
              added r = let Millis d = ds Map.! r; Millis b = peers testConfig Map.! r in d - b
           in conjoin
                [ all (\(Millis d) -> d >= 0 && d <= 5000) (Map.elems ds) === True
                , conjoin [counterexample (show r) (added f >= added r) | r <- ms]
                ]
  it "picks the pinned room only when it is a member" $ do
    chooseFocus kitchen (Just lab) (Set.fromList [kitchen, lab]) `shouldBe` Just lab
    chooseFocus kitchen (Just lab) (Set.fromList [kitchen, livingRoom]) `shouldBe` Just kitchen
    chooseFocus kitchen Nothing (Set.fromList [lab, livingRoom]) `shouldBe` Just lab
