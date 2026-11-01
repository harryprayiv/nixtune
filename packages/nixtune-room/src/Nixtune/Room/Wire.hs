-- | The coordinator's line protocol, as the Coordinator contract in
-- nixtune-multiroom.allium describes it: one request per line, one reply
-- per line, plus pushed status lines for subscribers.
--
-- > follow lab               ok | refused <reason>
-- > own | silence            ok | refused <reason>
-- > hold <room>              ok | refused <reason>
-- > release <room>           ok
-- > suspend <room>           ok | refused <reason>
-- > pin <room> | unpin       ok | refused <reason>
-- > interruption-starts <by> ok | refused <reason>
-- > interruption-ends <by>   ok
-- > status                   status room=... intent=... ...
-- > subscribe                status ... now, then one per change
--
-- Every token is a room name, a fixed word, or a comma-separated list of
-- room names, so a line never needs quoting.
module Nixtune.Room.Wire
  ( Command (..)
  , parseCommand
  , renderCommand
  , renderRequest
  , renderReply
  , parseReply
  , WireStatus (..)
  , renderStatus
  , parseStatus
  , refusalWord
  , interrupterWord
  )
where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Nixtune.Room.Name (RoomName, mkRoomName, roomNameText)
import Nixtune.Room.Protocol (Interrupter (..), Refusal (..), Request (..))

data Command
  = CmdRequest Request
  | CmdStatus
  | CmdSubscribe
  | -- | From this room's player, on the control socket only: True when it
    -- is about to open the DAC, False once it has closed it.
    CmdPlayerOutput Bool
  deriving stock (Eq, Show)

-- | A room's status as it travels: what pages draw and what a follower's
-- reconcile reads ('PeerView' is built from it).
data WireStatus = WireStatus
  { wsRoom :: RoomName
  , wsIntent :: Text
  -- ^ own, following or silent
  , wsSource :: Maybe RoomName
  , wsAudience :: Set RoomName
  , wsSuspended :: Set RoomName
  , wsMovedTo :: Maybe RoomName
  , wsPath :: Text
  -- ^ direct, own-server, peer-server, off or interrupted
  , wsInterruptedBy :: Maybe Interrupter
  , wsFocus :: Maybe RoomName
  }
  deriving stock (Eq, Show)

interrupterWord :: Interrupter -> Text
interrupterWord = \case
  AirPlay -> "airplay"
  Upnp -> "upnp"
  ForeignSendspin -> "foreign-sendspin"

refusalWord :: Refusal -> Text
refusalWord = \case
  UnknownRoom -> "unknown-room"
  IsSelf -> "self"
  RoomInterrupted -> "interrupted"
  Busy -> "busy"
  PlayerNotReady -> "player-not-ready"
  SourceUnreachable -> "source-unreachable"

inverse :: (Enum a, Bounded a) => (a -> Text) -> Text -> Maybe a
inverse f w = find ((== w) . f) [minBound .. maxBound]

parseCommand :: Text -> Either Text Command
parseCommand line = case Text.words line of
  ["status"] -> Right CmdStatus
  ["subscribe"] -> Right CmdSubscribe
  ["own"] -> req ReqOwn
  ["silence"] -> req ReqSilence
  ["unpin"] -> req ReqUnpin
  ["follow", r] -> req . ReqFollow =<< room r
  ["hold", r] -> req . ReqHold =<< room r
  ["release", r] -> req . ReqRelease =<< room r
  ["suspend", r] -> req . ReqSuspend =<< room r
  ["pin", r] -> req . ReqPin =<< room r
  ["interruption-starts", w] -> req . ReqInterruptionStarts =<< interrupter w
  ["interruption-ends", w] -> req . ReqInterruptionEnds =<< interrupter w
  ["player-output", "opening"] -> Right (CmdPlayerOutput True)
  ["player-output", "closed"] -> Right (CmdPlayerOutput False)
  _ -> Left ("unknown command: " <> Text.take 80 line)
  where
    req = Right . CmdRequest
    room r = maybe (Left ("bad room name: " <> Text.take 40 r)) Right (mkRoomName r)
    interrupter w = maybe (Left ("unknown interrupter: " <> Text.take 40 w)) Right (inverse interrupterWord w)

