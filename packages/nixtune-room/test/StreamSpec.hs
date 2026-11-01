-- | The server's pure parts: packing MPD's samples, timestamps, the
-- group's send-ahead, buffer accounting, the format a player gets, and
-- the wire framing.
module StreamSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Maybe (fromJust, isJust, isNothing)
import Nixtune.Sendspin.Audio
import Nixtune.Sendspin.Message
import Test.Hspec
import Test.QuickCheck

cd24 :: StreamFormat
cd24 = StreamFormat 44100 24 2

pcm :: Int -> PcmFormat
pcm = PcmFormat 44100 `flip` 2

spec :: Spec
spec = do
  describe "packing" $ do
    it "packs 24 bits in 32-bit containers into 3 bytes, little-endian" $
      pack cd24 (pcm 24) (ByteString.pack [1, 2, 3, 0, 4, 5, 6, 0xff])
        `shouldBe` ByteString.pack [1, 2, 3, 4, 5, 6]
    it "keeps the top 16 bits for a player that takes only 16" $
      pack cd24 (pcm 16) (ByteString.pack [1, 2, 3, 0, 4, 5, 6, 0xff])
        `shouldBe` ByteString.pack [2, 3, 5, 6]
    it "makes three bytes of every four" $
      property $ \(Positive frames) ->
        let raw = ByteString.replicate (frames * inputFrameBytes cd24) 7
         in ByteString.length (pack cd24 (pcm 24) raw) === frames * 6
  describe "format" $ do
    let fmt c b = SupportedFormat c (PcmFormat 44100 b 2)
    it "takes the player's PCM entry at the stream's depth" $
      choosePcm cd24 [fmt "flac" 24, fmt "pcm" 16, fmt "pcm" 24] `shouldBe` Just (pcm 24)
    it "falls back to 16-bit PCM" $
      choosePcm cd24 [fmt "flac" 24, fmt "pcm" 16] `shouldBe` Just (pcm 16)
    it "refuses a player without PCM at the stream's rate" $
      choosePcm cd24 [fmt "flac" 24, SupportedFormat "pcm" (PcmFormat 48000 24 2)] `shouldBe` Nothing
    it "reads the module's stream format" $ do
      parseStreamFormat "44100:24:2" `shouldBe` Right cd24
      parseStreamFormat "96000:24:2" `shouldSatisfy` either (const True) (const False)
  describe "timeline" $ do
    it "starts the stream one send-ahead from now" $
      fst (stamp 44100 300000 1000000 882 Nothing) `shouldBe` 1300000
    it "stamps each chunk where the last one ended" $ do
      let (_, t1) = stamp 44100 300000 1000000 882 Nothing
          (ts2, _) = stamp 44100 300000 1020000 882 (Just t1)
      ts2 `shouldBe` 1300000 + framesDuration 44100 882
    it "never drifts from the sample count" $
      property $ \(Positive k) ->
        let go 0 t = t
            go n t = go (n - 1 :: Int) (snd (stamp 44100 300000 (-300000) 882 (Just t)))
         in timelineEnd 44100 (go k (Timeline 0 0)) === framesDuration 44100 (fromIntegral k * 882)
    it "restarts later, never earlier, after MPD stopped writing" $ do
      let (_, t1) = stamp 44100 300000 1000000 882 Nothing
          (ts, _) = stamp 44100 300000 9000000 882 (Just t1)
      ts `shouldBe` 9300000
    it "gives every player at least its buffer plus its output delay" $ do
      sendAhead [(250, 0), (100, 400)] `shouldBe` 500000
      sendAhead [] `shouldBe` minimumSendAhead
  describe "buffer accounting" $ do
    let one = fromJust (admit 100 0 60 1000 noOutstanding)
    it "refuses a chunk that would exceed the capacity" $
      isNothing (admit 100 500 60 2000 one) `shouldBe` True
    it "frees what has finished playing" $
      isJust (admit 100 1000 60 2000 one) `shouldBe` True
  describe "framing" $ do
    it "lays out an audio chunk as the player role defines it" $
      audioFrame 0x0102030405060708 0x0a0b0c0d (Char8.pack "pcm")
        `shouldBe` ByteString.pack ([4, 1, 2, 3, 4, 5, 6, 7, 8, 0x0a, 0x0b, 0x0c, 0x0d] <> map (fromIntegral . fromEnum) "pcm")
    it "saturates send_ahead at both ends" $ do
      sendAheadField 100 200 `shouldBe` 0
      sendAheadField (10 ^ (12 :: Int)) 0 `shouldBe` maxBound
      sendAheadField 300 100 `shouldBe` 200
    it "reassembles fragments into the original message" $ do
      let (s1, a) = reassemble noFragments (ByteString.pack [1, 2, 0, 0x7b])
          (s2, b) = reassemble s1 (ByteString.pack [1, 0, 0x7d])
          (_, c) = reassemble s2 (ByteString.pack [1, 1, 0x21])
      (a, b, c) `shouldBe` (Partial, Partial, Complete 0 (Char8.pack "{}!"))
    it "refuses a message while a fragment is in flight" $ do
      let (s1, _) = reassemble noFragments (ByteString.pack [1, 2, 0, 0x7b])
      snd (reassemble s1 (ByteString.pack [0, 0x7b])) `shouldSatisfy` isError
    it "refuses an empty message and reserved flag bits" $ do
      snd (reassemble noFragments ByteString.empty) `shouldSatisfy` isError
      snd (reassemble noFragments (ByteString.pack [1, 4, 0])) `shouldSatisfy` isError
  describe "client/init" $ do
    it "reads a version 1 init" $
      parseClientInit (Char8.pack "{\"type\":\"client/init\",\"payload\":{\"client_id\":\"abc\",\"version\":1,\"suite\":\"25519_ChaChaPoly_SHA256\"}}")
        `shouldBe` Right (ClientInit "abc" "25519_ChaChaPoly_SHA256")
    it "refuses another version before looking at the rest" $
      parseClientInit (Char8.pack "{\"type\":\"client/init\",\"payload\":{\"version\":2}}") `shouldBe` Left UnsupportedVersion
    it "calls anything else malformed" $
      parseClientInit (Char8.pack "not json") `shouldBe` Left Malformed
  where
    isError = \case
      ProtocolError _ -> True
      _ -> False
