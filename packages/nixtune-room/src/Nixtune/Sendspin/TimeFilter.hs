-- | The Sendspin time filter, exactly as the spec's "Clock
-- Synchronization" section defines it: a two-dimensional Kalman filter
-- over the offset between the server's clock and the client's, and its
-- drift. All times are microseconds; state is kept in Double.
--
-- The server answers the exchanges; this module is what a player (or a
-- test of the server) runs on them.
module Nixtune.Sendspin.TimeFilter
  ( Params (..)
  , defaultParams
  , Exchange (..)
  , TimeFilter (..)
  , emptyFilter
  , measure
  , update
  , computeServerTime
  , computeClientTime
  , roundHalfAway
  )
where

import Data.Int (Int64)

-- | The spec's recommended values are 'defaultParams'.
data Params = Params
  { processStdDev :: Double
  , driftProcessStdDev :: Double
  , forgetFactor :: Double
  , adaptiveCutoff :: Double
  , minSamples :: Int
  , driftSignificanceThreshold :: Double
  , maxErrorScale :: Double
  }
  deriving stock (Eq, Show)

defaultParams :: Params
defaultParams =
  Params
    { processStdDev = 0.0
    , driftProcessStdDev = 1e-11
    , forgetFactor = 2.0
    , adaptiveCutoff = 3.0
    , minSamples = 100
    , driftSignificanceThreshold = 2.0
    , maxErrorScale = 0.5
    }

-- | One client/time and server/time exchange: T1 client transmitted, T2
-- server received, T3 server transmitted, T4 client received.
data Exchange = Exchange
  { clientTransmitted :: Int64
  , serverReceived :: Int64
  , serverTransmitted :: Int64
  , clientReceived :: Int64
  }
  deriving stock (Eq, Show)

data TimeFilter = TimeFilter
  { offset :: Double
  , drift :: Double
  , pOO :: Double
  , pOD :: Double
  , pDD :: Double
  , lastUpdate :: Int64
  , count :: Int
  , useDrift :: Bool
  }
  deriving stock (Eq, Show)

-- | P_oo at infinity, use_drift false, everything else 0.
emptyFilter :: TimeFilter
emptyFilter =
  TimeFilter
    { offset = 0
    , drift = 0
    , pOO = 1 / 0
    , pOD = 0
    , pDD = 0
    , lastUpdate = 0
    , count = 0
    , useDrift = False
    }

-- | measurement, max_error and time_added for one exchange. Division is
-- integer division truncating toward zero, as the spec says.
measure :: Exchange -> (Int64, Int64, Int64)
measure (Exchange t1 t2 t3 t4) =
  ( ((t2 - t1) + (t3 - t4)) `quot` 2
  , ((t4 - t1) - (t3 - t2)) `quot` 2
  , t4
  )

update :: Params -> Exchange -> TimeFilter -> TimeFilter
update ps ex tf
  | timeAdded <= lastUpdate tf || maxError <= 0 = tf
  | otherwise = case count tf of
      0 ->
        tf' {offset = m, pOO = r, drift = 0, count = 1}
      1 ->
        tf'
          { drift = (m - offset tf) / dt
          , pDD = (pOO tf + r) / (dt * dt)
          , offset = m
          , pOO = r
          , count = 2
          }
      _ ->
        let offsetP = offset tf + drift tf * dt
            pOOp0 =
              pOO tf + 2 * pOD tf * dt + pDD tf * dt * dt + processStdDev ps ^ (2 :: Int) * dt
            pODp0 = pOD tf + pDD tf * dt
            pDDp0 = pDD tf + driftProcessStdDev ps ^ (2 :: Int) * dt
            y = m - offsetP
            (count', scale)
              | count tf < minSamples ps = (count tf + 1, 1)
              | abs y > adaptiveCutoff ps * fromIntegral maxError =
                  (count tf, forgetFactor ps ^ (2 :: Int))
              | otherwise = (count tf, 1)
            pOOp = pOOp0 * scale
            pODp = pODp0 * scale
            pDDp = pDDp0 * scale
            s = pOOp + r
            kO = pOOp / s
            kD = pODp / s
            drift' = drift tf + kD * y
            pDD' = pDDp - kD * pODp
         in tf'
              { offset = offsetP + kO * y
              , drift = drift'
              , pOO = pOOp - kO * pOOp
              , pOD = pODp - kD * pOOp
              , pDD = pDD'
              , count = count'
              , useDrift = drift' * drift' > driftSignificanceThreshold ps ^ (2 :: Int) * pDD'
              }
  where
    (mI, maxError, timeAdded) = measure ex
    m = fromIntegral mI
    dt = fromIntegral (timeAdded - lastUpdate tf)
    r = (maxErrorScale ps * fromIntegral maxError) ^ (2 :: Int)
    tf' = tf {lastUpdate = timeAdded}

-- | Round to nearest, halves away from zero.
roundHalfAway :: Double -> Int64
roundHalfAway x
  | x < 0 = negate (floor (negate x + 0.5))
  | otherwise = floor (x + 0.5)

effectiveDrift :: TimeFilter -> Double
effectiveDrift tf = if useDrift tf then drift tf else 0

computeServerTime :: TimeFilter -> Int64 -> Int64
computeServerTime tf tClient =
  tClient
    + roundHalfAway (offset tf + effectiveDrift tf * fromIntegral (tClient - lastUpdate tf))

computeClientTime :: TimeFilter -> Int64 -> Int64
computeClientTime tf tServer =
  roundHalfAway
    ((fromIntegral tServer - offset tf + d * fromIntegral (lastUpdate tf)) / (1 + d))
  where
    d = effectiveDrift tf
