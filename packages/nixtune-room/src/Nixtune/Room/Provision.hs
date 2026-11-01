-- | PlayerCredentialsProvisioned: before every start of the room's
-- sendspin-cli player, write its identity and its pairing records from the
-- sops secrets, in the files and formats sendspin-cli reads today:
--
-- > identity-daemon.json      {"private_key": <base64url>}
-- > pairing-store-daemon.json {"records": {<psk_id>: {...}}, ...}
--
-- These are sendspin-cli's and aiosendspin's implementation files, not a
-- documented interface (KnownIssue player_store_is_private_format). The
-- declaration is the whole truth: records not declared do not survive.
-- The one thing kept from the old store is last_playback_server_id, which
-- the player uses to choose between servers, and only if it names a
-- declared server.
module Nixtune.Room.Provision
  ( provisionPlayer
  , storeJson
  , fixedTimestamp
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Nixtune.Room.Config (PeerConfig (..), RoomConfig (..), Secrets (..))
import Nixtune.Room.Keys (decodeBase64Url, publicKeyOf)
import Nixtune.Room.Name (roomNameText)
import Nixtune.Sendspin.PskId (Psk, base64Url, mkPsk, pskBytes, pskId)
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)

-- | Records carry a creation time, which aiosendspin uses only to pick
-- which record to evict when the store is full. nixtune's never is: the
-- store holds at most the declared servers.
fixedTimestamp :: Text
fixedTimestamp = "2026-01-01T00:00:00+00:00"

readSecret :: FilePath -> IO (Either String Text)
readSecret path = do
  r <- try (ByteString.readFile path)
  pure $ case r of
    Left e -> Left (path <> ": " <> show (e :: IOException))
    Right b -> Right (Text.strip (decodeUtf8Lenient b))

-- | The store's JSON, given (server_id, psk) pairs and the player's last
-- playback server.
storeJson :: [(Text, Psk)] -> Maybe Text -> Value
storeJson records lastServer =
  object
    [ "records"
        .= object
          [ Key.fromText (pskId k)
              .= object
                [ "psk_id" .= pskId k
                , "psk" .= base64Url (pskBytes k)
                , "server_id" .= serverId
                , "used" .= False
                , "created_at" .= fixedTimestamp
                , "last_used_at" .= fixedTimestamp
                ]
          | (serverId, k) <- records
          ]
    , "pairing_config"
        .= object
          [ "dynamic_pin_enabled" .= False
          , "static_pin_enabled" .= False
          , "unpaired_access_enabled" .= False
          ]
    , "pairing_psk" .= Null
    , "static_pin" .= Null
    , "pin_failures" .= (0 :: Int)
    , "last_playback_server_id" .= lastServer
    ]

writePrivate :: FilePath -> Lazy.ByteString -> IO ()
writePrivate path bytes = do
  let tmp = path <> ".tmp"
  -- Owner-only before any secret is written to it.
  Lazy.writeFile tmp mempty
  setFileMode tmp (ownerReadMode `unionFileModes` ownerWriteMode)
  Lazy.writeFile tmp bytes
  renameFile tmp path

provisionPlayer :: RoomConfig -> FilePath -> IO (Either String ())
provisionPlayer cfg stateDir = do
  let me = room cfg
      sec = secrets cfg
  keyText <- readSecret (playerKeyFile sec)
  pskTexts <- traverse readSecret (playerPskFiles sec)
  oldStore <- try (Lazy.readFile (stateDir </> "pairing-store-daemon.json"))
  let declaredServers = Map.map peerServerKey (peerConfigs cfg)
      lastServer = case oldStore of
        Left (_ :: IOException) -> Nothing
        Right bytes -> case Aeson.decode bytes of
          Just (Object o) | Just (String s) <- KeyMap.lookup "last_playback_server_id" o, s `elem` Map.elems declaredServers -> Just s
          _ -> Nothing
      built = do
        key <- keyText >>= decodeBase64Url
        pub <- publicKeyOf key
        mine <- maybe (Left "peers does not include this room") Right (Map.lookup me (peerConfigs cfg))
        when (base64Url pub /= peerPlayerKey mine) $
          Left "the provisioned player key does not match peers.<room>.playerKey"
        records <-
          traverse
            ( \(serverRoom, serverKey) -> do
                t <- maybe (Left ("no player PSK for server " <> Text.unpack (roomNameText serverRoom))) id (Map.lookup serverRoom pskTexts)
                raw <- decodeBase64Url t
                k <- maybe (Left ("PSK for server " <> Text.unpack (roomNameText serverRoom) <> " is not 32 bytes")) Right (mkPsk raw)
                pure (serverKey, k)
            )
            (Map.toList declaredServers)
        when (length records > 16) $
          Left "more than 16 servers: aiosendspin's store would evict records"
        pure (key, records)
  case built of
    Left e -> pure (Left e)
    Right (key, records) -> do
      createDirectoryIfMissing True stateDir
      writePrivate (stateDir </> "identity-daemon.json") (Aeson.encode (object ["private_key" .= base64Url key]))
      writePrivate (stateDir </> "pairing-store-daemon.json") (Aeson.encode (storeJson records lastServer))
      pure (Right ())