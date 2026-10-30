-- | The three things every view needs: class attributes, and a glyph.
module Ui where

import Prelude

import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

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
