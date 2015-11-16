{-# LANGUAGE ConstraintKinds, TypeSynonymInstances, BangPatterns, ScopedTypeVariables, TupleSections, GADTs, RankNTypes, FlexibleInstances, FlexibleContexts, MultiParamTypeClasses, GeneralizedNewtypeDeriving #-}

module Reflex.Bench.Focused where

import Reflex
import Reflex.TestPlan

import Control.Applicative
import Data.Foldable
import Data.Traversable

import Data.Map (Map)
import qualified Data.Map as Map

import Data.List
import Data.List.Split

import Prelude


mergeTree :: Num a => (Monoid (f [a]), Functor f) => Int -> [f a] -> f a
mergeTree n es | length es <= n =  sum' es
               | otherwise = mergeTree n subTrees
  where
    merges   = chunksOf n es
    subTrees = map sum' merges
    sum'     = fmap sum . mconcat . fmap (fmap (:[]) )

-- N events all firing in one frame
denseEvents :: TestPlan t m => Word -> m [Event t Word]
denseEvents n = for [1..n] $ \i -> plan [(1, i)]

-- Event which fires once on first frame
event :: TestPlan t m => m (Event t Word)
event = plan [(1, 0)]

-- Event which fires constantly over N frames
events :: TestPlan t m => Word -> m (Event t Word)
events n  = plan $ (\i -> (i, i)) <$> [1..n]

-- N events all originating from one event
fmapFan :: Reflex t => Word -> Event t Word -> [Event t Word]
fmapFan n e = (\i -> (+i) <$> e) <$> [1..n]

-- Create an Event with a Map which is dense to size N
denseMap :: TestPlan t m => Word -> m (Event t (Map Word Word))
denseMap n = plan [(1, m)] where
  m = Map.fromList $ zip [1..n] [1..n]

-- Create an Event with a Map which is sparse, firing N events over M frames and Fan size S
-- sparseMap ::
-- sparseMap n frames size =   events frames
--   occs = transpose $ chunksOf frames $ flip zip [1..n * frames] $ take (n * frames) $ concat (replicate [1..size])


iterateN :: (a -> a) -> a -> Word -> a
iterateN f a n = iterate f a !! fromIntegral n

fmapChain :: Reflex t => Word -> Event t Word -> (Event t Word)
fmapChain n e = iterateN (fmap (+1)) e n


switchFactors :: (Reflex t, MonadHold t m) => Word -> Event t Word -> m (Event t Word)
switchFactors n e = iter n e where
  iter 0 e = return e
  iter n e = do
    b <- hold ((+1) <$> e) (e <$ ffilter ((== 0) . (n `mod`)) e)
    iter (n - 1) (switch b)


switchChain :: (Reflex t, MonadHold t m) => Word -> Event t Word -> m (Event t Word)
switchChain n e = iter n e where
  iter 0 e = return e
  iter n e = do
    b <- hold e (e <$ e)
    iter (n - 1) (switch b)

switchPromptlyChain :: (Reflex t, MonadHold t m) => Word -> Event t Word -> m (Event t Word)
switchPromptlyChain n e = iter n e where
  iter 0 e = return e
  iter n e = do
    d <- holdDyn e (e <$ e)
    iter (n - 1) (switchPromptlyDyn d)

coinChain :: Reflex t => Word -> Event t Word -> Event t Word
coinChain n e = iterateN (\e' -> coincidence (e' <$ e')) e n


pullChain :: Reflex t => Word -> Behavior t Word -> Behavior t Word
pullChain n b = iterateN (\b' -> pull $ sample b') b n

-- Give N events split across M frames approximately evenly
sparseEvents :: TestPlan t m => Word -> Word -> m [Event t Word]
sparseEvents n frames = do
  fmap concat $ for frameOccs $ \(frame, firing) ->
    for firing $ \i -> plan [(frame, i)]
  where
    frameOccs = zip [1..] $ transpose $ chunksOf (fromIntegral frames) [1..n]





counters :: TestPlan t m => Word -> Word -> m [Behavior t Int]
counters n frames = traverse (fmap current . count) =<< sparseEvents n frames


-- Given a function which creates a sub-network (from a single event)
-- Create a plan which uses a switch to substitute it
switches :: TestPlan t m => Word -> (forall m. MonadHold t m => Event t Word -> m (Event t a)) -> m (Event t a)
switches numFrames f = do
  es <- events numFrames
  switch <$> hold never (makeEvents es)

    where
      makeEvents es =  pushAlways (\n -> f (fmap (+n) es)) es

-- Two sets of benchmarks, one which we're interested in testing subscribe time (as well as time to fire frames)
-- the other, which we're only interested in time for running frames
subscribing :: Word -> Word -> [(String, TestCase)]
subscribing n frames =
  [ testE "fmapFan merge"       $ switches frames (return . mergeList . fmapFan n)
  , testE "fmapFan/mergeTree 8" $ switches frames (return . mergeTree 8 . fmapFan n)
  , testE "fmapChain"           $ switches frames (return . fmapChain n)
  , testE "switchChain"         $ switches frames (switchChain n)
  , testE "switchPromptlyChain" $ switches frames (switchPromptlyChain n)
  , testE "switchFactors"       $ switches frames (switchFactors n)
  , testE "coincidenceChain"    $ switches frames (return . coinChain n)
  ]


firing :: Word -> [(String, TestCase)]
firing n =
  [ testE "dense mergeTree 8"      $ mergeTree 8 <$> denseEvents n
  , testE "sparse 10/mergeTree 8"  $ mergeTree 8 <$> sparseEvents n 10
  , testE "runFrame"               $ events n
  , testB "sum counters" $ do
      counts <- counters n 10
      return $ pull $ sum <$> traverse sample counts

  , testB "pullChain"                 $ pullChain n . current <$> (count =<< events 4)
  , testB "mergeTree (pull) counters" $ mergeTree 8 <$> counters n 10
  ]


