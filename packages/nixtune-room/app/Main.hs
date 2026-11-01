-- | nixtune-room's command line.
--
-- > nixtune-room run --config /etc/nixtune/room.json
-- > nixtune-room ctl --socket /run/nixtune-room/control.sock interruption-starts airplay
-- > nixtune-room keys --rooms kitchen,lab,living-room --out ./nixtune-room-keys
-- > nixtune-room provision-player --config /etc/nixtune/room.json --state-dir /var/lib/nixtune-player
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM_, unless, when)
import Data.ByteString.Char8 qualified as Char8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Text.IO qualified as TextIO
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Nixtune.Room.Config (loadConfig)
import Nixtune.Room.Daemon qualified as Daemon
import Nixtune.Room.Keys (generateHome, publicKeysNix, roomSecretsYaml)
import Nixtune.Room.Name (mkRoomName, roomNameText)
import Nixtune.Room.Provision (provisionPlayer)
import Nixtune.Room.Server (unbuiltServer)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesPathExist)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)

data Command
  = Run FilePath
  | Ctl FilePath [Text]
  | Keys Text FilePath
  | ProvisionPlayer FilePath FilePath

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "run" (info (Run <$> configOpt) (progDesc "Run the room's coordinator"))
        <> command "ctl" (info (Ctl <$> socketOpt <*> some (argument str (metavar "REQUEST..."))) (progDesc "Send one request to the local coordinator"))
        <> command "keys" (info (Keys <$> strOption (long "rooms" <> metavar "a,b,c") <*> strOption (long "out" <> metavar "DIR")) (progDesc "Generate keys and PSKs for every room"))
        <> command "provision-player" (info (ProvisionPlayer <$> configOpt <*> strOption (long "state-dir" <> metavar "DIR")) (progDesc "Write the player's identity and pairing records from sops secrets"))
    )
  where
    configOpt = strOption (long "config" <> metavar "FILE" <> value "/etc/nixtune/room.json" <> showDefault)
    socketOpt = strOption (long "socket" <> metavar "PATH" <> value "/run/nixtune-room/control.sock" <> showDefault)

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper) (fullDesc <> progDesc "The nixtune multiroom daemon"))
  case cmd of
    Run path -> do
      cfg <- either die' pure =<< loadConfig path
      let say = TextIO.hPutStrLn stderr
      d <- Daemon.start say cfg (\_ -> pure (unbuiltServer say))
      Daemon.run d
    Ctl path ws -> ctl path (Text.unwords ws)
    Keys rooms out -> keys rooms out
    ProvisionPlayer path stateDir -> do
      cfg <- either die' pure =<< loadConfig path
      r <- provisionPlayer cfg stateDir
      either die' pure r

die' :: String -> IO a
die' e = TextIO.hPutStrLn stderr (Text.pack e) >> exitFailure

-- | Exit status 0 for ok and for a status line, 1 for anything else, so a
-- hook can tell whether it was refused.
ctl :: FilePath -> Text -> IO ()
ctl path line =
  bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \s -> do
    Socket.connect s (Socket.SockAddrUnix path)
    SocketBS.sendAll s (encodeUtf8 line <> "\n")
    answer <- readAll s mempty
    let reply = Text.strip (decodeUtf8Lenient answer)
    TextIO.putStrLn reply
    unless (reply == "ok" || "status " `Text.isPrefixOf` reply) exitFailure
  where
    readAll s acc = do
      chunk <- SocketBS.recv s 4096
      if Char8.null chunk || Char8.elem '\n' chunk then pure (acc <> chunk) else readAll s (acc <> chunk)

-- | Writes one secrets file per room into DIR (mode 0600, never
-- overwriting), and prints the public keys as a Nix attrset. Nothing
-- secret is printed.
keys :: Text -> FilePath -> IO ()
keys roomsArg out = do
  rooms <- traverse (\t -> maybe (die' ("bad room name: " <> Text.unpack t)) pure (mkRoomName t)) (Text.splitOn "," roomsArg)
  when (null rooms) (die' "no rooms")
  createDirectoryIfMissing True out
  forM_ rooms $ \r -> do
    exists <- doesPathExist (out </> file r)
    when exists (die' (out </> file r <> " exists; refusing to overwrite keys"))
  hk <- generateHome rooms
  forM_ rooms $ \r -> do
    let path = out </> file r
    -- Owner-only before any secret is written to it.
    TextIO.writeFile path ""
    setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode)
    TextIO.writeFile path (roomSecretsYaml hk r)
    TextIO.hPutStrLn stderr ("wrote " <> Text.pack path)
  TextIO.putStr (publicKeysNix hk)
  where
    file r = Text.unpack (roomNameText r) <> ".yaml"