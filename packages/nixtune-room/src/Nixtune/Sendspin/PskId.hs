-- | psk_id, as the Sendspin spec's "Pre-Shared Key" section defines it:
--
-- > psk_id = base64url(SHA-256("sendspin-psk-id-v1" || PSK))
--
-- with no padding. Every long-term PSK provisioned from sops is looked up
-- by this identifier during the Noise handshake, on both sides.
module Nixtune.Sendspin.PskId
  ( Psk
  , mkPsk
  , pskBytes
  , pskId
  , sentinelPsk
  , base64Url
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)

-- | A 32-byte pre-shared key.
newtype Psk = Psk ByteString
  deriving stock (Eq)

-- | Never shows the key.
instance Show Psk where
  show _ = "Psk <32 bytes>"

mkPsk :: ByteString -> Maybe Psk
mkPsk b
  | ByteString.length b == 32 = Just (Psk b)
  | otherwise = Nothing

pskBytes :: Psk -> ByteString
pskBytes (Psk b) = b

sha256 :: ByteString -> ByteString
sha256 b = convert (hash b :: Digest SHA256)

base64Url :: ByteString -> Text
base64Url = decodeUtf8 . convertToBase Base64URLUnpadded

pskId :: Psk -> Text
pskId (Psk b) = base64Url (sha256 (Char8.pack "sendspin-psk-id-v1" <> b))

-- | SHA-256("sendspin-sentinel-psk-v1"), the published constant used when
-- no other PSK applies. nixtune never plays on a Sentinel-keyed session;
-- it is here to recognise one, and as the spec's test vector.
sentinelPsk :: Psk
sentinelPsk = Psk (sha256 (Char8.pack "sendspin-sentinel-psk-v1"))
