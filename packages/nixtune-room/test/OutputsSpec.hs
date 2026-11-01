-- | The DAC is never claimed twice. Every step of every random run is
-- replayed action by action against a model of the room's outputs.
module OutputsSpec (spec) where

import Generators
import Nixtune.Room.Coordinator (Effect (..))
import Nixtune.Room.Outputs (Action (..))
import Nixtune.Room.State (Holder (..), Outputs (..), outputs)
import Test.Hspec
import Test.QuickCheck

-- | What the shell has switched: MPD's ALSA output, MPD's fifo output, and
-- which of nixtune's servers holds this room's player (an interrupter
-- holding it is outside nixtune's actions, so it shows as Nothing).
data Sim = Sim
  { simAlsa :: Bool
  , simFifo :: Bool
  , simHolder :: Maybe Holder
  }
  deriving stock (Eq, Show)

ours :: Maybe Holder -> Maybe Holder
ours (Just ByInterrupter) = Nothing
ours h = h

fromOutputs :: Outputs -> Sim
fromOutputs o = Sim (alsaOutput o) (fifoOutput o) (ours (player o))

apply :: Sim -> Action -> Either String Sim
apply s a = case a of
  EnableFifo -> Right s {simFifo = True}
  DisableFifo
    | simHolder s == Just BySelf -> Left "fifo disabled while own server holds own player"
    | otherwise -> Right s {simFifo = False}
  EnableAlsa
    | simHolder s /= Nothing -> Left "ALSA enabled while a player is held"
    | otherwise -> Right s {simAlsa = True}
  DisableAlsa -> Right s {simAlsa = False}
  HoldOwnPlayer
    | simAlsa s -> Left "own player held while ALSA enabled"
    | not (simFifo s) -> Left "own player held with fifo off"
    | otherwise -> Right s {simHolder = Just BySelf}
  ReleaseOwnPlayer -> Right s {simHolder = Nothing}
  AskHold r
    | simAlsa s -> Left "peer asked to hold while ALSA enabled"
    | otherwise -> Right s {simHolder = Just (ByPeer r)}
  AskRelease _ -> Right s {simHolder = Nothing}
  AskSuspend _ -> Right s {simHolder = Nothing}

actionsOf :: [Effect] -> [Action]
actionsOf es = [a | Act a <- es]

-- | Replays one step's actions. A foreign Sendspin server takes the
-- player by itself, displacing whichever of nixtune's servers held it, and
-- the player opens the DAC only after the start hook (which is this plan)
-- has returned; so that takeover is applied after the actions.
replayStep :: Stepped -> Either String Sim
replayStep s = takeover <$> foldl (\acc a -> acc >>= (`apply` a)) (Right (fromOutputs (outputs (before' s)))) (actionsOf (effects s))
  where
    takeover sim
      | player (outputs (after' s)) == Just ByInterrupter = sim {simHolder = Nothing}
      | otherwise = sim

spec :: Spec
spec = describe "output switching" $ do
  it "never has MPD's ALSA output and a held player at once" $
    property $
      forAll genRun $ \r ->
        conjoin
          [ counterexample (show s) $ case replayStep s of
              Left why -> counterexample why False
              Right _ -> property True
          | s <- runEvents r
          ]
  it "ends every step with the outputs the new state asks for" $
    property $
      forAll genRun $ \r ->
        conjoin
          [ counterexample (show s) (replayStep s === Right (fromOutputs (outputs (after' s))))
          | s <- runEvents r
          ]
