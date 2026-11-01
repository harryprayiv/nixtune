-- | Keys, and the player's provisioned credentials.
module KeysSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Generators
import Nixtune.Room.Clock (Millis (..))
import Nixtune.Room.Config
import Nixtune.Room.Keys
import Nixtune.Room.Name (RoomName, roomNameText)
import Nixtune.Room.Provision (provisionPlayer)
import Nixtune.Sendspin.Audio (StreamFormat (..))
import Nixtune.Sendspin.PskId (base64Url, pskBytes, pskId)
import System.FilePath ((</>))
import TempDir (withTempDir)
import Test.Hspec

lineValue :: Text -> Text -> Text -> Maybe Text
lineValue section key yaml = go False (Text.lines yaml)
  where
    go _ [] = Nothing
    go inSection (l : ls)
      | Text.strip l == section <> ":" = go True ls
      | inSection, Just v <- Text.stripPrefix ("    " <> key <> ": \"") l = Just (Text.dropEnd 1 v)
      | not (Text.isPrefixOf "    " l) && Text.isSuffixOf ":" (Text.strip l) = go False ls
      | otherwise = go inSection ls

-- | Writes kitchen's secrets as sops-nix would (one file per value) and a
-- room.json pointing at them.
kitchenConfig :: HomeKeys -> FilePath -> IO RoomConfig
kitchenConfig hk dir = do
  let write name v = TextIO.writeFile (dir </> name) v >> pure (dir </> name)
      secret field r = maybe "" (base64Url . identitySecret) (Map.lookup r (field hk))
      public field r = maybe "" (base64Url . identityPublic) (Map.lookup r (field hk))
  playerKey <- write "player-key" (secret players kitchen)
  serverKey <- write "server-key" (secret servers kitchen)
  playerPsks <-
    Map.fromList
      <$> traverse
        (\s -> (s,) <$> write ("player-psk-" <> Text.unpack (roomNameText s)) (maybe "" (base64Url . pskBytes) (Map.lookup (s, kitchen) (psks hk))))
        home
  let peer r = PeerConfig "127.0.0.1" 80 "/room" (Millis 0) (public servers r) (public players r)
  pure
    RoomConfig
      { room = kitchen
      , peerConfigs = Map.fromList [(r, peer r) | r <- home]
      , acousticsMs = Map.empty
      , timing = Timing 10000 180000 10000 1800000 2000 15000
      , listen = Listen "127.0.0.1" 0 (dir </> "control.sock")
      , mpd = MpdConfig "127.0.0.1" 6600 "dac" "multiroom"
      , secrets = Secrets serverKey playerKey Map.empty playerPsks
      , sendspin = SendspinConfig 8928 "/sendspin" (dir </> "fifo") (StreamFormat 44100 24 2)
      }

serverIdsIn :: Value -> [Text]
serverIdsIn (Object o)
  | Just (Object rs) <- KeyMap.lookup "records" o =
      [s | Object r <- KeyMap.elems rs, Just (String s) <- [KeyMap.lookup "server_id" r]]
serverIdsIn _ = []

spec :: Spec
spec = describe "keys" $ do
  it "derives each public key from its private key" $ do
    hk <- generateHome home
    mapM_ (\i -> publicKeyOf (identitySecret i) `shouldBe` Right (identityPublic i)) (Map.elems (servers hk) <> Map.elems (players hk))
  it "gives both rooms of a pair the same PSK, under each side's name" $ do
    hk <- generateHome home
    let ofRoom :: RoomName -> Text
        ofRoom = roomSecretsYaml hk
    lineValue "server-psk" "kitchen" (ofRoom lab) `shouldBe` lineValue "player-psk" "lab" (ofRoom kitchen)
    lineValue "server-psk" "lab" (ofRoom lab) `shouldBe` lineValue "player-psk" "lab" (ofRoom lab)
    lineValue "server-psk" "kitchen" (ofRoom lab) `shouldNotBe` lineValue "server-psk" "lab" (ofRoom lab)
  it "provisions the player with a record for every declared server, keyed by psk_id" $
    withTempDir "nixtune-room" $ \dir -> do
      hk <- generateHome home
      cfg <- kitchenConfig hk dir
      provisionPlayer cfg (dir </> "state") `shouldReturn` Right ()
      store <- Aeson.decode <$> Lazy.readFile (dir </> "state" </> "pairing-store-daemon.json")
      let ids = maybe [] serverIdsIn store
      ids `shouldMatchList` map (\r -> maybe "" (base64Url . identityPublic) (Map.lookup r (servers hk))) home
      case store of
        Just (Object o)
          | Just (Object rs) <- KeyMap.lookup "records" o ->
              map Key.toText (KeyMap.keys rs)
                `shouldMatchList` [pskId k | ((_, p), k) <- Map.toList (psks hk), p == kitchen]
        _ -> expectationFailure "store has no records"
  it "refuses a player key that does not match the declaration" $
    withTempDir "nixtune-room" $ \dir -> do
      hk <- generateHome home
      cfg <- kitchenConfig hk dir
      TextIO.writeFile (playerKeyFile (secrets cfg)) (maybe "" (base64Url . identitySecret) (Map.lookup lab (players hk)))
      provisionPlayer cfg (dir </> "state")
        `shouldReturn` Left "the provisioned player key does not match peers.<room>.playerKey"