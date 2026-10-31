-- | What every view needs: class attributes, glyphs, and the format badge
-- | that appears on every kind of track row.
module Ui where

import Prelude

import Data.Maybe (Maybe(..))
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Mpd (Quality(..))
import Mpd as Mpd

-- | One glyph from the set in index.html, painted with the colour of
-- | whatever contains it. Each is an SVG behind a CSS mask, so it
-- | inherits the button's colour and keeps the same size everywhere;
-- | emoji did neither, which is what made the speaker shift in place.
icon :: forall w i. String -> HH.HTML w i
icon name = HH.span [ classes [ "i", "i-" <> name ] ] []

iconSized :: forall w i. String -> String -> HH.HTML w i
iconSized size name = HH.span [ classes [ "i", size, "i-" <> name ] ] []

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls = HP.class_ <<< HH.ClassName

classes :: forall r i. Array String -> HP.IProp (class :: String | r) i
classes = HP.classes <<< map HH.ClassName

-- | What a file is, in three or four letters, coloured by whether it
-- | keeps every sample. Nothing at all for a stream or an extension the
-- | page does not recognise: a blank says less than a wrong guess.
formatBadge :: forall w i. String -> HH.HTML w i
formatBadge file = case Mpd.fileFormat file of
  Nothing -> HH.text ""
  Just f ->
    HH.span
      [ classes [ "fmt", if f.quality == Lossless then "lossless" else "lossy" ]
      , HP.title (if f.quality == Lossless then f.label <> ", lossless" else f.label <> ", lossy")
      ]
      [ HH.text f.label ]