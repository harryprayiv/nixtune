module Main (main) where

import CoordinatorSpec qualified
import DaemonSpec qualified
import FocusSpec qualified
import KeysSpec qualified
import MpdSpec qualified
import OutputsSpec qualified
import SendspinSpec qualified
import SyncSpec qualified
import Test.Hspec
import WireSpec qualified

main :: IO ()
main = hspec $ do
  describe "Coordinator" CoordinatorSpec.spec
  describe "Outputs" OutputsSpec.spec
  describe "Focus" FocusSpec.spec
  describe "Sendspin" SendspinSpec.spec
  describe "Wire" WireSpec.spec
  describe "MPD" MpdSpec.spec
  describe "Keys" KeysSpec.spec
  describe "Sync" SyncSpec.spec
  describe "Daemon" DaemonSpec.spec