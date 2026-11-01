-- | Time as the coordinator sees it: a monotonic instant in microseconds,
-- and durations between instants. Delays sent to players are whole
-- milliseconds, which is what Sendspin's output_delay_ms carries.
module Nixtune.Room.Clock
  ( Instant (..)
  , Duration (..)
  , Millis (..)
  , after
  , elapsedSince
  , milliseconds
  , seconds
  , minutes
  )
where

import Data.Int (Int64)

-- | CLOCK_MONOTONIC in microseconds.
newtype Instant = Instant Int64
  deriving stock (Eq, Ord, Show)

newtype Duration = Duration Int64
  deriving stock (Eq, Ord, Show)

newtype Millis = Millis Int
  deriving stock (Eq, Ord, Show)

after :: Duration -> Instant -> Instant
after (Duration d) (Instant t) = Instant (t + d)

-- | How long ago the first instant was, seen from the second.
elapsedSince :: Instant -> Instant -> Duration
elapsedSince (Instant earlier) (Instant now) = Duration (now - earlier)

milliseconds :: Int64 -> Duration
milliseconds n = Duration (n * 1000)

seconds :: Int64 -> Duration
seconds n = Duration (n * 1000000)

minutes :: Int64 -> Duration
minutes n = seconds (n * 60)
