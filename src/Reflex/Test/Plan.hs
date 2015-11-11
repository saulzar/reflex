{-# LANGUAGE FunctionalDependencies, BangPatterns, UndecidableInstances, ConstraintKinds, GADTs, ScopedTypeVariables, FlexibleInstances, MultiParamTypeClasses, GeneralizedNewtypeDeriving, RankNTypes, RecursiveDo, FlexibleContexts, StandaloneDeriving #-}
module Reflex.Test.Plan
  ( TestPlan(..)
  , runPlan
  , Plan
  , Schedule

  , readSchedule
  , testSchedule
  , readEvent'
  , makeDense

  , TestCase (..)

  , runTestE, runTestB
  , testE, testB
  , TestE, TestB

  , MonadIORef

  ) where

import Reflex.Class
import Reflex.Host.Class

import Control.Applicative
import Control.Monad
import Control.Monad.State.Strict

import Data.Dependent.Sum (DSum (..))
import Data.Monoid
import Data.Maybe
import qualified Data.IntMap as IntMap
import Control.Monad.Ref
import Control.DeepSeq (NFData (..))


import Data.IntMap
import Data.IORef
import System.Mem

-- Note: this import must come last to silence warnings from AMP
import Prelude

type MonadIORef m = (MonadIO m, MonadRef m, Ref m ~ Ref IO)

class (Reflex t, MonadHold t m, MonadFix m) => TestPlan t m where
  -- | Speicify a plan of an input Event firing
  -- Occurances must be in the future (i.e. Time > 0)
  -- Initial specification is

  plan :: [(Word, a)] -> m (Event t a)


data TestCase  where
  TestE  :: (Show a, Eq a) => TestE a -> TestCase
  TestB  :: (Show a, Eq a) => TestB a -> TestCase

-- Helpers to declare test cases
testE :: (Eq a, Show a) => String -> TestE a -> (String, TestCase)
testE name test = (name, TestE test)

testB :: (Eq a, Show a) => String -> TestB a -> (String, TestCase)
testB name test = (name, TestB test)

runTestB :: (MonadReflexHost t m, MonadIORef m) => Plan t (Behavior t a) -> m (IntMap a)
runTestB p = do
  (b, s) <- runPlan p
  testSchedule s $ sample b

runTestE :: (MonadReflexHost t m, MonadIORef m) => Plan t (Event t a) -> m (IntMap (Maybe a))
runTestE p = do
  (e, s) <- runPlan p
  h <- subscribeEvent e
  testSchedule s (readEvent' h)


type TestE a = forall t m. TestPlan t m => m (Event t a)
type TestB a = forall t m. TestPlan t m => m (Behavior t a)

data Firing t where
  Firing :: IORef (Maybe (EventTrigger t a)) -> a -> Firing t


instance NFData (Behavior t a) where
  rnf !_ = ()


instance NFData (Event t a) where
  rnf !_ = ()

instance NFData (Firing t) where
  rnf !_ = ()


readEvent' :: MonadReadEvent t m => EventHandle t a -> m (Maybe a)
readEvent' = readEvent >=> sequence

type Schedule t = IntMap [Firing t]
-- Implementation of a TestPlan
newtype Plan t a = Plan (StateT (Schedule t) (HostFrame t) a)

deriving instance ReflexHost t => Functor (Plan t)
deriving instance ReflexHost t => Applicative (Plan t)
deriving instance ReflexHost t => Monad (Plan t)

deriving instance ReflexHost t => MonadSample t (Plan t)
deriving instance ReflexHost t => MonadHold t (Plan t)
deriving instance ReflexHost t => MonadFix (Plan t)


instance (ReflexHost t, MonadRef (HostFrame t), Ref (HostFrame t) ~ Ref IO) => TestPlan t (Plan t) where
  plan occurances = Plan $ do
    (e, ref) <- newEventWithTriggerRef
    modify (IntMap.unionWith mappend (firings ref))
    return e

    where
      firings ref = IntMap.fromList (makeFiring ref <$> occurances)
      makeFiring ref (t, a) = (fromIntegral t, [Firing ref a])


firingTrigger :: (MonadReflexHost t m, MonadIORef m) => Firing t -> m (Maybe (DSum (EventTrigger t)))
firingTrigger (Firing ref a) = fmap (:=> a) <$> readRef ref

runPlan :: (MonadReflexHost t m, MonadIORef m) => Plan t a -> m (a, Schedule t)
runPlan (Plan p) = runHostFrame $ runStateT p mempty


makeDense :: Schedule t -> Schedule t
makeDense s = fromMaybe (emptyRange 0) $ do
  (end, _) <- fst <$> maxViewWithKey s
  return $ union s (emptyRange end)
    where
      emptyRange end = IntMap.fromList (zip [0..end + 1] (repeat []))


-- For the purposes of testing, we add in a zero frame and extend one frame (to observe changes to behaviors
-- after the last event)
-- performGC is called at each frame to test for GC issues
testSchedule :: (MonadReflexHost t m, MonadIORef m) => Schedule t -> ReadPhase m a -> m (IntMap a)
testSchedule schedule readResult = IntMap.traverseWithKey (\t occs -> liftIO performGC *> triggerFrame readResult t occs) (makeDense schedule)

readSchedule :: (MonadReflexHost t m, MonadIORef m) => Schedule t -> ReadPhase m a -> m (IntMap a)
readSchedule schedule readResult = IntMap.traverseWithKey (triggerFrame readResult) schedule

triggerFrame :: (MonadReflexHost t m, MonadIORef m) => ReadPhase m a -> Int -> [Firing t] -> m a
triggerFrame readResult _ occs =  do
    triggers <- catMaybes <$> traverse firingTrigger occs
    fireEventsAndRead triggers readResult






