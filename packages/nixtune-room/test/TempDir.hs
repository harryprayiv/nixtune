-- | A scratch directory for one test, removed afterwards. Written here so
-- the test suite needs nothing beyond GHC's own boot packages for it.
module TempDir (withTempDir) where

import Control.Exception (bracket)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)

withTempDir :: String -> (FilePath -> IO a) -> IO a
withTempDir prefix = bracket make removeDirectoryRecursive
  where
    make = do
      base <- getTemporaryDirectory
      pid <- getProcessID
      t <- getMonotonicTimeNSec
      let dir = base </> (prefix <> "-" <> show pid <> "-" <> show t)
      createDirectory dir
      pure dir