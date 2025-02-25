{-# options_haddock prune #-}
-- |Description: Monitor Implementations, Internal
module Polysemy.Conc.Monitor where

import Data.Default (Default (def))
import qualified Polysemy.Time as Time
import Polysemy.Time (Minutes (Minutes), NanoSeconds, Seconds (Seconds), Time, TimeUnit, convert)
import Torsor (Torsor, difference, minus)

import Polysemy.Conc.Effect.Monitor (MonitorCheck (MonitorCheck))

-- |Config for 'monitorClockSkew'.
data ClockSkewConfig =
  ClockSkewConfig {
    interval :: NanoSeconds,
    tolerance :: NanoSeconds
  }
  deriving (Eq, Show)

-- |Smart constructor for 'ClockSkewConfig' that takes arbitrary 'TimeUnit's.
clockSkewConfig ::
  TimeUnit u1 =>
  TimeUnit u2 =>
  u1 ->
  u2 ->
  ClockSkewConfig
clockSkewConfig i t =
  ClockSkewConfig (convert i) (convert t)

instance Default ClockSkewConfig where
  def =
    clockSkewConfig (Minutes 1) (Seconds 5)

-- |Check for 'Polysemy.Conc.Effect.Monitor' that checks every @interval@ whether the difference between the current
-- time and the time at the last check is larger than @interval@ + @tolerance@.
-- Can be used to detect that the operating system suspended and resumed.
monitorClockSkew ::
  ∀ t d diff r .
  Torsor t diff =>
  TimeUnit diff =>
  Members [AtomicState (Maybe t), Time t d, Embed IO] r =>
  ClockSkewConfig ->
  MonitorCheck r
monitorClockSkew (ClockSkewConfig interval tolerance) =
  MonitorCheck interval \ signal -> do
    atomicGet >>= \case
      Just prev -> do
        now <- Time.now @t @d
        when (minus (convert (difference now prev)) tolerance > interval) (void (embed @IO (tryPutMVar signal ())))
        atomicPut (Just now)
      Nothing -> do
        now <- Time.now @t @d
        atomicPut (Just now)
