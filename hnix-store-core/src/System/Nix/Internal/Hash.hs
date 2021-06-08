{-|
Description : Cryptographic hashing interface for hnix-store, on top
              of the cryptohash family of libraries.
-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE CPP #-}

module System.Nix.Internal.Hash
  ( HashAlgorithm(..)
  , ValidAlgo(..)
  , NamedAlgo(..)
  , hash
  , hashLazy
  , Digest
  , SomeNamedDigest(..)
  , mkNamedDigest
  , encodeDigestWith
  , decodeDigestWith
  , mkStorePathHash
  )
where

import qualified Crypto.Hash.MD5        as MD5
import qualified Crypto.Hash.SHA1       as SHA1
import qualified Crypto.Hash.SHA256     as SHA256
import qualified Crypto.Hash.SHA512     as SHA512
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Lazy   as BSL
import qualified Data.Hashable          as DataHashable
import           Data.List              (foldl')
import           Data.Text              (Text)
import qualified Data.Text              as T
import           System.Nix.Internal.Base
import           Data.Coerce            (coerce)
import           System.Nix.Internal.Truncation
                                        (truncateInNixWay)

-- | The universe of supported hash algorithms.
--
-- Currently only intended for use at the type level.
data HashAlgorithm
  = MD5
  | SHA1
  | SHA256
  | SHA512

-- | The result of running a 'HashAlgorithm'.
newtype Digest (a :: HashAlgorithm) =
  Digest BS.ByteString deriving (Eq, Ord, DataHashable.Hashable)

instance Show (Digest a) where
  show = ("Digest " <>) . show . encodeDigestWith NixBase32

-- | The primitive interface for incremental hashing for a given
-- 'HashAlgorithm'. Every 'HashAlgorithm' should have an instance.
class ValidAlgo (a :: HashAlgorithm) where
  -- | The incremental state for constructing a hash.
  type AlgoCtx a

  -- | Start building a new hash.
  initialize        :: AlgoCtx a
  -- | Append a 'BS.ByteString' to the overall contents to be hashed.
  update            :: AlgoCtx a -> BS.ByteString -> AlgoCtx a
  -- | Finish hashing and generate the output.
  finalize          :: AlgoCtx a -> Digest a

-- | A 'HashAlgorithm' with a canonical name, for serialization
-- purposes (e.g. SRI hashes)
class ValidAlgo a => NamedAlgo (a :: HashAlgorithm) where
  algoName :: Text
  hashSize :: Int

instance NamedAlgo 'MD5 where
  algoName = "md5"
  hashSize = 16

instance NamedAlgo 'SHA1 where
  algoName = "sha1"
  hashSize = 20

instance NamedAlgo 'SHA256 where
  algoName = "sha256"
  hashSize = 32

instance NamedAlgo 'SHA512 where
  algoName = "sha512"
  hashSize = 64

-- | A digest whose 'NamedAlgo' is not known at compile time.
data SomeNamedDigest = forall a . NamedAlgo a => SomeDigest (Digest a)

instance Show SomeNamedDigest where
  show sd = case sd of
    SomeDigest (digest :: Digest hashType) -> T.unpack $ "SomeDigest " <> algoName @hashType <> ":" <> encodeDigestWith NixBase32 digest

mkNamedDigest :: Text -> Text -> Either String SomeNamedDigest
mkNamedDigest name sriHash =
  let (sriName, h) = T.breakOnEnd "-" sriHash in
    if sriName == "" || sriName == (name <> "-")
    then mkDigest h
    else Left $ T.unpack $ "Sri hash method " <> sriName <> " does not match the required hash type " <> name
 where
  mkDigest h = case name of
    "md5"    -> SomeDigest <$> decodeGo @'MD5    h
    "sha1"   -> SomeDigest <$> decodeGo @'SHA1   h
    "sha256" -> SomeDigest <$> decodeGo @'SHA256 h
    "sha512" -> SomeDigest <$> decodeGo @'SHA512 h
    _        -> Left $ "Unknown hash name: " <> T.unpack name
  decodeGo :: forall a . (NamedAlgo a, ValidAlgo a) => Text -> Either String (Digest a)
  decodeGo h
    | size == base16Len = decodeDigestWith Base16 h
    | size == base32Len = decodeDigestWith NixBase32 h
    | size == base64Len = decodeDigestWith Base64 h
    | otherwise = Left $ T.unpack sriHash <> " is not a valid " <> T.unpack name <> " hash. Its length (" <> show size <> ") does not match any of " <> show [base16Len, base32Len, base64Len]
   where
    size = T.length h
    hsize = hashSize @a
    base16Len = hsize * 2
    base32Len = ((hsize * 8 - 1) `div` 5) + 1;
    base64Len = ((4 * hsize `div` 3) + 3) `div` 4 * 4;


-- | Hash an entire (strict) 'BS.ByteString' as a single call.
--
--   For example:
--   > let d = hash "Hello, sha-256!" :: Digest SHA256
--   or
--   > :set -XTypeApplications
--   > let d = hash @SHA256 "Hello, sha-256!"
hash :: forall a . ValidAlgo a => BS.ByteString -> Digest a
hash bs =
  finalize $ update @a (initialize @a) bs

mkStorePathHash :: forall a . ValidAlgo a => BS.ByteString -> BS.ByteString
mkStorePathHash bs =
  truncateInNixWay 20 $ coerce $ hash @a bs

-- | Hash an entire (lazy) 'BSL.ByteString' as a single call.
--
-- Use is the same as for 'hash'.  This runs in constant space, but
-- forces the entire bytestring.
hashLazy :: forall a . ValidAlgo a => BSL.ByteString -> Digest a
hashLazy bsl =
  finalize $ foldl' (update @a) (initialize @a) (BSL.toChunks bsl)


-- | Take BaseEncoding type of the output -> take the Digeest as input -> encode Digest
encodeDigestWith :: BaseEncoding -> Digest a -> T.Text
encodeDigestWith b = encodeWith b . coerce


-- | Take BaseEncoding type of the input -> take the input itself -> decodeBase into Digest
decodeDigestWith :: BaseEncoding -> T.Text -> Either String (Digest a)
decodeDigestWith b x = Digest <$> decodeWith b x


-- | Uses "Crypto.Hash.MD5" from cryptohash-md5.
instance ValidAlgo 'MD5 where
  type AlgoCtx 'MD5 = MD5.Ctx
  initialize = MD5.init
  update = MD5.update
  finalize = Digest . MD5.finalize

-- | Uses "Crypto.Hash.SHA1" from cryptohash-sha1.
instance ValidAlgo 'SHA1 where
  type AlgoCtx 'SHA1 = SHA1.Ctx
  initialize = SHA1.init
  update = SHA1.update
  finalize = Digest . SHA1.finalize

-- | Uses "Crypto.Hash.SHA256" from cryptohash-sha256.
instance ValidAlgo 'SHA256 where
  type AlgoCtx 'SHA256 = SHA256.Ctx
  initialize = SHA256.init
  update = SHA256.update
  finalize = Digest . SHA256.finalize

-- | Uses "Crypto.Hash.SHA512" from cryptohash-sha512.
instance ValidAlgo 'SHA512 where
  type AlgoCtx 'SHA512 = SHA512.Ctx
  initialize = SHA512.init
  update = SHA512.update
  finalize = Digest . SHA512.finalize
