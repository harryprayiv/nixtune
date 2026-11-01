-- | Noise KKpsk2, the initiator's side, which in Sendspin is always the
-- server. Pure: the caller supplies the ephemeral key, so a handshake is
-- a function of its inputs and the tests compare it byte for byte with
-- the Python noiseprotocol library that aiosendspin uses.
--
-- > KKpsk2:
-- >   -> s
-- >   <- s
-- >   ...
-- >   -> e, es, ss
-- >   <- e, ee, se, psk
--
-- In a PSK handshake every "e" token also mixes the ephemeral into the
-- chaining key (Noise revision 34, section 9.2).
module Nixtune.Sendspin.Noise
  ( Suite (..)
  , suiteName
  , parseSuite
  , StaticKey
  , mkStaticKey
  , staticPublic
  , Ephemeral
  , mkEphemeral
  , generateEphemeral
  , PublicKey
  , mkPublicKey
  , AfterMessage1
  , writeMessage1
  , readMessage2
  , CipherState
  , Transport (..)
  , encrypt
  , decrypt
  )
where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.ChaChaPoly1305 qualified as ChaCha
import Crypto.Cipher.Types (AEADMode (AEAD_GCM), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (CryptoFailable (..), maybeCryptoError)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.MAC.HMAC (HMAC, hmac)
import Crypto.PubKey.Curve25519 qualified as X25519
import Data.Bits (shiftR)
import Data.ByteArray (constEq, convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Word (Word64, Word8)
import Nixtune.Sendspin.PskId (Psk, pskBytes)

data Suite = ChaChaPoly | AesGcm
  deriving stock (Eq, Show, Bounded, Enum)

-- | The suite as client/init names it.
suiteName :: Suite -> Text
suiteName = \case
  ChaChaPoly -> "25519_ChaChaPoly_SHA256"
  AesGcm -> "25519_AESGCM_SHA256"

parseSuite :: Text -> Maybe Suite
parseSuite t = lookup t [(suiteName s, s) | s <- [minBound .. maxBound]]

protocolName :: Suite -> ByteString
protocolName = \case
  ChaChaPoly -> "Noise_KKpsk2_25519_ChaChaPoly_SHA256"
  AesGcm -> "Noise_KKpsk2_25519_AESGCM_SHA256"

data StaticKey = StaticKey X25519.SecretKey X25519.PublicKey

mkStaticKey :: ByteString -> Maybe StaticKey
mkStaticKey raw = do
  sk <- maybeCryptoError (X25519.secretKey raw)
  pure (StaticKey sk (X25519.toPublic sk))

staticPublic :: StaticKey -> ByteString
staticPublic (StaticKey _ pk) = convert pk

newtype Ephemeral = Ephemeral X25519.SecretKey

mkEphemeral :: ByteString -> Maybe Ephemeral
mkEphemeral raw = Ephemeral <$> maybeCryptoError (X25519.secretKey raw)

generateEphemeral :: IO Ephemeral
generateEphemeral = Ephemeral <$> X25519.generateSecretKey

newtype PublicKey = PublicKey X25519.PublicKey

mkPublicKey :: ByteString -> Maybe PublicKey
mkPublicKey raw = PublicKey <$> maybeCryptoError (X25519.publicKey raw)

-- | A key and its counter. A counter that would reach 2^64 - 1 is never
-- used: the session is closed long before, at one message per 20 ms.
data CipherState = CipherState
  { csSuite :: Suite
  , csKey :: Maybe ByteString
  , csNonce :: Word64
  }

data Symmetric = Symmetric
  { cipher :: CipherState
  , ck :: ByteString
  , h :: ByteString
  }

sha256 :: ByteString -> ByteString
sha256 b = convert (hash b :: Digest SHA256)

hmacSha256 :: ByteString -> ByteString -> ByteString
hmacSha256 key msg = convert (hmac key msg :: HMAC SHA256)

-- | Noise's HKDF with two or three outputs.
hkdf :: ByteString -> ByteString -> (ByteString, ByteString, ByteString)
hkdf chaining ikm =
  let tk = hmacSha256 chaining ikm
      o1 = hmacSha256 tk (ByteString.singleton 1)
      o2 = hmacSha256 tk (o1 <> ByteString.singleton 2)
      o3 = hmacSha256 tk (o2 <> ByteString.singleton 3)
   in (o1, o2, o3)

initialize :: Suite -> ByteString -> Symmetric
initialize suite prologue =
  let name = protocolName suite
      h0
        | ByteString.length name <= 32 = name <> ByteString.replicate (32 - ByteString.length name) 0
        | otherwise = sha256 name
   in mixHash prologue (Symmetric (CipherState suite Nothing 0) h0 h0)

mixHash :: ByteString -> Symmetric -> Symmetric
mixHash d s = s {h = sha256 (h s <> d)}

mixKey :: ByteString -> Symmetric -> Symmetric
mixKey ikm s =
  let (ck', k, _) = hkdf (ck s) ikm
   in s {ck = ck', cipher = (cipher s) {csKey = Just k, csNonce = 0}}

mixKeyAndHash :: ByteString -> Symmetric -> Symmetric
mixKeyAndHash ikm s =
  let (ck', th, k) = hkdf (ck s) ikm
   in mixHash th s {ck = ck', cipher = (cipher s) {csKey = Just k, csNonce = 0}}

nonceBytes :: Suite -> Word64 -> ByteString
nonceBytes suite n = ByteString.replicate 4 0 <> ByteString.pack (order [fromIntegral (n `shiftR` (8 * i)) | i <- [0 .. 7]])
  where
    order :: [Word8] -> [Word8]
    order = case suite of
      ChaChaPoly -> id
      AesGcm -> reverse

aeadEncrypt :: Suite -> ByteString -> Word64 -> ByteString -> ByteString -> ByteString
aeadEncrypt suite key n ad plaintext = case suite of
  ChaChaPoly ->
    let st0 = throwCrypto (ChaCha.nonce12 (nonceBytes suite n) >>= ChaCha.initialize key)
        st1 = ChaCha.finalizeAAD (ChaCha.appendAAD ad st0)
        (ct, st2) = ChaCha.encrypt plaintext st1
     in ct <> convert (ChaCha.finalize st2)
  AesGcm ->
    let aes = throwCrypto (cipherInit key) :: AES256
        mode = throwCrypto (aeadInit AEAD_GCM aes (nonceBytes suite n))
        (AuthTag tag, ct) = aeadSimpleEncrypt mode ad plaintext 16
     in ct <> convert tag

aeadDecrypt :: Suite -> ByteString -> Word64 -> ByteString -> ByteString -> Maybe ByteString
aeadDecrypt suite key n ad sealed
  | ByteString.length sealed < 16 = Nothing
  | otherwise =
      let (ct, tag) = ByteString.splitAt (ByteString.length sealed - 16) sealed
       in case suite of
            ChaChaPoly -> do
              st0 <- maybeCryptoError (ChaCha.nonce12 (nonceBytes suite n) >>= ChaCha.initialize key)
              let st1 = ChaCha.finalizeAAD (ChaCha.appendAAD ad st0)
                  (pt, st2) = ChaCha.decrypt ct st1
              if constEq (convert (ChaCha.finalize st2) :: ByteString) tag then Just pt else Nothing
            AesGcm -> do
              aes <- maybeCryptoError (cipherInit key) :: Maybe AES256
              mode <- maybeCryptoError (aeadInit AEAD_GCM aes (nonceBytes suite n))
              aeadSimpleDecrypt mode ad ct (AuthTag (convert tag))

-- | Every input that can fail is checked before it gets here (key and
-- nonce lengths are fixed by construction), so a failure is a bug.
throwCrypto :: CryptoFailable a -> a
throwCrypto = \case
  CryptoPassed a -> a
  CryptoFailed e -> error ("Noise: " <> show e)

encryptAndHash :: ByteString -> Symmetric -> (ByteString, Symmetric)
encryptAndHash plaintext s = case csKey (cipher s) of
  Nothing -> (plaintext, mixHash plaintext s)
  Just k ->
    let c = cipher s
        sealed = aeadEncrypt (csSuite c) k (csNonce c) (h s) plaintext
     in (sealed, mixHash sealed s {cipher = c {csNonce = csNonce c + 1}})

decryptAndHash :: ByteString -> Symmetric -> Maybe (ByteString, Symmetric)
decryptAndHash sealed s = case csKey (cipher s) of
  Nothing -> Just (sealed, mixHash sealed s)
  Just k -> do
    let c = cipher s
    plaintext <- aeadDecrypt (csSuite c) k (csNonce c) (h s) sealed
    pure (plaintext, mixHash sealed s {cipher = c {csNonce = csNonce c + 1}})

dh :: X25519.SecretKey -> X25519.PublicKey -> ByteString
dh sk pk = convert (X25519.dh pk sk)

-- | What the initiator keeps between its message and the responder's.
-- Pure, so message 2 can be checked under a second PSK by reading it
-- again from the same state.
data AfterMessage1 = AfterMessage1
  { amSymmetric :: Symmetric
  , amEphemeral :: X25519.SecretKey
  , amStatic :: X25519.SecretKey
  }

-- | Noise message 1 and the state to read message 2 with.
writeMessage1 ::
  Suite -> StaticKey -> PublicKey -> ByteString -> Ephemeral -> ByteString -> (ByteString, AfterMessage1)
writeMessage1 suite (StaticKey s spub) (PublicKey rs) prologue (Ephemeral e) payload =
  let epub = convert (X25519.toPublic e) :: ByteString
      s0 = mixHash (convert rs) (mixHash (convert spub) (initialize suite prologue))
      s1 = mixKey epub (mixHash epub s0)
      s2 = mixKey (dh s rs) (mixKey (dh e rs) s1)
      (sealed, s3) = encryptAndHash payload s2
   in (epub <> sealed, AfterMessage1 s3 e s)

data Transport = Transport
  { sending :: CipherState
  , receiving :: CipherState
  }

-- | Read Noise message 2 with the PSK message 1 referred to; the
-- responder's payload and the transport keys, or Nothing when the
-- message does not authenticate under that PSK.
readMessage2 :: AfterMessage1 -> Psk -> ByteString -> Maybe (ByteString, Transport)
readMessage2 am psk msg
  | ByteString.length msg < 32 = Nothing
  | otherwise = do
      let (rePub, rest) = ByteString.splitAt 32 msg
      re <- maybeCryptoError (X25519.publicKey rePub)
      let s1 = mixKey rePub (mixHash rePub (amSymmetric am))
          s2 = mixKeyAndHash (pskBytes psk) (mixKey (dh (amStatic am) re) (mixKey (dh (amEphemeral am) re) s1))
      (payload, s3) <- decryptAndHash rest s2
      let (k1, k2, _) = hkdf (ck s3) ByteString.empty
          suite = csSuite (cipher s3)
      pure (payload, Transport (CipherState suite (Just k1) 0) (CipherState suite (Just k2) 0))

-- | A transport message: no associated data, the counter as nonce.
encrypt :: CipherState -> ByteString -> (ByteString, CipherState)
encrypt c plaintext = case csKey c of
  Nothing -> (plaintext, c)
  Just k -> (aeadEncrypt (csSuite c) k (csNonce c) ByteString.empty plaintext, c {csNonce = csNonce c + 1})

decrypt :: CipherState -> ByteString -> Maybe (ByteString, CipherState)
decrypt c sealed = case csKey c of
  Nothing -> Just (sealed, c)
  Just k -> do
    plaintext <- aeadDecrypt (csSuite c) k (csNonce c) ByteString.empty sealed
    pure (plaintext, c {csNonce = csNonce c + 1})

