{-# options_haddock prune #-}
-- |Description: Sync effect
module Polysemy.Conc.Effect.Sync where

import Polysemy.Time (TimeUnit)
import Polysemy.Conc.Effect.Scoped (Scoped)

-- |Abstracts an 'MVar'.
--
-- For documentation on the constructors, see the module "Polysemy.Conc.Effect.Sync".
--
-- @
-- import Polysemy.Conc (Sync)
-- import qualified Polysemy.Conc.Effect.Sync as Sync
--
-- prog :: Member (Sync Int) r => Sem r Int
-- prog = do
--   Sync.putTry 5
--   Sync.takeBlock
-- @
data Sync d :: Effect where
  -- |Read the variable, waiting until a value is available.
  Block :: Sync d m d
  -- |Read the variable, waiting until a value is available or the timeout has expired.
  Wait :: TimeUnit u => u -> Sync d m (Maybe d)
  -- |Read the variable, returning 'Nothing' immmediately if no value was available.
  Try :: Sync d m (Maybe d)
  -- |Take the variable, waiting until a value is available.
  TakeBlock :: Sync d m d
  -- |Take the variable, waiting until a value is available or the timeout has expired.
  TakeWait :: TimeUnit u => u -> Sync d m (Maybe d)
  -- |Take the variable, returning 'Nothing' immmediately if no value was available.
  TakeTry :: Sync d m (Maybe d)
  -- |Read the variable, waiting until a value is available.
  ReadBlock :: Sync d m d
  -- |Read the variable, waiting until a value is available or the timeout has expired.
  ReadWait :: TimeUnit u => u -> Sync d m (Maybe d)
  -- |Read the variable, returning 'Nothing' immmediately if no value was available.
  ReadTry :: Sync d m (Maybe d)
  -- |Write the variable, waiting until it is writable.
  PutBlock :: d -> Sync d m ()
  -- |Write the variable, waiting until it is writable or the timeout has expired.
  PutWait :: TimeUnit u => u -> d -> Sync d m Bool
  -- |Write the variable, returning 'False' immmediately if no value was available.
  PutTry :: d -> Sync d m Bool
  -- |Indicate whether the variable is empty.
  Empty :: Sync d m Bool

makeSem ''Sync

newtype SyncResources a =
  SyncResources { unSyncResources :: a }

-- |Convenience alias.
type ScopedSync res a =
  Scoped (SyncResources res) (Sync a)
