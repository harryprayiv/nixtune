-- | A minimal MPD client over TCP: one connection for commands, and a
-- second one that sits in @idle@ and reports when the player or the
-- outputs change. Commands on one connection are serialised by an MVar.
module Nixtune.Mpd.Client
  ( Connection
  , connect
  , close
  , command
  , idleLoop
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (bracketOnError)
import Control.Monad (forever, unless)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Nixtune.Mpd.Protocol (Response (..), pair)

data Connection = Connection
  { sock :: Socket.Socket
  , pending :: IORef ByteString.ByteString
  , lock :: MVar ()
  }

connect :: Text -> Int -> IO Connection
connect host port = do
  let hints = Socket.defaultHints {Socket.addrSocketType = Socket.Stream}
  addrs <- Socket.getAddrInfo (Just hints) (Just (Text.unpack host)) (Just (show port))
  addr <- case addrs of
    a : _ -> pure a
    [] -> fail ("no address for " <> Text.unpack host)
  bracketOnError (Socket.openSocket addr) Socket.close $ \s -> do
    Socket.connect s (Socket.addrAddress addr)
    c <- Connection s <$> newIORef ByteString.empty <*> newMVar ()
    greeting <- readLine c
    unless ("OK MPD" `Text.isPrefixOf` greeting) $
      fail ("not an MPD server: " <> Text.unpack (Text.take 60 greeting))
    pure c

close :: Connection -> IO ()
close = Socket.close . sock

readLine :: Connection -> IO Text
readLine c = do
  buf <- readIORef (pending c)
  case Char8.elemIndex '\n' buf of
    Just i -> do
      writeIORef (pending c) (ByteString.drop (i + 1) buf)
      pure (decodeUtf8Lenient (ByteString.take i buf))
    Nothing -> do
      more <- SocketBS.recv (sock c) 65536
      if ByteString.null more
        then fail "MPD closed the connection"
        else writeIORef (pending c) (buf <> more) >> readLine c

readResponse :: Connection -> IO Response
readResponse c = go []
  where
    go acc = do
      line <- readLine c
      if line == "OK"
        then pure (Done (reverse acc))
        else
          if "ACK " `Text.isPrefixOf` line
            then pure (Failed line)
            else go (maybe acc (: acc) (pair line))

-- | Send one command line and read its whole response.
command :: Connection -> Text -> IO Response
command c line = withMVar (lock c) $ \_ -> do
  SocketBS.sendAll (sock c) (encodeUtf8 line <> "\n")
  readResponse c

-- | Wait in @idle@ for the given subsystems, calling back after each
-- wake. Returns only by exception, when the connection fails.
idleLoop :: Connection -> [Text] -> IO () -> IO ()
idleLoop c subsystems onChange = forever $ do
  _ <- command c ("idle " <> Text.unwords subsystems)
  onChange
