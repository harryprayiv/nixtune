-- | The arithmetic of the audio stream, kept pure: which PCM format a
-- player gets, packing MPD's samples for it, when each chunk plays, the
-- group's send-ahead, and the player's buffer accounting.
--
-- Times are microseconds on the server's monotonic clock.
module Nixtune.Sendspin.Audio
  ( StreamFormat (..)
  , parseStreamFormat
  , inputFrameBytes
  , chunkFrames
  , choosePcm
  , pack
  , framesDuration
  , Timeline (..)
  , timelineEnd
  , stamp
  , sendAhead
  , minimumSendAhead
  , Outstanding
  , noOutstanding
  , admit
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Internal qualified as Internal
import Data.ByteString.Unsafe (unsafeIndex)
import Data.Foldable (find)
import Data.Int (Int64)
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (poke)
import Nixtune.Sendspin.Message (PcmFormat (..), SupportedFormat (..))
import Text.Read (readMaybe)

-- | What MPD's multiroom output writes: multiroom.streamFormat.
data StreamFormat = StreamFormat
  { sRate :: Int
  , sBits :: Int
  , sChannels :: Int
  }
  deriving stock (Eq, Show)

-- | "44100:24:2", as MPD and the module option write it. Only what every
-- Sendspin player must accept: 44.1 or 48 kHz, 16 or 24 bits, 1 or 2
-- channels.
parseStreamFormat :: Text -> Either String StreamFormat
parseStreamFormat t = case traverse (readMaybe . Text.unpack) (Text.splitOn ":" t) of
  Just [r, b, c]
    | r `elem` [44100, 48000], b `elem` [16, 24], c `elem` [1, 2] -> Right (StreamFormat r b c)
  _ -> Left ("stream format must be rate:bits:channels with rate 44100 or 48000, bits 16 or 24, channels 1 or 2: " <> Text.unpack t)

-- | MPD writes 24-bit samples in 32-bit containers and 16-bit samples
-- in 16 bits, little-endian.
inputFrameBytes :: StreamFormat -> Int
inputFrameBytes f = sChannels f * (if sBits f == 24 then 4 else 2)

-- | 20 ms of frames.
chunkFrames :: StreamFormat -> Int
chunkFrames f = sRate f `div` 50

-- | The player's PCM entry at the stream's rate and channels: at the
-- stream's depth when listed, else at 16 bits, which every player that
-- lists PCM at all must take. Nothing when it lists neither.
choosePcm :: StreamFormat -> [SupportedFormat] -> Maybe PcmFormat
choosePcm f formats =
  find (== wanted (sBits f)) pcm `orElse` find (== wanted 16) pcm
  where
    pcm = [sfFormat s | s <- formats, sfCodec s == "pcm"]
    wanted b = PcmFormat (sRate f) b (sChannels f)
    orElse (Just a) _ = Just a
    orElse Nothing b = b

-- | MPD's samples, little-endian, packed for the player: 24 bits in 3
-- bytes, or the top 16 bits of a 24-bit sample. The input is whole
-- frames.
pack :: StreamFormat -> PcmFormat -> ByteString -> ByteString
pack f out input = case (sBits f, pcmBits out) of
  (24, 24) -> repack 4 [0, 1, 2]
  (24, _) -> repack 4 [1, 2]
  _ -> input
  where
    samples = ByteString.length input `div` 4
    repack width keep =
      let k = length keep
       in Internal.unsafeCreate (samples * k) $ \dst ->
            let go i
                  | i >= samples = pure ()
                  | otherwise = do
                      write dst (i * k) [unsafeIndex input (i * width + j) | j <- keep]
                      go (i + 1)
             in go 0
    write :: Ptr Word8 -> Int -> [Word8] -> IO ()
    write dst at bytes = sequence_ [poke (dst `plusPtr` (at + n)) b | (n, b) <- zip [0 ..] bytes]

framesDuration :: Int -> Int64 -> Int64
framesDuration rate n = n * 1000000 `div` fromIntegral rate

-- | Where the stream is: the time its first sample since the last
-- (re)start plays, and how many frames have been stamped since.
-- Timestamps come from the frame count, so they never drift from the
-- sample clock.
data Timeline = Timeline
  { tlBase :: Int64
  , tlFrames :: Int64
  }
  deriving stock (Eq, Show)

timelineEnd :: Int -> Timeline -> Int64
timelineEnd rate t = tlBase t + framesDuration rate (tlFrames t)

-- | The timestamp of the next chunk of n frames, and the timeline after
-- it. The stream restarts at now + send-ahead when there is none, and
-- when the next timestamp has fallen too far behind that: after MPD
-- stopped writing for a while, or when the send-ahead has grown. A
-- restart only ever moves the timeline later, so no audio overlaps.
stamp :: Int -> Int64 -> Int64 -> Int64 -> Maybe Timeline -> (Int64, Timeline)
stamp rate ahead now n current = (ts, t {tlFrames = tlFrames t + n})
  where
    fresh = Timeline (now + ahead) 0
    slack = min 50000 (ahead `div` 2)
    t = case current of
      Just c | timelineEnd rate c >= now + ahead - slack -> c
      _ -> fresh
    ts = timelineEnd rate t

-- | Never less than this, so a player reporting no buffer still gets the
-- chunk before its time.
minimumSendAhead :: Int64
minimumSendAhead = 100000

-- | The group's send-ahead: the largest min_buffer_ms plus
-- output_delay_ms among the players streaming.
sendAhead :: [(Int64, Int64)] -> Int64
sendAhead timings = maximum (minimumSendAhead : [(minBuf + delay) * 1000 | (minBuf, delay) <- timings])

-- | Chunks sent and not yet finished playing: completion time and size.
newtype Outstanding = Outstanding (Seq (Int64, Int))

noOutstanding :: Outstanding
noOutstanding = Outstanding Seq.empty

-- | Player Buffer Accounting: whether a chunk of this size, finishing at
-- this time, fits under the player's capacity now.
admit :: Int -> Int64 -> Int -> Int64 -> Outstanding -> Maybe Outstanding
admit capacity now size completion (Outstanding s0)
  | total + size > capacity = Nothing
  | otherwise = Just (Outstanding (s |> (completion, size)))
  where
    s = dropDone s0
    total = sum (fmap snd s)
    dropDone q = case viewl q of
      (c, _) :< rest | c <= now -> dropDone rest
      _ -> q
