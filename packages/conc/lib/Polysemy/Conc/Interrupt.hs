{-# options_haddock prune #-}
-- |Description: Interrupt interpreters
module Polysemy.Conc.Interrupt where

import qualified Control.Concurrent.Async as A
import Control.Concurrent.Async (AsyncCancelled)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text.IO as Text
import Polysemy (getInspectorT, inspect, interpretH, runT)
import Polysemy.Async (Async, async, await, cancel)
import Polysemy.Internal.Tactics (liftT)
import Polysemy.Time (Seconds (Seconds))
import System.Posix.Signals (Handler (CatchInfoOnce, CatchOnce), SignalInfo, installHandler, keyboardSignal)

import qualified Polysemy.Conc.Data.Critical as Critical
import Polysemy.Conc.Data.Critical (Critical)
import Polysemy.Conc.Data.Interrupt (Interrupt (..))
import Polysemy.Conc.Data.Race (Race)
import qualified Polysemy.Conc.Effect.Sync as Sync
import Polysemy.Conc.Interpreter.Sync (interpretSync)
import Polysemy.Conc.Race (race_)

putErr ::
  Member (Embed IO) r =>
  Text ->
  Sem r ()
putErr =
  embed . Text.hPutStrLn stderr

data InterruptState =
  InterruptState {
    quit :: !(MVar ()),
    finished :: !(MVar ()),
    listeners :: !(Set Text),
    original :: !(SignalInfo -> IO ()),
    handlers :: !(Map Text (IO ()))
  }

modListeners :: (Set Text -> Set Text) -> InterruptState -> InterruptState
modListeners f s@InterruptState {listeners} =
  s {listeners = f listeners}

modHandlers :: (Map Text (IO ()) -> Map Text (IO ())) -> InterruptState -> InterruptState
modHandlers f s@InterruptState {handlers} =
  s {handlers = f handlers}

waitQuit ::
  Members [AtomicState InterruptState, Embed IO] r =>
  Sem r ()
waitQuit = do
  mv <- atomicGets quit
  readMVar mv

checkListeners ::
  Members [AtomicState InterruptState, Embed IO] r =>
  Sem r ()
checkListeners =
  whenM (atomicGets (Set.null . listeners)) do
    fin <- atomicGets finished
    void (tryPutMVar fin ())

onQuit ::
  Members [AtomicState InterruptState, Embed IO] r =>
  Text ->
  Sem r a ->
  Sem r a
onQuit name ma = do
  atomicModify' (modListeners (Set.insert name))
  waitQuit
  a <- ma
  atomicModify' (modListeners (Set.delete name))
  checkListeners
  pure a

processHandler ::
  Member (Embed IO) r =>
  Text ->
  IO () ->
  Sem r ()
processHandler name thunk = do
  putErr [qt|processing interrupt handler: #{name}|]
  embed thunk

execInterrupt ::
  Members [AtomicState InterruptState, Embed IO] r =>
  Sem r (SignalInfo -> Sem r ())
execInterrupt = do
  InterruptState quitSignal finishSignal _ orig _ <- atomicGet
  whenM (tryPutMVar quitSignal ()) do
    traverse_ (uncurry processHandler) . Map.toList =<< atomicGets handlers
    checkListeners
    takeMVar finishSignal
  embed . orig <$ putErr "interrupt handlers finished"

registerHandler ::
  Member (AtomicState InterruptState) r =>
  Text ->
  IO () ->
  Sem r ()
registerHandler name handler =
  atomicModify' (modHandlers (Map.insert name handler))

awaitOrKill ::
  Members [AtomicState InterruptState, Critical, Race, Async, Embed IO] r =>
  Text ->
  A.Async (Maybe a) ->
  Sem r (Maybe a)
awaitOrKill desc handle = do
  interpretSync @() do
    race_ (catchCritical (await handle)) kill
  where
    catchCritical =
      maybe waitKill (pure . Just) <=< Critical.catchAs @AsyncCancelled Nothing
    waitKill =
      Nothing <$ Sync.wait @() (Seconds 1)
    kill = do
      onQuit desc do
        putErr [qt|killing #{desc}|]
        cancel handle
        putErr [qt|killed #{desc}|]
        Sync.putBlock ()
        pure Nothing

interpretInterruptState ::
  Members [AtomicState InterruptState, Critical, Race, Async, Embed IO] r =>
  InterpreterFor Interrupt r
interpretInterruptState =
  interpretH \case
    Register name handler ->
      liftT (registerHandler name handler)
    Unregister name ->
      liftT $ atomicModify' \ s@InterruptState {handlers} -> s {handlers = Map.delete name handlers}
    WaitQuit ->
      liftT waitQuit
    Quit ->
      liftT do
        putErr "manual interrupt"
        void execInterrupt
    Interrupted ->
      liftT . fmap isJust . tryReadMVar =<< atomicGets quit
    KillOnQuit desc ma -> do
      maT <- runT ma
      ins <- getInspectorT
      handle <- raise (interpretInterruptState (async maT))
      result <- liftT (awaitOrKill desc handle)
      pure (join . fmap (inspect ins) <$> result)
{-# INLINE interpretInterruptState #-}

broadcastInterrupt ::
  Members [AtomicState InterruptState, Embed IO] r =>
  SignalInfo ->
  Sem r ()
broadcastInterrupt sig = do
  putErr "caught interrupt signal"
  orig <- execInterrupt
  orig sig

-- The original handler is either the default handler that kills all threads or a handler installed by an environment
-- like ghcid.
-- In the latter case, not calling it results in ghcid misbehaving.
-- To distinguish the two cases, the constructor used by the default is 'Catch', while a custom handler should usually
-- use 'CatchOnce', since you don't want to catch repeated occurences of SIGINT, as it will surely cause problems.
originalHandler :: Handler -> (SignalInfo -> IO ())
originalHandler (CatchOnce thunk) =
  (const thunk)
originalHandler (CatchInfoOnce thunk) =
  thunk
originalHandler _ =
  const pass
{-# INLINE originalHandler #-}

installSignalHandler ::
  TVar InterruptState ->
  IO Handler
installSignalHandler state =
  installHandler keyboardSignal (CatchInfoOnce handler) Nothing
  where
    handler sig =
      runFinal $ embedToFinal @IO $ runAtomicStateTVar state (broadcastInterrupt sig)

-- |Interpret 'Interrupt' by installing a signal handler.
interpretInterrupt ::
  Members [Critical, Race, Async, Embed IO] r =>
  InterpreterFor Interrupt r
interpretInterrupt sem = do
  quitMVar <- newEmptyMVar
  finishMVar <- newEmptyMVar
  state <- newTVarIO (InterruptState quitMVar finishMVar Set.empty (const pass) Map.empty)
  orig <- embed $ installSignalHandler state
  runAtomicStateTVar state do
    atomicModify' \ s -> s {original = originalHandler orig}
    interpretInterruptState $ raiseUnder sem
{-# INLINE interpretInterrupt #-}
