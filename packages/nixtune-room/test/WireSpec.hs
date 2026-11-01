module WireSpec (spec) where

import Data.Set qualified as Set
import Generators
import Nixtune.Room.Protocol
import Nixtune.Room.Wire
import Test.Hspec
import Test.QuickCheck

genStatus :: Gen WireStatus
genStatus =
  WireStatus
    <$> elements home
    <*> elements ["own", "following", "silent"]
    <*> maybeRoom
    <*> (Set.fromList <$> sublistOf home)
    <*> (Set.fromList <$> sublistOf home)
    <*> maybeRoom
    <*> elements ["direct", "own-server", "peer-server", "off", "interrupted"]
    <*> oneof [pure Nothing, Just <$> arbitraryBoundedEnum]
    <*> maybeRoom
  where
    maybeRoom = oneof [pure Nothing, Just <$> elements home]

genReq :: Gen Request
genReq =
  oneof
    [ ReqFollow <$> elements home
    , pure ReqOwn
    , pure ReqSilence
    , ReqHold <$> elements home
    , ReqRelease <$> elements home
    , ReqSuspend <$> elements home
    , ReqPin <$> elements home
    , pure ReqUnpin
    , ReqInterruptionStarts <$> arbitraryBoundedEnum
    , ReqInterruptionEnds <$> arbitraryBoundedEnum
    ]

spec :: Spec
spec = describe "line protocol" $ do
  it "reads back every request it writes" $
    forAll genReq $ \r -> parseCommand (renderRequest r) === Right (CmdRequest r)
  it "reads back every reply it writes" $
    forAll (oneof [pure (Right ()), Left <$> arbitraryBoundedEnum]) $ \x ->
      parseReply (renderReply x) === Right (x :: Either Refusal ())
  it "reads back every status it writes" $
    forAll genStatus $ \s -> parseStatus (renderStatus s) === Right s
  it "rejects what is not a command" $ do
    parseCommand "follow" `shouldSatisfy` either (const True) (const False)
    parseCommand "follow Lab" `shouldSatisfy` either (const True) (const False)
    parseCommand "interruption-starts bluetooth" `shouldSatisfy` either (const True) (const False)
    parseCommand "rm -rf /" `shouldSatisfy` either (const True) (const False)
  it "writes the status line the spec shows" $
    renderStatus (WireStatus lab "own" Nothing (Set.fromList [kitchen]) mempty Nothing "own-server" Nothing (Just lab))
      `shouldBe` "status room=lab intent=own source=- audience=kitchen suspended=- moved-to=- path=own-server interrupted-by=- focus=lab"