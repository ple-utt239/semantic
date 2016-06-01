{-# LANGUAGE DeriveAnyClass, DeriveGeneric, FlexibleInstances, StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import Alignment
import Criterion.Main
import Data.Bifunctor.Join
import Data.Functor.Foldable
import qualified Data.OrderedMap as Map
import Data.String
import Data.Text.Arbitrary ()
import Data.These
import Diff
import Prologue
import Syntax
import Test.QuickCheck hiding (Fixed)

main :: IO ()
main = do
  benchmarks <- sequenceA [ generativeBenchmark "numberedRows" 10 length (nf (numberedRows :: [Join These ()] -> [Join These (Int, ())])) ]
  defaultMain benchmarks

-- | Defines a named group of n benchmarks over inputs generated by an `Arbitrary` instance.
-- |
-- | The inputs’ sizes at each iteration are measured by a metric function, which gives the name of the benchmark. This makes it convenient to correlate a benchmark of some function over lists with e.g. input `length`.
generativeBenchmark :: (Arbitrary a, Show m, Ord m) => String -> Int -> (a -> m) -> (a -> Benchmarkable) -> IO Benchmark
generativeBenchmark name n metric benchmark = do
  benchmarks <- traverse measure (replicate n defaultSize)
  pure $! bgroup name (snd <$> (sortOn fst benchmarks))
  where measure n = do
          input <- generate (resize n arbitrary)
          let measurement = metric input
          pure $! (measurement, bench (show measurement) (benchmark input))
        defaultSize = 100


newtype ArbitraryDiff leaf annotation = ArbitraryDiff { unArbitraryDiff :: DiffF leaf annotation (ArbitraryDiff leaf annotation) }
  deriving (Show, Eq, Generic)

toDiff :: ArbitraryDiff leaf annotation -> Diff leaf annotation
toDiff = unfold unArbitraryDiff


-- Instances

deriving instance (NFData a, NFData b) => NFData (These a b)
deriving instance NFData a => NFData (Join These a)

instance (Arbitrary a, Arbitrary b) => Arbitrary (These a b) where
  arbitrary = oneof [ This <$> arbitrary
                    , That <$> arbitrary
                    , These <$> arbitrary <*> arbitrary ]
  shrink = these (fmap This . shrink) (fmap That . shrink) (\ a b -> (This <$> shrink a) ++ (That <$> shrink b) ++ (These <$> shrink a <*> shrink b))

instance Arbitrary a => Arbitrary (Join These a) where
  arbitrary = Join <$> arbitrary
  shrink (Join a) = Join <$> shrink a

instance (Arbitrary leaf, Arbitrary annotation) => Arbitrary (ArbitraryDiff leaf annotation) where
  arbitrary = scale (`div` 2) $ sized (\ x -> boundedTerm x x) -- first indicates the cube of the max length of lists, second indicates the cube of the max depth of the tree
    where boundedTerm maxLength maxDepth = (ArbitraryDiff .) . (Free .) . (:<) <$> (pure <$> arbitrary) <*> boundedSyntax maxLength maxDepth
          boundedSyntax _ maxDepth | maxDepth <= 0 = Leaf <$> arbitrary
          boundedSyntax maxLength maxDepth = frequency
            [ (12, Leaf <$> arbitrary),
              (1, Indexed . take maxLength <$> listOf (smallerTerm maxLength maxDepth)),
              (1, Fixed . take maxLength <$> listOf (smallerTerm maxLength maxDepth)),
              (1, Keyed . Map.fromList . take maxLength <$> listOf (arbitrary >>= (\x -> (,) x <$> smallerTerm maxLength maxDepth))) ]
          smallerTerm maxLength maxDepth = boundedTerm (div maxLength 3) (div maxDepth 3)
