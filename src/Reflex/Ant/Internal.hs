{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE EmptyDataDecls #-}

module Reflex.Ant.Internal where

import Data.IORef
import System.Mem.Weak

import System.IO.Unsafe
import Control.Monad.Ref
import Control.Monad.Reader
import Control.Monad.State.Strict

import Control.Monad.Primitive

import Unsafe.Coerce

import Data.Foldable
import Data.Maybe
import Data.Functor.Misc

import qualified Data.Dependent.Map as DMap
import Data.Dependent.Map (DMap, GCompare)
import Data.Dependent.Sum

import Data.Semigroup
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap

import qualified Reflex.Class as R
import qualified Reflex.Host.Class as R


data MakeNode a where
  MakeNode        :: !(NodeRef a) -> !(a -> EventM (Maybe b)) -> MakeNode b
  MakeMerge       :: GCompare k => !([DSum (WrapArg NodeRef k)]) -> MakeNode (DMap k)
  MakeSwitch      :: !(Behavior (Event a)) -> MakeNode a
  MakeCoincidence :: !(NodeRef (Event a)) -> MakeNode a
  MakeRoot        :: MakeNode a

type LazyRef a b = IORef (Either a b)
newtype NodeRef a = NodeRef (LazyRef (MakeNode a) (Node a))

type PullRef a = LazyRef (BehaviorM a) (Pull a)

data Event a
  = Never
  | Event !(NodeRef a)

data Behavior a
  = Constant !a
  | PullB !(PullRef a)
  | HoldB !(Hold a)

newtype EventHandle a = EventHandle { unEventHandle :: Maybe (Node a) }

type Height = Int

data Subscription a b where
  PushSub   :: Node a -> Node b -> (a -> EventM (Maybe b)) -> Subscription a b
  MergeSub  :: GCompare k => Merge k -> k a -> Subscription a (DMap k)
  HoldSub   :: Node a -> Hold a -> Subscription a a
  SwitchSub :: Switch a -> Subscription a a
  CoinInner :: Coincidence a -> Subscription a a
  CoinOuter :: Coincidence a -> Subscription (Event a) a

instance Show (Subscription a b) where
  show (PushSub   {}) = "Push"
  show (MergeSub  {}) = "Merge"
  show (HoldSub   {}) = "Hold"
  show (SwitchSub {}) = "Switch"
  show (CoinInner {}) = "Inner Coincidence"
  show (CoinOuter {}) = "Outer Coincidence"


data Subscribing b where
  Subscribing       :: (Subscription a b) -> Subscribing b
  SubscribingMerge  :: (Merge k) -> Subscribing (DMap k)
  SubscribingSwitch :: (Switch a) -> Subscribing a
  SubscribingCoin   :: Coincidence a -> Subscribing a
  SubscribingRoot   :: Subscribing b

data WeakSubscriber a = forall b. WeakSubscriber { unWeak :: !(Weak (Subscription a b)) }


data Node a = Node
  { nodeSubs      :: !(IORef [WeakSubscriber a])
  , nodeHeight    :: !(IORef Int)
  , nodeParents   :: (Subscribing a)
  , nodeValue     :: !(IORef (Maybe a))
  }


data Invalidator where
  PullInv   :: Pull a   -> Invalidator
  SwitchInv :: Switch a -> Invalidator


data Pull a  = Pull
  { pullInv     :: Invalidator
  , pullInvs    :: !(IORef [Weak Invalidator])
  , pullValue   :: !(IORef (Maybe a))
  , pullCompute :: (BehaviorM a)
  }

data Hold a = Hold
  { holdInvs     :: !(IORef [Weak Invalidator])
  , holdValue    :: !(IORef a)
  , holdSub      :: !(LazyRef (Event a) (Maybe (Subscription a a)))
  }

type NodeSub a = (Node a, Weak (Subscription a a))

data Switch a = Switch
  { switchNode   :: Node a
  , switchSub    :: Subscription a a
  , switchConn   :: !(IORef (Maybe (NodeSub a)))
  , switchInv    :: Invalidator
  , switchSource :: Behavior (Event a)
  }

data Coincidence a = Coincidence
  { coinNode     :: Node a
  , coinParent   :: Node (Event a)
  , coinOuterSub :: Subscription (Event a) a
  , coinInnerSub :: Subscription a a
  }


data MergeParent k a where
  MergeParent      :: Node a -> (Subscription a (DMap k)) -> MergeParent k a

data Merge k = Merge
  { mergeNode     :: Node (DMap k)
  , mergeParents  :: DMap (WrapArg (MergeParent k) k)
  , mergePartial  :: !(IORef (DMap k))
  }


-- A bunch of existentials used so we can put these things in lists
data WriteHold      where WriteHold      :: Hold a    -> !a -> WriteHold
data HoldInit       where HoldInit       :: Hold a    -> HoldInit
data Connect        where Connect        :: Switch a  -> Connect
data DelayMerge     where DelayMerge     :: Merge k   -> DelayMerge
data CoincidenceOcc where CoincidenceOcc :: NodeSub a ->  CoincidenceOcc
data SomeNode       where SomeNode       :: Node a    -> SomeNode


-- EvenM environment, lists of things which need attention at the end of a frame
data Env = Env
  { envDelays       :: !(IORef (IntMap [DelayMerge]))
  , envClears       :: !(IORef [SomeNode])
  , envHolds        :: !(IORef [WriteHold])
  , envHoldInits    :: !(IORef [HoldInit])
  , envCoincidences :: !(IORef [CoincidenceOcc])
  }

newtype EventM a = EventM { unEventM :: ReaderT Env IO a }
    deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadReader Env)

