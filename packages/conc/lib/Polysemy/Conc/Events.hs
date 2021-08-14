-- |Description: Events Combinators
module Polysemy.Conc.Events where

import Polysemy.Conc.Interpreter.Events (EventConsumer)
import qualified Polysemy.Conc.Effect.Events as Events

-- |Pull repeatedly from the 'Events' channel, passing the event to the supplied callback.
-- Stop when the action returns @False@.
subscribeWhile ::
  ∀ e token r .
  Member (EventConsumer token e) r =>
  (e -> Sem r Bool) ->
  Sem r ()
subscribeWhile action =
  Events.subscribe @e @token spin
  where
    spin =
      whenM (raise . action =<< Events.consume) spin

-- |Pull repeatedly from the 'Events' channel, passing the event to the supplied callback.
subscribeLoop ::
  ∀ e token r .
  Member (EventConsumer token e) r =>
  (e -> Sem r ()) ->
  Sem r ()
subscribeLoop action =
  Events.subscribe @e @token (forever (raise . action =<< Events.consume))