renderRequest :: Request -> Text
renderRequest = \case
  ReqFollow r -> "follow " <> roomNameText r
  ReqOwn -> "own"
  ReqSilence -> "silence"
  ReqHold r -> "hold " <> roomNameText r
  ReqRelease r -> "release " <> roomNameText r
  ReqSuspend r -> "suspend " <> roomNameText r
  ReqPin r -> "pin " <> roomNameText r
  ReqUnpin -> "unpin"
  ReqInterruptionStarts w -> "interruption-starts " <> interrupterWord w
  ReqInterruptionEnds w -> "interruption-ends " <> interrupterWord w

renderCommand :: Command -> Text
renderCommand = \case
  CmdRequest r -> renderRequest r
  CmdStatus -> "status"
  CmdSubscribe -> "subscribe"
  CmdPlayerOutput True -> "player-output opening"
  CmdPlayerOutput False -> "player-output closed"

renderReply :: Either Refusal () -> Text
renderReply = \case
  Right () -> "ok"
  Left why -> "refused " <> refusalWord why

parseReply :: Text -> Either Text (Either Refusal ())
parseReply line = case Text.words line of
  ["ok"] -> Right (Right ())
  ["refused", w] -> maybe (Left ("unknown refusal: " <> w)) (Right . Left) (inverse refusalWord w)
  _ -> Left ("not a reply: " <> Text.take 80 line)

renderStatus :: WireStatus -> Text
renderStatus s =
  Text.unwords
    [ "status"
    , "room=" <> roomNameText (wsRoom s)
    , "intent=" <> wsIntent s
    , "source=" <> one (wsSource s)
    , "audience=" <> many (wsAudience s)
    , "suspended=" <> many (wsSuspended s)
    , "moved-to=" <> one (wsMovedTo s)
    , "path=" <> wsPath s
    , "interrupted-by=" <> maybe "-" interrupterWord (wsInterruptedBy s)
    , "focus=" <> one (wsFocus s)
    ]
  where
    one = maybe "-" roomNameText
    many xs
      | Set.null xs = "-"
      | otherwise = Text.intercalate "," (map roomNameText (Set.toAscList xs))

parseStatus :: Text -> Either Text WireStatus
parseStatus line = case Text.words line of
  ("status" : fields) -> do
    kv <- Map.fromList <$> traverse field fields
    let get k = maybe (Left ("status without " <> k)) Right (Map.lookup k kv)
    wsRoom <- room =<< get "room"
    wsIntent <- word ["own", "following", "silent"] =<< get "intent"
    wsSource <- optional room =<< get "source"
    wsAudience <- rooms =<< get "audience"
    wsSuspended <- rooms =<< get "suspended"
    wsMovedTo <- optional room =<< get "moved-to"
    wsPath <- word ["direct", "own-server", "peer-server", "off", "interrupted"] =<< get "path"
    wsInterruptedBy <- optional interrupter =<< get "interrupted-by"
    wsFocus <- optional room =<< get "focus"
    pure WireStatus {..}
  _ -> Left ("not a status line: " <> Text.take 80 line)
  where
    field f = case Text.breakOn "=" f of
      (k, v) | not (Text.null v) -> Right (k, Text.drop 1 v)
      _ -> Left ("bad field: " <> Text.take 40 f)
    room r = maybe (Left ("bad room name: " <> Text.take 40 r)) Right (mkRoomName r)
    optional p v = if v == "-" then Right Nothing else Just <$> p v
    rooms v
      | v == "-" = Right Set.empty
      | otherwise = Set.fromList <$> traverse room (Text.splitOn "," v)
    word ws v = if v `elem` ws then Right v else Left ("unexpected value: " <> v)
    interrupter w = maybe (Left ("unknown interrupter: " <> w)) Right (inverse interrupterWord w)