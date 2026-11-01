-- | Keys for a home: a Curve25519 identity for every room's server and
-- every room's player, and a 32-byte PSK for every ordered pair (server
-- room, player room), a room's own server and own player included,
-- because a source plays to its own speaker through its own server.
--
-- Public keys are base64url, unpadded, as Sendspin's server_id and
-- client_id are. They go in the Nix declaration. Private keys and PSKs go
-- in one YAML file per room, to be merged into that host's sops file.
module Nixtune.Room.Keys
  ( Identity (..)
  , generateIdentity
  , publicKeyOf
  , generatePsk
  , HomeKeys (..)
  , generateHome
  , roomSecretsYaml
  , publicKeysNix
  , decodeBase64Url
  )
where

import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Curve25519 qualified as X25519
import Crypto.Random (getRandomBytes)
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Nixtune.Room.Name (RoomName, roomNameText)
import Nixtune.Sendspin.PskId (Psk, base64Url, mkPsk, pskBytes)

data Identity = Identity
  { identitySecret :: ByteString
  , identityPublic :: ByteString
  }

generateIdentity :: IO Identity
generateIdentity = do
  sk <- X25519.generateSecretKey
  pure (Identity (convert sk) (convert (X25519.toPublic sk)))

-- | The public key of a raw 32-byte private key.
publicKeyOf :: ByteString -> Either String ByteString
publicKeyOf raw = case X25519.secretKey raw of
  CryptoPassed sk -> Right (convert (X25519.toPublic sk))
  CryptoFailed e -> Left (show e)

generatePsk :: IO Psk
generatePsk = do
  b <- getRandomBytes 32
  maybe (fail "random source returned the wrong length") pure (mkPsk b)

decodeBase64Url :: Text -> Either String ByteString
decodeBase64Url t = convertFromBase Base64URLUnpadded (encodeUtf8 (Text.strip t))

data HomeKeys = HomeKeys
  { servers :: Map RoomName Identity
  , players :: Map RoomName Identity
  , psks :: Map (RoomName, RoomName) Psk
  -- ^ (server room, player room)
  }

generateHome :: [RoomName] -> IO HomeKeys
generateHome rooms = do
  ss <- Map.fromList <$> traverse (\r -> (r,) <$> generateIdentity) rooms
  ps <- Map.fromList <$> traverse (\r -> (r,) <$> generateIdentity) rooms
  ks <- Map.fromList <$> traverse (\pr -> (pr,) <$> generatePsk) [(s, p) | s <- rooms, p <- rooms]
  pure (HomeKeys ss ps ks)

-- | One room's secrets, for its host's sops file. The keys are the paths
-- the NixOS module declares as sops.secrets:
-- nixtune-room/server-key, nixtune-room/player-key,
-- nixtune-room/server-psk/<player room>, nixtune-room/player-psk/<server room>.
roomSecretsYaml :: HomeKeys -> RoomName -> Text
roomSecretsYaml hk r =
  Text.unlines $
    [ "nixtune-room:"
    , "  server-key: " <> q (b64 (identitySecret <$> Map.lookup r (servers hk)))
    , "  player-key: " <> q (b64 (identitySecret <$> Map.lookup r (players hk)))
    , "  server-psk:"
    ]
      <> [ "    " <> roomNameText p <> ": " <> q (base64Url (pskBytes k))
         | ((s, p), k) <- Map.toAscList (psks hk)
         , s == r
         ]
      <> ["  player-psk:"]
      <> [ "    " <> roomNameText s <> ": " <> q (base64Url (pskBytes k))
         | ((s, p), k) <- Map.toAscList (psks hk)
         , p == r
         ]
  where
    b64 = maybe "" base64Url
    q t = "\"" <> t <> "\""

-- | The public half, for multiroom.peers.<room>.serverKey and playerKey.
publicKeysNix :: HomeKeys -> Text
publicKeysNix hk =
  Text.unlines $
    ["{"]
      <> [ "  " <> quoteIfNeeded (roomNameText r) <> " = { serverKey = \"" <> pub servers r <> "\"; playerKey = \"" <> pub players r <> "\"; };"
         | r <- Map.keys (servers hk)
         ]
      <> ["}"]
  where
    pub field r = maybe "" (base64Url . identityPublic) (Map.lookup r (field hk))
    -- A Nix attribute name with a hyphen is fine unquoted; quote anything
    -- else that is not a plain identifier.
    quoteIfNeeded n = if Text.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') n then n else "\"" <> n <> "\""