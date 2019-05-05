--
-- Copyright © 2013-2015 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ViewPatterns               #-}

-- | Description: Common types and encoding for OAuth2 Types
--
-- Common types and encoding for OAuth2 Types
module Network.OAuth2.Server.Types.Common (
-- * Syntax Descriptions for OAuth2
  vschar,
  nqchar,
  nqschar,
  unicodecharnocrlf,
-- * Redirect URIs
  RedirectURI,
  addQueryParameters,
  redirectURI,
-- * Postgres parsing for URIs
  fromFieldURI,
  uriToBS,
-- * URI JSON/Aeson Encoding/Decoding
  uriToJSON,
  uriFromJSON,
-- * Commonly used typeclasses
  ToHTTPHeaders(..),
) where

import           Blaze.ByteString.Builder             (toByteString)
import           Control.Lens.Fold                    (preview, (^?))
import           Control.Lens.Operators               ((%~), (&), (^.))
import           Control.Lens.Prism                   (Prism', prism')
import           Control.Lens.Review                  (review)
import           Data.Aeson                           (ToJSON (..), Value,
                                                       withText)
import qualified Data.Aeson.Types                     as Aeson (Parser)
import           Data.ByteString                      (ByteString)
import           Data.Char                            (ord)
import           Data.Monoid                          ((<>))
import qualified Data.Text.Encoding                   as T (decodeUtf8,
                                                            encodeUtf8)
import           Data.Typeable                        (Typeable)
import           Data.Word                            (Word8)
import           Database.PostgreSQL.Simple.FromField
import           Database.PostgreSQL.Simple.ToField
import           Network.HTTP.Types.Header            as HTTP
import           URI.ByteString                       (URI, parseURI,
                                                       queryPairsL,
                                                       serializeURIRef,
                                                       strictURIParserOptions,
                                                       uriFragmentL,
                                                       queryL)
import           Yesod.Core                           (PathPiece (..))

--------------------------------------------------------------------------------

-- * Syntax Descriptions for OAuth2
--
-- Defined here https://tools.ietf.org/html/rfc6749#appendix-A
--
-- Uses Augmented Backus-Nuar Form (ABNF) Syntax
-- ABNF RFC is found here: https://tools.ietf.org/html/rfc5234

-- | VSCHAR = %x20-7E
vschar :: Word8 -> Bool
vschar c = c>=0x20 && c<=0x7E

-- | NQCHAR = %x21 / %x23-5B / %x5D-7E
nqchar :: Word8 -> Bool
nqchar c = or
    [ c==0x21
    , c>=0x23 && c<=0x5B
    , c>=0x5D && c<=0x7E
    ]

-- | NQSCHAR    = %x20-21 / %x23-5B / %x5D-7E
nqschar :: Word8 -> Bool
nqschar c = or
    [ c>=0x20 && c<=0x21
    , c>=0x23 && c<=0x5B
    , c>=0x5D && c<=0x7E
    ]

-- | UNICODECHARNOCRLF = %x09 /%x20-7E / %x80-D7FF /
--                       %xE000-FFFD / %x10000-10FFFF
unicodecharnocrlf :: Char -> Bool
unicodecharnocrlf (ord -> c) = or
    [ c==0x09
    , c>=0x20    && c<=0x7E
    , c>=0x80    && c<=0xD7FF
    , c>=0xE000  && c<=0xFFFD
    , c>=0x10000 && c<=0x10FFFF
    ]

--------------------------------------------------------------------------------

-- * Redirect URIs

-- | Redirect URIs as used in the OAuth2 RFC.
newtype RedirectURI = RedirectURI { unRedirectURI :: URI }
  deriving (Eq, Show, Typeable)

-- | Helper function to safely add query parameters without having to use the
--   exposed prism to convert to and from Bytestrings and RedirectURIs
addQueryParameters :: RedirectURI -> [(ByteString, ByteString)] -> RedirectURI
addQueryParameters (RedirectURI uri) params = RedirectURI $ uri & queryL . queryPairsL %~ (<> params)

-- | Redirect URIs must be absolute and have no fragment as defined at:
--
--   https://tools.ietf.org/html/rfc6749#section-3.1.2
--
--   https://tools.ietf.org/html/rfc3986#section-4.3
redirectURI :: Prism' ByteString RedirectURI
redirectURI = prism' fromRedirect toRedirect
  where
    fromRedirect :: RedirectURI -> ByteString
    fromRedirect = toByteString . serializeURIRef . unRedirectURI

    toRedirect :: ByteString -> Maybe RedirectURI
    toRedirect bs = case parseURI strictURIParserOptions bs of
        Left _ -> Nothing
        Right uri -> case uri ^. uriFragmentL of
            Just _ -> Nothing
            Nothing -> Just $ RedirectURI uri

-- PathPiece instances for RedirectURI

instance PathPiece RedirectURI where
    fromPathPiece = preview redirectURI . T.encodeUtf8
    toPathPiece = T.decodeUtf8 . review redirectURI

-- Postgres instances for RedirectURI

instance FromField RedirectURI where
    fromField f bs = do
        x <- fromField f bs
        case x ^? redirectURI of
            Nothing -> returnError ConversionFailed f $ "Prism failed to convert URI: " <> show x
            Just uris -> return uris

instance ToField RedirectURI where
    toField = toField . review redirectURI

-- * Postgres parsing for URIs

-- | FromField parser for URI.
--
--   Similar to the one used in the FromField instance for RedirectURI but
--   allowing URI fragments.
fromFieldURI :: FieldParser URI
fromFieldURI f bs = do
    x <- fromField f bs
    case parseURI strictURIParserOptions x of
        Left e -> returnError ConversionFailed f (show e)
        Right uri -> return uri

-- | ToField convertor for URI.
--
-- Similar to the one used in the ToField instance for RedirectURI but
-- allowing URI fragments.
uriToBS :: URI -> ByteString
uriToBS = toByteString . serializeURIRef

--------------------------------------------------------------------------------

-- * URI JSON/Aeson Encoding/Decoding

-- | Convert a URI to an Aeson Value
uriToJSON :: URI -> Value
uriToJSON = toJSON . T.decodeUtf8 . uriToBS

-- | Parse a URI from an Aeson Value
uriFromJSON :: Value -> Aeson.Parser URI
uriFromJSON = withText "URI" $ \t ->
    case parseURI strictURIParserOptions $ T.encodeUtf8 t of
        Left e -> fail $ show e
        Right u -> return u

--------------------------------------------------------------------------------

-- * Commonly used typeclasses

-- | Produce headers to be included in a request.
class ToHTTPHeaders a where
    -- | Generate headers to be included in a HTTP request/response.
    toHeaders :: a -> [HTTP.Header]
