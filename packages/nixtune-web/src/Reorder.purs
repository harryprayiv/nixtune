-- | Dragging a queue row.
-- |
-- | The list is never reordered under the finger. The rows are measured
-- | once, when the drag starts, and each row is then drawn offset from
-- | where it actually sits, so the geometry the drag is reckoned against
-- | stays still while the gap appears to open. One `move` goes to MPD
-- | when the finger lifts, and the real order arrives back through the
-- | idle connection like any other change, which is why nothing here
-- | touches the queue.
module Reorder where

import Prelude

import Data.Array (length)
import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Types (Drag, M)
import Web.HTML.HTMLElement as HTMLElement

-- | The ref every queue row carries, so a drag can measure the list.
rowRef :: Int -> H.RefLabel
rowRef i = H.RefLabel ("queue-row-" <> show i)

-- | The vertical middle of each of the first n queue rows. Measured from
-- | the list's own offset parent rather than the viewport, which costs
-- | nothing here: every comparison below is between two of these numbers
-- | or against a pointer's travel, and both are differences. Short of n
-- | entries when a row is not on the page, which is the signal to leave
-- | the drag alone.
rowMiddles :: forall o m. MonadAff m => Int -> M o m (Array Number)
rowMiddles n =
  if n <= 0 then pure []
  else map Array.catMaybes (traverse one (Array.range 0 (n - 1)))
  where
  one i = do
    el <- H.getHTMLElementRef (rowRef i)
    case el of
      Nothing -> pure Nothing
      Just e -> do
        top <- liftEffect (HTMLElement.offsetTop e)
        height <- liftEffect (HTMLElement.offsetHeight e)
        pure (Just (top + height / 2.0))

-- | Where the dragged row would land if the finger lifted now: the row
-- | whose middle the dragged row's middle has last passed.
dragTarget :: Drag -> Int
dragTarget d =
  let
    here = fromMaybe 0.0 (Array.index d.mids d.from) + (d.y - d.startY)
    above = length (Array.filter (_ < here) d.mids)
  in
    clamp 0 (length d.mids - 1) (if d.y > d.startY then above - 1 else above)

-- | How far row i is drawn from where it sits, during a drag. The row
-- | under the finger follows it; the rows the drag has passed step out of
-- | the way by one row's worth, which is what makes the gap appear.
rowShift :: Maybe Drag -> Int -> Number
rowShift Nothing _ = 0.0
rowShift (Just d) i =
  let
    to = dragTarget d
  in
    if i == d.from then d.y - d.startY
    else if d.from < to && i > d.from && i <= to then negate d.advance
    else if to < d.from && i >= to && i < d.from then d.advance
    else 0.0
