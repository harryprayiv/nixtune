module SyncSpec (spec) where

import Control.Exception (throwIO)
import Nixtune.Room.Sync qualified as Sync
import Test.Hspec

spec :: Spec
spec = describe "failures" $
  it "describes one by its own text, without the backtrace GHC 9.10 attaches" $ do
    r <- Sync.trySync (throwIO (userError "boom") :: IO ())
    case r of
      Left e -> Sync.describe e `shouldBe` "user error (boom)"
      Right () -> expectationFailure "nothing was thrown"