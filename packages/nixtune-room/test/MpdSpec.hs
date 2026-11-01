module MpdSpec (spec) where

import Data.Maybe (mapMaybe)
import FakeMpd
import Nixtune.Mpd.Client qualified as Client
import Nixtune.Mpd.Protocol
import Test.Hspec

spec :: Spec
spec = describe "MPD protocol" $ do
  it "splits a response line at the first colon and space" $ do
    pair "file: a: b.flac" `shouldBe` Just ("file", "a: b.flac")
    pair "OK" `shouldBe` Nothing
  it "reads the player state" $ do
    playState [("volume", "50"), ("state", "play")] `shouldBe` Just Playing
    playState [("state", "pause")] `shouldBe` Just Paused
    playState [("state", "stop")] `shouldBe` Just Stopped
  it "reads the outputs MPD 0.24 lists" $ do
    let kv =
          mapMaybe
            pair
            [ "outputid: 0"
            , "outputname: sndrpihifiberry"
            , "plugin: alsa"
            , "outputenabled: 1"
            , "outputid: 1"
            , "outputname: multiroom"
            , "plugin: fifo"
            , "outputenabled: 0"
            , "attribute: path=/run/nixtune-room/fifo"
            ]
    parseOutputs kv `shouldBe` [Output 0 "sndrpihifiberry" True, Output 1 "multiroom" False]
    fmap outputId (outputNamed "multiroom" (parseOutputs kv)) `shouldBe` Just 1
  it "sends a command again on a new connection after MPD closes the old one" $ do
    f <- startFakeMpd True
    c <- Client.connect "127.0.0.1" (fakePort f)
    Client.command c "status" `shouldReturn` Done [("state", "play")]
    dropClients f
    Client.command c "pause 1" `shouldReturn` Done []
    mpdLog f `shouldReturn` ["pause 1"]
    Client.close c