{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Data.MIME
  (
  -- * MIME data
    MIME(..)
  , mime

  , parsed
  , entities
  , contentTransferDecoded

  -- * Content-Type header
  , ContentType(..)
  , ctType
  , ctSubtype
  , ctParameters
  , contentType
  ) where

{- |

MIME messages (RFC 2045, RFC 2046 and friends).

There are different approaches to parsing the MIME content bodies,
to account for different use cases.

- Parse a body into a @ByteString@ (transfer encoding ignored)

- Parse a body into start offset and length.  The content is
  not included in the parsed data.  This mode is suitable e.g.
  for attachments, where there is no point reading the data into
  the program but you need enough information to read the body
  again at a later time.

The parser is configured with a function that tells it which body
type to use for a given part.  Multipart messages are handled
specially, as part of the 'MIME' data type.

-}

import Control.Applicative

import Control.Lens
import Data.Attoparsec.ByteString
import Data.Attoparsec.ByteString.Char8 (char8)
import qualified Data.ByteString as B
import Data.CaseInsensitive (mk)
import Data.Maybe (fromMaybe)

import Data.RFC5322
import Data.RFC5322.Internal
import Data.MIME.Types
import Data.MIME.Base64
import Data.MIME.QuotedPrintable

type Entity = (Headers, B.ByteString)

data MIME
  = Part B.ByteString
  | Multipart [RFC5322 MIME]
  deriving (Show)

-- | Get all terminal entities from the MIME message
--
entities :: Fold (RFC5322 MIME) Entity
entities f (RFC5322 h a) = case a of
  Part b ->
    (\(h', b') -> RFC5322 h' (Part b')) <$> f (h, b)
  Multipart bs ->
    RFC5322 h . Multipart <$> sequenceA (entities f <$> bs)

-- | Decode an entity according to its Content-Transfer-Encoding
--
contentTransferDecoded :: Fold Entity B.ByteString
contentTransferDecoded = to f . folded
  where
  f (h, b) = preview (contentTransferEncoding h) b


-- | Get the transfer decoder for an entity

contentTransferEncoding :: Headers -> ContentTransferEncoding
contentTransferEncoding h =
  fromMaybe id $
    preview (header "content-transfer-encoding") h
    >>= (`lookup` table) . mk
  where
    table =
      [ ("7bit", id)
      , ("8bit", id)
      , ("binary", id)
      , ("quoted-printable", contentTransferEncodingQuotedPrintable)
      , ("base64", contentTransferEncodingBase64)
      -- TODO fail on unrecognised transfer encoding?
      ]


data ContentType = ContentType
  (CI B.ByteString) -- type
  (CI B.ByteString) -- subtype
  [(CI B.ByteString, B.ByteString)]  -- parameters
  deriving (Show)

ctType :: Lens' ContentType (CI B.ByteString)
ctType f (ContentType a b c) = fmap (\a' -> ContentType a' b c) (f a)

ctSubtype :: Lens' ContentType (CI B.ByteString)
ctSubtype f (ContentType a b c) = fmap (\b' -> ContentType a b' c) (f b)

ctParameters :: Lens' ContentType [(CI B.ByteString, B.ByteString)]
ctParameters f (ContentType a b c) = fmap (\c' -> ContentType a b c') (f c)
{-# ANN ctParameters ("HLint: ignore Avoid lambda" :: String) #-}

-- | Parser for Content-Type header
contentType :: Parser ContentType
contentType = ContentType
  <$> ci token
  <*  char8 '/' <*> ci token
  <*> many (char8 ';' *> skipWhile (== 32 {-SP-}) *> parameter)
  where
    parameter = (,) <$> ci token <* char8 '=' <*> value
    value = token <|> quotedString
    token = takeWhile1 (\c -> c >= 33 && c <= 126 && notInClass "()<>@,;:\\\"/[]?=" c)


-- | Given a parser, construct a 'Fold'
parsed :: Parser a -> Fold B.ByteString a
parsed p = to (parseOnly p) . folded


-- | Top-level MIME body parser that uses headers to decide how to
--   parse the body.
--
-- Do not use this parser for parsing a nested message.
--
mime :: Headers -> Parser MIME
mime = mime' endOfInput

mime'
  :: Parser end
  -- ^ Parser for the part delimiter.  If this part is multipart,
  --   we pass it on to the 'multipart' parser.  If this part is
  --   not multipart, we slurp the input until the parser matches.
  -> Headers
  -> Parser MIME
mime' end h = case preview (header "content-type" . parsed contentType) h of
  Just ct | view ctType ct == "multipart" ->
    case preview (ctParameters . header "boundary") ct of
      Nothing -> part
      Just boundary -> Multipart <$> multipart end boundary
  _ -> part
  where
    part = Part . B.pack <$> manyTill anyWord8 end

{-

The multipart parser makes a few opinionated decisions.

- Preamble and epilogue are discarded

- Preamble and epilogue are assumed to be short, therefore
  the cost of skipping over these is also assumed to be low
  (until proven otherwise)

-}
multipart
  :: Parser end    -- ^ parser that indicates where the epilogue ends
  -> B.ByteString  -- ^ boundary, sans leading "--"
  -> Parser [RFC5322 MIME]
multipart end boundary =
  multipartBody
  where
    dashes = string "--"
    dashBoundary = dashes *> string boundary
    delimiter = crlf *> dashBoundary
    part = message (mime' delimiter)
    multipartBody =
      skipTill (dashBoundary *> crlf) -- FIXME transport-padding
      *> part `sepBy` crlf
      <* dashes <* crlf <* skipTill end
