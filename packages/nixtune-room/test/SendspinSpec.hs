module SendspinSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.Int (Int64)
import Nixtune.Sendspin.PskId
import Nixtune.Sendspin.TimeFilter
import Numeric (showHex)
import Test.Hspec
import Test.QuickCheck

hex :: ByteString.ByteString -> String
hex = concatMap (\w -> let s = showHex w "" in if length s == 1 then '0' : s else s) . ByteString.unpack

-- | An exchange against a server whose clock is the client's plus the
-- given offset, with the given one-way delay each way and server
-- processing time.
exchangeAt :: Int64 -> Int64 -> Int64 -> Int64 -> Exchange
exchangeAt off t1 oneWay processing =
  Exchange
    { clientTransmitted = t1
    , serverReceived = t1 + oneWay + off
    , serverTransmitted = t1 + oneWay + processing + off
    , clientReceived = t1 + 2 * oneWay + processing
    }

spec :: Spec
spec = do
  describe "psk_id" $ do
    it "derives the spec's Sentinel PSK" $
      hex (pskBytes sentinelPsk)
        `shouldBe` "1b5e24dbc1aed95fc2a5a338a90c05df44bd10f5ec1f4cd66cbf86272767b9d3"
    it "derives the spec's Sentinel psk_id" $
      pskId sentinelPsk `shouldBe` "GFsV9tLaSQm9HcFWpKsgYQOr7wFTvNUtkmFwuVz3zoo"
    it "accepts only 32-byte keys" $ do
      mkPsk (ByteString.replicate 31 0) `shouldBe` Nothing
      fmap pskBytes (mkPsk (ByteString.replicate 32 7)) `shouldBe` Just (ByteString.replicate 32 7)

  describe "time filter" $ do
    it "measures offset and max error as the spec defines them" $
      measure (Exchange 1000 501000 501010 1100) `shouldBe` (499955, 45, 1100)
    it "rounds halves away from zero" $
      map roundHalfAway [2.5, -2.5, 2.4, -2.4, 0.5, -0.5] `shouldBe` [3, -3, 2, -2, 1, -1]
    it "discards an exchange that is not newer, or has no positive max error" $ do
      let f1 = update defaultParams (exchangeAt 5000 1000000 20 5) emptyFilter
      update defaultParams (exchangeAt 5000 999000 20 5) f1 `shouldBe` f1
      update defaultParams (Exchange 2000000 2005000 2005000 2000000) f1 `shouldBe` f1
    it "takes the first measurement as the offset" $ do
      let f = update defaultParams (exchangeAt 5000 1000000 20 5) emptyFilter
      (offset f, count f) `shouldBe` (5000, 1)
    it "converges on a fixed offset through jittery exchanges" $
      property $
        forAll (vectorOf 300 (chooseInt (5, 400))) $ \delays ->
          let exs = zipWith (\i d -> exchangeAt 123456 (1000000 + i * 250000) (fromIntegral d) 3) [0 ..] delays
              f = foldl (flip (update defaultParams)) emptyFilter exs
           in counterexample (show f) (abs (offset f - 123456) < 5)
    it "converts server time to client time and back" $
      property $
        forAll (chooseInt (0, 1000000000)) $ \t ->
          let exs = [exchangeAt 777 (1000000 + i * 250000) 50 3 | i <- [0 .. 50]]
              f = foldl (flip (update defaultParams)) emptyFilter exs
              tc = fromIntegral t
           in abs (computeClientTime f (computeServerTime f tc) - tc) <= 1
