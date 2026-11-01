-- | Catching failures without catching cancellation. A handler for
-- SomeException also catches the asynchronous exception that cancels a
-- thread, and a thread that swallows its own cancellation never stops;
-- these rethrow anything asynchronous.
module Nixtune.Room.Sync
  ( trySync
  , catchSync
  , describe
  )
where

import Control.Exception (SomeAsyncException, SomeException (..), displayException, fromException, throwIO, try)

trySync :: IO a -> IO (Either SomeException a)
trySync act = do
  r <- try act
  case r of
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    _ -> pure r

catchSync :: IO a -> (SomeException -> IO a) -> IO a
catchSync act handler = trySync act >>= either handler pure

-- | What went wrong, in one line for the log. From GHC 9.10,
-- displayException on a SomeException appends the backtrace collected
-- when it was thrown; the inner exception's own text is the part a
-- reader of the log needs.
describe :: SomeException -> String
describe (SomeException e) = displayException e