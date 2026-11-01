module Main (main) where

import CoordinatorSpec qualified
import DaemonSpec qualified
import FocusSpec qualified
import KeysSpec qualified
import MpdSpec qualified
import NetSpec qualified
import NoiseSpec qualified
import OutputsSpec qualified
import SendspinSpec qualified
import StreamSpec qualified
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
  describe "Noise" NoiseSpec.spec
  describe "Stream" StreamSpec.spec
  describe "Sync" SyncSpec.spec
  describe "Net" NetSpec.spec
  describe "Daemon" DaemonSpec.spec