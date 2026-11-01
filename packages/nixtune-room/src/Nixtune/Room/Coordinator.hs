-- | The coordinator as a pure state machine: one event in, the next state
-- and the effects out. The shell (a later stage) turns requests, Sendspin
-- server events, MPD's idle events, peer probes and a clock tick into
-- 'Event's, and carries out the 'Effect's in order, waiting for each.
--
-- Rule names in the comments are those of nixtune-multiroom.allium.
-- Stage 1 covers the requests a room makes about itself, a source's
-- audience, reconciliation and orphaning, interruptions, and the focus.
-- MOVE and the shared library come in a later stage.
module Nixtune.Room.Coordinator
  ( Config (..)
  , PeerView (..)
  , Event (..)
  , Effect (..)
  , step
  , focusMembers
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Nixtune.Room.Clock (Duration, Instant, Millis, after)
import Nixtune.Room.Focus (Acoustics, alignedDelays, chooseFocus)
import Nixtune.Room.Name (RoomName)
import Nixtune.Room.Outputs (Action (..), plan)
import Nixtune.Room.Protocol (Interrupter, Refusal (..), ReplyTo, Request (..))
import Nixtune.Room.State

data Config = Config
  { peers :: Map RoomName Millis
  -- ^ Every declared room, this one included, with its outputDelay.
  , acoustics :: Acoustics
  , audienceGrace :: Duration
  , orphanTimeout :: Duration
  , playerReadyTimeout :: Duration
  , maxSuspension :: Duration
  -- ^ How long a suspended member keeps its place. A follower that is
  -- interrupted and then reboots never comes back to say so.
  }
  deriving stock (Eq, Show)

-- | What a probe of a source's status returns that the coordinator uses.
data PeerView = PeerView
  { viewAudience :: Set RoomName
  , viewMovedTo :: Maybe RoomName
  }
  deriving stock (Eq, Show)

data Event
  = Requested ReplyTo Request
  | -- | The answer to this room's AskHold, from the named source.
    HoldAnswered RoomName (Either Refusal ())
  | -- | A probe of the named room's status; Nothing when it did not answer.
    PeerProbed RoomName (Maybe PeerView)
  | -- | This room's server: the named room's player reported available.
    PlayerAvailable RoomName
  | -- | This room's server: the named room's player went away.
    PlayerGone RoomName
  | -- | MPD's player state changed: playing or not.
    MpdPlaying Bool
  | Tick
  deriving stock (Eq, Show)

data Effect
  = Act Action
  | Reply ReplyTo (Either Refusal ())
  | PauseMpd
  | ResumeMpd
  | -- | PauseClears: clear every player's buffer and seek MPD back by the
    -- audio that was sent and not yet heard.
    FlushAndSeekBack
  | ServerHold RoomName
  | ServerRelease RoomName
  | SendDelays (Map RoomName Millis)
  | Probe RoomName
  | StatusChanged
  deriving stock (Eq, Show)

-- | Effects that must happen before the outputs change (pausing MPD) and
-- effects that come after (replies, server and peer calls).
data Out = Out [Effect] [Effect]

instance Semigroup Out where
  Out a b <> Out c d = Out (a <> c) (b <> d)

instance Monoid Out where
  mempty = Out [] []

before, afterwards :: [Effect] -> Out
before es = Out es []
afterwards es = Out [] es

reply :: ReplyTo -> Either Refusal () -> Out
reply r x = afterwards [Reply r x]

step :: Config -> Instant -> Event -> RoomState -> (RoomState, [Effect])
step cfg now ev st0 =
  let (st1, out1) = handle cfg now ev st0
      (st2, out2) = settle st1
      (st3, delays) = align cfg st2
      Out pre post = out1 <> out2
      actions = map Act (plan (path st0, outputs st0) (path st3, outputs st3))
   in ( st3
      , pre <> actions <> post <> delays <> [StatusChanged | st3 /= st0]
      )

-- | Silent with nobody listening is not a resting state: own, paused.
settle :: RoomState -> (RoomState, Out)
settle st
  | intent st == Silent && not (streaming st) && not (isInterrupted st) =
      (st {intent = Own}, before [PauseMpd | mpdPlaying st])
  | otherwise = (st, mempty)

-- | The rooms the focus applies to: held members, and this room when its
-- own server holds its own player.
focusMembers :: RoomState -> Set RoomName
focusMembers st =
  heldMembers st <> (if path st == OwnServer then Set.singleton (self st) else Set.empty)

-- | ApplyFocus: send new delays whenever they differ from the last sent.
align :: Config -> RoomState -> (RoomState, [Effect])
align cfg st
  | wanted == appliedDelays st = (st, [])
  | Map.null wanted = (st {appliedDelays = wanted}, [])
  | otherwise = (st {appliedDelays = wanted}, [SendDelays wanted])
  where
    ms = focusMembers st
    wanted
      | not (streaming st) = Map.empty
      | otherwise = case chooseFocus (self st) (pin st) ms of
          Nothing -> Map.empty
          Just f -> alignedDelays (peers cfg) (acoustics cfg) f ms

handle :: Config -> Instant -> Event -> RoomState -> (RoomState, Out)
handle cfg now ev st = case ev of
  Requested r req -> request cfg now r req st
  HoldAnswered src result -> holdAnswered src result st
  PeerProbed src view -> probed now src view st
  PlayerAvailable f -> playerAvailable cfg f st
  PlayerGone f -> playerGone now f st
  MpdPlaying b ->
    ( st {mpdPlaying = b}
    , afterwards [FlushAndSeekBack | mpdPlaying st, not b, streaming st]
    )
  Tick -> tick cfg now st

known :: Config -> RoomName -> Bool
known cfg r = Map.member r (peers cfg)

-- | Any follow request still waiting on its source is answered Busy and
-- dropped, because a later request has replaced it.
dropPending :: RoomState -> (RoomState, Out)
dropPending st = case pendingFollow st of
  Nothing -> (st, mempty)
  Just p -> (st {pendingFollow = Nothing}, reply (pendingReply p) (Left Busy))

-- | A member's earlier pending reply, if any, answered Busy.
supersede :: RoomName -> RoomState -> Out
supersede f st = case Map.lookup f (members st) of
  Just (Joining _ r0) -> reply r0 (Left Busy)
  _ -> mempty

request :: Config -> Instant -> ReplyTo -> Request -> RoomState -> (RoomState, Out)
request cfg now r req st = case req of
  -- FollowRequested
  ReqFollow t
    | not (known cfg t) -> refuse UnknownRoom
    | t == self st -> refuse IsSelf
    | isInterrupted st -> refuse RoomInterrupted
    | isJust (pendingFollow st) -> refuse Busy
    | intent st == Following t -> ok st
    | otherwise ->
        ( st
            { intent = Following t
            , pendingFollow = Just (PendingFollow r t (intent st))
            , sourceUnreachableSince = Nothing
            }
        , before [PauseMpd | mpdPlaying st, not (streaming st)]
        )
  -- OwnRequested
  ReqOwn
    | isInterrupted st -> refuse RoomInterrupted
    | otherwise ->
        let (st', out) = dropPending st
         in (st' {intent = Own, sourceUnreachableSince = Nothing}, out <> reply r (Right ()))
  -- SilenceRequested
  ReqSilence
    | isInterrupted st -> refuse RoomInterrupted
    | otherwise ->
        let (st', out) = dropPending st
         in (st' {intent = Silent, sourceUnreachableSince = Nothing}, out <> reply r (Right ()))
  -- HoldRequested
  ReqHold f
    | not (known cfg f) -> refuse UnknownRoom
    | f == self st -> refuse IsSelf
    | Map.lookup f (members st) == Just Held -> ok st
    | otherwise ->
        ( st
            { members = Map.insert f (Joining (after (playerReadyTimeout cfg) now) r) (members st)
            , audienceEmptySince = Nothing
            }
        , supersede f st <> afterwards [ServerHold f]
        )
  ReqRelease f
    | Map.member f (members st) ->
        let ms = Map.delete f (members st)
         in ( st {members = ms, audienceEmptySince = emptiedAt now ms (audienceEmptySince st)}
            , supersede f st <> afterwards [ServerRelease f] <> reply r (Right ())
            )
    | otherwise -> ok st
  -- AudienceSuspends
  ReqSuspend f
    | not (known cfg f) -> refuse UnknownRoom
    | f == self st -> refuse IsSelf
    | otherwise ->
        ( st
            { members = Map.insert f (Suspended now) (members st)
            , audienceEmptySince = Nothing
            }
        , supersede f st <> afterwards [ServerRelease f] <> reply r (Right ())
        )
  -- FocusRequested
  ReqPin p
    | not (known cfg p) -> refuse UnknownRoom
    | otherwise -> (st {pin = Just p}, reply r (Right ()))
  ReqUnpin -> (st {pin = Nothing}, reply r (Right ()))
  -- InterruptionStarts
  ReqInterruptionStarts by -> interruptionStarts r by st
  -- InterruptionEnds
  ReqInterruptionEnds by -> interruptionEnds r by st
  where
    refuse why = (st, reply r (Left why))
    ok s = (s, reply r (Right ()))

-- | Restart the grace period when the last member has just gone.
emptiedAt :: Instant -> Map RoomName Member -> Maybe Instant -> Maybe Instant
emptiedAt now ms current
  | Map.null ms = Just (fromMaybe now current)
  | otherwise = Nothing

interruptionStarts :: ReplyTo -> Interrupter -> RoomState -> (RoomState, Out)
interruptionStarts r by st = case interruption st of
  Just i
    | interruptedBy i == by -> (st, reply r (Right ()))
    | otherwise -> (st, reply r (Left RoomInterrupted))
  Nothing ->
    let -- A follow still waiting on its source is abandoned, and the room
        -- resumes to what it was before that request. The target is told
        -- to let go too, or it would keep a place for this room.
        (st1, out1) = case pendingFollow st of
          Nothing -> (st, mempty)
          Just p ->
            ( st {pendingFollow = Nothing, intent = pendingPrevious p}
            , reply (pendingReply p) (Left RoomInterrupted)
                <> afterwards [Act (AskRelease (pendingTarget p))]
            )
        alone = intent st1 == Own && not (streaming st1)
        playingAlone = alone && mpdPlaying st1
        saved = Resumption {resumeIntent = intent st1, resumeMpdPlaying = playingAlone}
     in ( st1 {interruption = Just (Interruption by saved)}
        , out1 <> before [PauseMpd | playingAlone] <> reply r (Right ())
        )

interruptionEnds :: ReplyTo -> Interrupter -> RoomState -> (RoomState, Out)
interruptionEnds r by st = case interruption st of
  Just i
    | interruptedBy i == by ->
        let saved = resumption i
         in ( st
                { interruption = Nothing
                , intent = resumeIntent saved
                , sourceUnreachableSince = Nothing
                }
            , afterwards [ResumeMpd | resumeMpdPlaying saved] <> reply r (Right ())
            )
  _ -> (st, reply r (Right ()))

holdAnswered :: RoomName -> Either Refusal () -> RoomState -> (RoomState, Out)
holdAnswered src result st = case pendingFollow st of
  Just p
    | pendingTarget p == src -> case result of
        Right () -> (st {pendingFollow = Nothing}, reply (pendingReply p) (Right ()))
        Left why ->
          ( st {pendingFollow = Nothing, intent = pendingPrevious p}
          , reply (pendingReply p) (Left why)
          )
  _ -> (st, mempty)

-- | FollowerReconciles, from a probe's result.
probed :: Instant -> RoomName -> Maybe PeerView -> RoomState -> (RoomState, Out)
probed now src view st
  | currentSource st /= Just src = (st, mempty)
  | isInterrupted st || isJust (pendingFollow st) = (st, mempty)
  | otherwise = case view of
      Nothing ->
        (st {sourceUnreachableSince = Just (fromMaybe now (sourceUnreachableSince st))}, mempty)
      Just v -> case viewMovedTo v of
        Just n
          | n == self st -> (st {intent = Own, sourceUnreachableSince = Nothing}, mempty)
          | otherwise -> (st {intent = Following n, sourceUnreachableSince = Nothing}, mempty)
        Nothing
          | self st `Set.member` viewAudience v -> (st {sourceUnreachableSince = Nothing}, mempty)
          | otherwise ->
              -- The source rebooted, or dropped the player: ask again.
              (st {sourceUnreachableSince = Nothing}, afterwards [Act (AskHold src)])

-- | AudienceJoins.
playerAvailable :: Config -> RoomName -> RoomState -> (RoomState, Out)
playerAvailable cfg f st = case Map.lookup f (members st) of
  Just (Joining _ r) -> (held, reply r (Right ()))
  Just (Suspended _) -> (held, mempty)
  Just Held -> (st, mempty)
  Nothing
    | known cfg f && f /= self st -> (held, mempty)
    | otherwise -> (st, afterwards [ServerRelease f])
  where
    held = st {members = Map.insert f Held (members st), audienceEmptySince = Nothing}

-- | AudienceLeaves. A suspended member keeps its place.
playerGone :: Instant -> RoomName -> RoomState -> (RoomState, Out)
playerGone now f st = case Map.lookup f (members st) of
  Just (Joining _ r) -> (removed, reply r (Left PlayerNotReady))
  Just Held -> (removed, mempty)
  Just (Suspended _) -> (st, mempty)
  Nothing -> (st, mempty)
  where
    ms = Map.delete f (members st)
    removed = st {members = ms, audienceEmptySince = emptiedAt now ms (audienceEmptySince st)}

tick :: Config -> Instant -> RoomState -> (RoomState, Out)
tick cfg now st0 =
  let (st1, out1) = expireMembers cfg now st0
      (st2, out2) = endGrace cfg now st1
      (st3, out3) = orphan cfg now st2
      out4 = case currentSource st3 of
        Just src
          | not (isInterrupted st3) && not (isJust (pendingFollow st3)) -> afterwards [Probe src]
        _ -> mempty
   in (st3, out1 <> out2 <> out3 <> out4)

-- | Joining members past their deadline are refused PlayerNotReady;
-- suspended members past maxSuspension are dropped.
expireMembers :: Config -> Instant -> RoomState -> (RoomState, Out)
expireMembers cfg now st =
  let (gone, kept) = Map.partition expired (members st)
      expired (Joining deadline _) = deadline <= now
      expired (Suspended since) = after (maxSuspension cfg) since <= now
      expired Held = False
      out = foldMap goneOut (Map.toList gone)
      goneOut (f, Joining _ r) = reply r (Left PlayerNotReady) <> afterwards [ServerRelease f]
      goneOut _ = mempty
      emptySince
        | Map.null gone = audienceEmptySince st
        | otherwise = emptiedAt now kept (audienceEmptySince st)
   in (st {members = kept, audienceEmptySince = emptySince}, out)

-- | AudienceGoneForGood. A silent room is settled to own and paused by
-- 'settle'; a following room's MPD is paused because nobody hears it.
endGrace :: Config -> Instant -> RoomState -> (RoomState, Out)
endGrace cfg now st = case audienceEmptySince st of
  Just since
    | Map.null (members st) && after (audienceGrace cfg) since <= now ->
        let following = isJust (currentSource st)
         in (st {audienceEmptySince = Nothing}, before [PauseMpd | following, mpdPlaying st])
  _ -> (st, mempty)

-- | ListenerOrphaned.
orphan :: Config -> Instant -> RoomState -> (RoomState, Out)
orphan cfg now st = case (currentSource st, sourceUnreachableSince st) of
  (Just _, Just since)
    | not (isInterrupted st) && after (orphanTimeout cfg) since <= now ->
        ( st {intent = Own, sourceUnreachableSince = Nothing}
        , before [PauseMpd | mpdPlaying st, not (streaming st)]
        )
  _ -> (st, mempty)
