module Main (main) where

import CoordinatorSpec qualified
import FocusSpec qualified
import OutputsSpec qualified
import SendspinSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Coordinator" CoordinatorSpec.spec
  describe "Outputs" OutputsSpec.spec
  describe "Focus" FocusSpec.spec
  describe "Sendspin" SendspinSpec.spec
