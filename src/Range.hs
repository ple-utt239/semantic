module Range where

import qualified Data.Text as T
import Control.Applicative ((<|>))
import qualified Data.Char as Char
import Data.Maybe (fromMaybe)

-- | A half-open interval of integers, defined by start & end indices.
data Range = Range { start :: !Int, end :: !Int }
  deriving (Eq, Show)

substring :: Range -> T.Text -> T.Text
substring range = T.take (end range - start range) . T.drop (start range)

sublist :: Range -> [a] -> [a]
sublist range = take (end range - start range) . drop (start range)

totalRange :: T.Text -> Range
totalRange t = Range 0 $ T.length t

offsetRange :: Int -> Range -> Range
offsetRange i (Range start end) = Range (i + start) (i + end)

rangesAndWordsFrom :: Int -> String -> [(Range, String)]
rangesAndWordsFrom _ "" = []
rangesAndWordsFrom startIndex string = fromMaybe [] $ takeAndContinue <$> (word <|> punctuation) <|> skipAndContinue <$> space
  where
    word = parse isWord string
    punctuation = parse (not . isWordOrSpace) string
    space = parse Char.isSpace string
    takeAndContinue (parsed, rest) = (Range startIndex $ endFor parsed, parsed) : rangesAndWordsFrom (endFor parsed) rest
    skipAndContinue (parsed, rest) = rangesAndWordsFrom (endFor parsed) rest
    endFor parsed = startIndex + length parsed
    parse predicate string = case span predicate string of
      ([], _) -> Nothing
      (parsed, rest) -> Just (parsed, rest)
    isWordOrSpace c = Char.isSpace c || isWord c
    -- | Is this a word character?
    -- | Word characters are defined as in [Ruby’s `\p{Word}` syntax](http://ruby-doc.org/core-2.1.1/Regexp.html#class-Regexp-label-Character+Properties), i.e.:
    -- | > A member of one of the following Unicode general category _Letter_, _Mark_, _Number_, _Connector_Punctuation_
    isWord c = Char.isLetter c || Char.isNumber c || Char.isMark c || Char.generalCategory c == Char.ConnectorPunctuation

-- | Return Just the last index from a non-empty range, or if the range is empty, Nothing.
maybeLastIndex :: Range -> Maybe Int
maybeLastIndex (Range start end) | start == end = Nothing
maybeLastIndex (Range _ end) = Just $ end - 1

unionRanges :: (Functor f, Foldable f) => f Range -> Range
unionRanges ranges = fromMaybe mempty . foldl mappend Nothing $ Just <$> ranges

instance Ord Range where
  a <= b = start a <= start b

instance Monoid Range where
  mempty = Range 0 0
  mappend (Range start1 end1) (Range start2 end2) = Range (min start1 start2) (max end1 end2)