newtype BehaviorM a = BehaviorM { unBehaviorM :: ReaderT (Weak Invalidator) IO a }
    deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadReader (Weak Invalidator))


instance MonadRef EventM where
  type Ref EventM = Ref IO
  {-# INLINE newRef #-}
  {-# INLINE readRef #-}
  {-# INLINE writeRef #-}
  newRef = liftIO . newRef
  readRef = liftIO . readRef
  writeRef r a = liftIO $ writeRef r a

instance MonadRef BehaviorM where
  type Ref BehaviorM = Ref IO
  {-# INLINE newRef #-}
  {-# INLINE readRef #-}
  {-# INLINE writeRef #-}
  newRef = liftIO . newRef
  readRef = liftIO . readRef
  writeRef r a = liftIO $ writeRef r a


{-# NOINLINE unsafeLazy #-}
unsafeLazy :: a -> LazyRef a b
unsafeLazy create = unsafePerformIO $ newIORef (Left create)


makeNode :: MakeNode a -> IO (NodeRef a)
makeNode create = NodeRef <$> newIORef (Left create)


unsafeCreateEvent :: MakeNode a -> Event a
unsafeCreateEvent = Event . NodeRef . unsafeLazy


createEvent  :: MakeNode a -> IO (Event a)
createEvent create = Event <$> makeNode create



type MonadIORef m = (MonadIO m, MonadRef m, Ref m ~ IORef)


readLazy :: MonadIORef m => (a -> m b) -> LazyRef a b -> m b
readLazy create ref = readRef ref >>= \case
    Left a -> do
      node <- create a
      writeRef ref (Right node)
      return node
    Right node -> return node

readNodeRef :: NodeRef a -> EventM (Node a)
readNodeRef (NodeRef ref) = readLazy createNode ref


eventNode :: Event a -> EventM (Maybe (Node a))
eventNode Never       = return Nothing
eventNode (Event ref) = Just <$> readNodeRef ref


readHeight :: MonadIORef m => Node a -> m Int
readHeight node = readRef (nodeHeight node)


newNode :: MonadIO m => Height -> Subscribing a -> m (Node a)
newNode height parents = liftIO $
  Node <$> newRef [] <*> newRef height <*> pure parents <*> newRef Nothing


readNode :: MonadIORef m => Node a -> m (Maybe a)
readNode node = readRef (nodeValue node)


writeNode :: Node a -> a -> EventM ()
writeNode node a = do
  writeRef (nodeValue node) (Just a)
  clearsRef <- asks envClears
  modifyRef clearsRef (SomeNode node :)

readEvent :: EventHandle a -> IO (Maybe a)
readEvent (EventHandle n) = join <$> traverse readNode n


subscribe :: MonadIORef m => Node a -> Subscription a b -> m (Weak (Subscription a b))
subscribe node sub = do
  weakSub <- liftIO (mkWeakPtr sub Nothing)
  modifyRef (nodeSubs node) (WeakSubscriber weakSub :)
  return weakSub

subscribe_ :: MonadIORef m => Node a -> Subscription a b -> m ()
subscribe_ node = void . subscribe node

createNode :: MakeNode a -> EventM (Node a)
createNode (MakeNode ref f) = makePush ref f
createNode (MakeMerge refs) = makeMerge refs
createNode (MakeSwitch b) = makeSwitch b
createNode (MakeCoincidence ref) = makeCoincidence ref
createNode MakeRoot = newNode 0 SubscribingRoot

constant :: a -> Behavior a
constant = Constant

hold :: a -> Event a -> EventM (Behavior a)
hold a e = do
  h <- Hold <$> newRef [] <*> newRef a <*> newRef (Left e)
  delayInitHold h
  return $ HoldB h

initHold :: HoldInit -> EventM ()
initHold (HoldInit h) = void $ readLazy createHold (holdSub h) where
  createHold (Never) = return  Nothing
  createHold (Event ref) = do
    parent <- readNodeRef ref
    value <- readNode parent
    traverse_ (delayHold h) value

    let sub = HoldSub parent h
    subscribe_ parent sub

    return (Just sub)


pull :: BehaviorM a -> Behavior a
pull = PullB . unsafeLazy

createPull :: BehaviorM a -> IO (Pull a)
createPull f = do
  rec
    p <- Pull <$> pure (PullInv p) <*> newRef [] <*> newRef Nothing <*> pure f
  return p


runBehaviorM ::  BehaviorM a -> Invalidator -> IO a
runBehaviorM (BehaviorM m) inv = runReaderT m =<< mkWeakPtr inv Nothing

runPull :: PullRef a -> Maybe (Weak Invalidator) -> IO a
runPull ref inv = do
  Pull self invs valRef compute  <- readLazy createPull ref
  traverse_ (modifyRef invs . (:)) inv
  readRef valRef >>= \case
    Nothing -> do
      a <- runBehaviorM compute self
      a <$ writeRef valRef (Just a)
    Just a  -> return a


sampleIO :: Behavior a -> IO a
sampleIO (Constant a) = return a
sampleIO (HoldB h)    = readRef (holdValue h)
sampleIO (PullB ref)  = runPull ref Nothing


sample :: Behavior a -> BehaviorM a
sample (Constant a) = return a
sample (HoldB (Hold invs value sub)) = do
  liftIO (touch sub) --Otherwise the gc seems to know that we never read the IORef again!
  ask >>= modifyRef invs . (:)
  readRef value
sample (PullB ref) = liftIO . runPull ref =<< asks Just


sampleE :: Behavior a -> EventM a
sampleE = liftIO . sampleIO


pattern Invalid :: Height
pattern Invalid = -1

coincidence :: Event (Event a) -> Event a
coincidence Never = Never
coincidence (Event ref) = unsafeCreateEvent (MakeCoincidence ref)

makeCoincidence :: forall a. NodeRef (Event a) -> EventM (Node a)
makeCoincidence ref = do
  parent <- readNodeRef ref
  height <- readHeight parent

  rec
    let c = Coincidence node parent outerSub innerSub
        outerSub = CoinOuter c
        innerSub = CoinInner c
    node <- newNode height (SubscribingCoin c)

  subscribe_ parent outerSub
  readNode parent >>= traverse_ (connectC c)
  return node


connectC :: Coincidence a -> Event a -> EventM (Maybe a)
connectC _ Never = return Nothing
connectC (Coincidence node parent _ innerSub) (Event ref) = do
  inner <- readNodeRef ref
  innerHeight <- readHeight inner
  height <- readHeight parent

  value <- readNode inner
  case value of
    -- Already occured simply pass on the occurance
    Just a  -> writeNode node a

    -- Yet to occur, subscribe the event, record the susbcription as a CoincidenceOcc
    -- and adjust our height
    Nothing -> when (innerHeight >= height) $ do
      weakSub <- subscribe inner innerSub
      askModifyRef envCoincidences (CoincidenceOcc (inner, weakSub):)
      liftIO $ propagateHeight innerHeight node
  return value




switch :: Behavior (Event a) -> Event a
switch (Constant e) = e
switch b = unsafeCreateEvent (MakeSwitch b)

makeSwitch ::  Behavior (Event a) -> EventM (Node a)
makeSwitch source =  do
  connRef <- newRef Nothing
  rec
    let s   = Switch node sub connRef inv source
        inv = SwitchInv s
        sub = SwitchSub s
    node <- newNode 0 (SubscribingSwitch s)

  writeRef (nodeHeight node)  =<< connect s
  return node

connect :: Switch a -> EventM Height
connect (Switch node sub connRef inv source) = do
  e <- liftIO $ runBehaviorM (sample source) inv
  case e of
    Never       -> 0 <$ writeRef connRef Nothing
    Event ref -> do
      parent <- readNodeRef ref
      weakSub <- subscribe parent sub

      writeRef connRef (Just (parent, weakSub))
      readNode parent >>= traverse_ (writeNode node)
      readHeight parent


boolM :: Applicative m => Bool -> m b -> m (Maybe b)
boolM True  m  = Just <$> m
boolM False _  = pure Nothing

bool :: Bool -> a -> Maybe a
bool True  a  = Just a
bool False _  = Nothing


reconnect :: Connect -> IO ()
reconnect (Connect s) = do
  -- Forcibly disconnect any existing connection
  conn <- readRef (switchConn s)
  traverse_ (finalize . snd) conn

  height <- evalEventM $ connect s
  propagateHeight height (switchNode s)



disconnectC :: CoincidenceOcc -> IO ()
disconnectC (CoincidenceOcc (_, weakSub)) = finalize weakSub

connectSwitches :: [Connect] -> [CoincidenceOcc] -> IO ()
connectSwitches connects coincidences = do
  traverse_ disconnectC coincidences
  traverse_ reconnect connects



push :: (a -> EventM (Maybe b)) -> Event a -> Event b
push _ Never = Never
push f (Event ref) = unsafeCreateEvent $ MakeNode ref f

pushAlways :: (a -> EventM b) -> Event a -> Event b
pushAlways f = push (fmap Just . f)


makePush :: NodeRef a -> (a -> EventM (Maybe b)) -> EventM (Node b)
makePush ref f =  do
  parent <- readNodeRef ref
  height <- readHeight parent
  rec
    let sub = PushSub parent node f
    node <- newNode height (Subscribing sub)

  readNode parent >>= traverse_
    (f >=> traverse_ (writeNode node))

  subscribe_ parent sub
  return node


merge :: GCompare k => DMap (WrapArg Event k) -> Event (DMap k)
merge events = case catEvents (DMap.toAscList events) of
  [] -> Never
  refs -> unsafeCreateEvent (MakeMerge refs)


mergeSubscribing :: GCompare k =>  Merge k -> DSum (WrapArg Node k) -> IO (DSum (WrapArg (MergeParent k) k))
mergeSubscribing  merge' (WrapArg k :=> parent) = do
  subscribe_ parent sub
  return (WrapArg k :=> MergeParent parent sub)

  where sub = MergeSub merge' k


makeMerge :: GCompare k =>  [DSum (WrapArg NodeRef k)] -> EventM (Node (DMap k))
makeMerge refs = do
  parents <- traverseDSums readNodeRef refs
  height <- maximumHeight <$> sequence (mapDSums readHeight parents)
  values <- catDSums <$> traverseDSums readNode parents

  rec
    subs   <- liftIO $ traverse (mergeSubscribing merge') parents
    merge' <- Merge node (fromAsc subs) <$> newRef DMap.empty
    node <- newNode (succ height) (SubscribingMerge merge')

  when (not  . null  $ values) $ writeNode node (fromAsc values)
  return node

never :: Event a
never = Never


newEventWithFire :: IO (Event a, a -> DSum Trigger)
newEventWithFire = do
  root <- makeNode MakeRoot
  return (Event root, (Trigger root :=>))



data Trigger a = Trigger (NodeRef a)



traverseWeak :: MonadIORef m => (forall b. Subscription a b -> m ()) -> [WeakSubscriber a] -> m [WeakSubscriber a]
traverseWeak f subs = do
  flip filterM subs $ \(WeakSubscriber weak) -> do
    m <- liftIO (deRefWeak weak)
    isJust m <$ traverse_ f m

traverseSubs :: MonadIORef m =>  (forall b. Subscription a b -> m ()) -> Node a -> m ()
traverseSubs f node = modifyM (nodeSubs node) $ traverseWeak f


forSubs :: MonadIORef m =>  Node a -> (forall b. Subscription a b -> m ()) -> m ()
forSubs node f = traverseSubs f node


modifyM :: MonadRef m => Ref m a -> (a -> m a) -> m ()
modifyM ref f = readRef ref >>= f >>= writeRef ref

-- | Delayed operations
delayMerge :: Merge k -> Height ->  EventM ()
delayMerge m height = do
  delayRef <- asks envDelays
  modifyRef delayRef ins
    where ins = IntMap.insertWith (<>) height [DelayMerge m]

delayHold :: Hold a -> a -> EventM ()
delayHold h value = do
  holdsRef <- asks envHolds
  modifyRef holdsRef (WriteHold h value:)


delayInitHold :: Hold a -> EventM ()
delayInitHold ref = do
  holdInitRef <- asks envHoldInits
  modifyRef holdInitRef (HoldInit ref:)


-- | Event propagation
writePropagate ::  Height -> Node a -> a -> EventM ()
writePropagate  height node value = do
  writeNode node value
  propagate height node value



propagate :: forall a. Height -> Node a -> a -> EventM ()
propagate  height node value = traverseSubs propagate' node where

  propagate' :: Subscription a b -> EventM ()
  propagate' (PushSub _ dest f)  = f value >>= traverse_ (writePropagate height dest)
  propagate' (MergeSub m k) = do
    partial <- readRef (mergePartial m)
    writeRef (mergePartial m) $ DMap.insert k value partial
    when (DMap.null partial) $ delayMerge m =<< readHeight (mergeNode m)

  propagate' (HoldSub _ h) =  delayHold h value
  propagate' (SwitchSub s) = writePropagate height (switchNode s) value
  propagate' (CoinInner c) = writePropagate height (coinNode c) value
  propagate' (CoinOuter c) = connectC c value >>= traverse_ (propagate height (coinNode c))



propagateMerge :: Height -> DelayMerge -> EventM ()
propagateMerge height (DelayMerge m) = do
  height' <- readHeight (mergeNode m)
  -- Check if a coincidence has changed the merge height
  case (height == height') of
    False -> delayMerge m height'
    True -> do
      value <- readRef (mergePartial m)
      writeRef (mergePartial m) (DMap.empty)
      writePropagate height (mergeNode m) value



{-# INLINE takeRef #-}
takeRef :: MonadRef m => Ref m [a] -> m [a]
takeRef ref = readRef ref <* writeRef ref []

{-# INLINE askRef #-}
askRef :: (MonadReader r m, MonadRef m) => (r -> Ref m a) -> m a
askRef = asks >=> readRef

askModifyRef :: (MonadReader r m, MonadRef m) => (r -> Ref m a) -> (a -> a) -> m ()
askModifyRef g f = asks g >>= flip modifyRef f

type InvalidateM a = StateT [Connect] IO a

-- Write holds out and invalidate, return switches to connect!
writeHolds :: [WriteHold] -> IO [Connect]
writeHolds writes = execStateT (traverse_ writeHold writes) []


writeHold :: WriteHold -> InvalidateM ()
writeHold (WriteHold h value) = do
  writeRef (holdValue h) value
  takeRef (holdInvs h) >>= invalidate


invalidate :: [Weak Invalidator] -> InvalidateM ()
invalidate = traverse_ (liftIO . deRefWeak >=> traverse_ invalidate') where
  invalidate' (PullInv p) = do
    writeRef (pullValue p) Nothing
    takeRef (pullInvs p) >>= invalidate

  invalidate' (SwitchInv s) = modify (Connect s:)



-- | Propagate changes in height from a coincidence or switch
-- assumes height as maximum over time
propagateHeight :: Height -> Node a -> IO ()
propagateHeight newHeight node = do
  height <- readHeight node
  when (height < newHeight) $ do
    writeRef (nodeHeight node) newHeight
    forSubs node $ \case
      MergeSub (Merge dest _ _)  _ -> propagateHeight (succ newHeight) dest
      sub -> traverseDest (propagateHeight newHeight) sub

traverseDest :: Monad m => (Node b -> m ()) -> Subscription a b -> m ()
traverseDest f (MergeSub  m _)    = f (mergeNode m)
traverseDest f (PushSub  _ node _) = f node
traverseDest f (SwitchSub s)       = f (switchNode s)
traverseDest f (CoinInner c)       = f (coinNode c)
traverseDest f (CoinOuter c)       = f (coinNode c)
traverseDest _ (HoldSub {})        = return ()

maxHeight :: Height -> Height -> Height
maxHeight Invalid _ = Invalid
maxHeight _ Invalid = Invalid
maxHeight h h' = max h h'

maximumHeight :: [Height] -> Height
maximumHeight [] = Invalid
maximumHeight (h:hs) = foldl' maxHeight h hs

isValid :: Height -> Bool
isValid Invalid = False
isValid _       = True

runEventM :: EventM a -> IO (a, Env)
runEventM action = do
  env <- Env <$> newRef mempty <*> newRef [] <*> newRef [] <*> newRef [] <*> newRef []
  (,env) <$> runReaderT (unEventM $ action) env

evalEventM :: EventM a -> IO a
evalEventM = fmap fst . runEventM

execEventM :: EventM a -> IO Env
execEventM = fmap snd . runEventM

runHostFrame :: EventM a -> IO a
runHostFrame action =  evalEventM $ action <* initHolds


-- | Initialize new holds, then check if subscribing new events caused
-- any other new holds to be initialized.
initHolds :: EventM ()
initHolds = do
  newHolds <- takeRef =<< asks envHoldInits
  unless (null newHolds) $ do
    traverse_ initHold newHolds
    initHolds


subscribeEvent :: Event a -> IO (EventHandle a)
subscribeEvent e = evalEventM $ EventHandle <$> eventNode e


takeDelayed :: EventM (Maybe (Height, [DelayMerge]))
takeDelayed = do
  delaysRef <- asks envDelays
  delayed   <- readRef delaysRef

  let view = IntMap.minViewWithKey delayed
  traverse_ (writeRef delaysRef) (snd <$> view)
  return (fst <$> view)


endFrame :: Env -> IO ()
endFrame env  = do
  traverse_ clearNode =<< readRef (envClears env)
  connects <- writeHolds =<< readRef (envHolds env)
  connectSwitches connects =<< readRef (envCoincidences env)

  where
    clearNode (SomeNode node) = writeRef (nodeValue node) Nothing

fireEventsAndRead :: [DSum Trigger] -> EventM a -> IO a
fireEventsAndRead triggers runRead = do
  (a, env) <- runEventM $ do
    traverse_ propagateRoot triggers
    runDelays
    runRead <* initHolds

  a <$ endFrame env

  where
    runDelays = takeDelayed >>= traverse_  (\(height, merges) -> do
        traverse_ (propagateMerge height) merges
        runDelays)

    propagateRoot (Trigger nodeRef :=> a) = do
      node <- readNodeRef nodeRef
      writePropagate 0 node a

fireEvents :: [DSum Trigger] -> IO ()
fireEvents triggers = fireEventsAndRead triggers (return ())


instance Functor Event where
  fmap f e = push (return .   Just . f) e

instance Functor Behavior where
  fmap f b = pull (f <$> sample b)


data Ant

instance R.Reflex Ant where
  newtype Behavior Ant a = AntBehavior { unAntBehavior :: Behavior a }
  newtype Event Ant a = AntEvent { unAntEvent :: Event a }
  type PullM Ant = BehaviorM
  type PushM Ant = EventM
  {-# INLINE never #-}
  {-# INLINE constant #-}
  never = AntEvent never
  constant = AntBehavior . constant
  push f = AntEvent. push f . unAntEvent
  pull = AntBehavior . pull
  merge = AntEvent . merge . (unsafeCoerce :: DMap (WrapArg (R.Event Ant) k) -> DMap (WrapArg Event k))
  fan e = error "not implemented" --R.EventSelector $ AntEvent . select (fan (unAntEvent e))
  switch = AntEvent . switch . (unsafeCoerce :: Behavior (R.Event Ant a) -> Behavior (Event a)) . unAntBehavior
  coincidence = AntEvent . coincidence . (unsafeCoerce :: Event (R.Event Ant a) -> Event (Event a)) . unAntEvent


--HostFrame instances
instance R.MonadSubscribeEvent Ant EventM where
  subscribeEvent (AntEvent e) = liftIO $ subscribeEvent e

instance R.MonadReflexCreateTrigger Ant EventM where
  newEventWithTrigger      = undefined
  newFanEventWithTrigger f = undefined


instance R.MonadSample Ant BehaviorM where
  sample (AntBehavior b) = sample b

instance R.MonadSample Ant EventM where
  sample (AntBehavior b) = sampleE b

instance R.MonadHold Ant EventM where
  hold a (AntEvent e) = AntBehavior <$> hold a e


newtype AntHost a = AntHost { runAntHost :: IO a } deriving (Functor, Applicative, Monad, MonadFix, MonadIO)

--Host instances
instance R.MonadReflexCreateTrigger Ant AntHost where
  newEventWithTrigger      = undefined
  newFanEventWithTrigger f = undefined


instance R.MonadSubscribeEvent Ant AntHost where
  subscribeEvent (AntEvent e) = liftIO $ subscribeEvent e

instance R.MonadReadEvent Ant EventM where
  {-# INLINE readEvent #-}
  readEvent h = fmap return <$> liftIO (readEvent h)

instance R.MonadReflexHost Ant AntHost where
  type ReadPhase AntHost = EventM

  fireEventsAndRead es = liftIO . fireEventsAndRead es
  runHostFrame = liftIO . runHostFrame

instance R.MonadSample Ant AntHost where
  sample (AntBehavior b) = liftIO (sampleIO b)


instance R.ReflexHost Ant where
  type EventTrigger Ant = Trigger
  type EventHandle Ant = EventHandle
  type HostFrame Ant = EventM




-- DMap utilities
catEvents ::  [DSum (WrapArg Event k)] -> [DSum (WrapArg NodeRef k)]
catEvents events = [(WrapArg k) :=> ref | (WrapArg k) :=> Event ref <- events]

traverseDSums :: Applicative m => (forall a. f a -> m (g a)) -> [DSum (WrapArg f k)] -> m [DSum (WrapArg g k)]
traverseDSums f = traverse (\(WrapArg k :=> v) -> (WrapArg k :=>) <$> f v)

mapDSums :: (forall a. f a -> b) -> [DSum (WrapArg f k)] -> [b]
mapDSums f = map (\(WrapArg _ :=> v) -> f v)


mapDMap :: (forall a. f a -> b) -> DMap (WrapArg f k) -> [b]
mapDMap f = mapDSums f . DMap.toList


catDSums :: [DSum (WrapArg Maybe k)] -> [DSum k]
catDSums = catMaybes . map toMaybe

toMaybe :: DSum (WrapArg Maybe k)  -> Maybe (DSum k)
toMaybe (WrapArg k :=> Just v ) = Just (k :=> v)
toMaybe _ = Nothing

fromAsc :: [DSum k] -> DMap k
fromAsc = DMap.fromDistinctAscList
