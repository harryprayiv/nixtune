-- | A minimal MPD client over TCP: one connection for commands, and a
-- second one that sits in @idle@ and reports when the player or the
-- outputs change. Commands on one connection are serialised by an MVar.
--
-- A connection reconnects on its own. MPD closes a client that has sent
-- nothing for its connection_timeout (60 seconds by default), and a room
-- that plays alone sends nothing for hours; MPD also goes away when it
-- restarts. A command that finds the connection closed is sent again,
-- once, on a new one. That is safe for every command nixtune sends: MPD
-- runs nothing from a client it has already closed, and the commands
-- sent on a long-lived connection (status, outputs, enableoutput,
-- disableoutput, pause, idle) leave MPD the same if run twice.
module Nixtune.Mpd.Client
  ( Connection
  , connect
  , close
  , command
  , idleLoop
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Exception (bracketOnError, mask, throwIO)
import Control.Monad (forever, unless)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Foldable (traverse_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Nixtune.Mpd.Protocol (Response (..), pair)
import Nixtune.Room.Sync (catchSync, trySync)

data Connection = Connection
  { host :: Text
  , port :: Int
  , live :: MVar (Maybe Live)
  -- ^ Nothing after a failure, until the next command connects again.
  }

data Live = Live
  { sock :: Socket.Socket
  , pending :: IORef ByteString.ByteString
  }

-- | Connect now, so a caller learns at once whether MPD is there.
connect :: Text -> Int -> IO Connection
connect h p = Connection h p <$> (newMVar . Just =<< open h p)

open :: Text -> Int -> IO Live
open h p = do
  let hints = Socket.defaultHints {Socket.addrSocketType = Socket.Stream}
  addrs <- Socket.getAddrInfo (Just hints) (Just (Text.unpack h)) (Just (show p))
  addr <- case addrs of
    a : _ -> pure a
    [] -> fail ("no address for " <> Text.unpack h)
  bracketOnError (Socket.openSocket addr) Socket.close $ \s -> do
    Socket.connect s (Socket.addrAddress addr)
    l <- Live s <$> newIORef ByteString.empty
    greeting <- readLine l
    unless ("OK MPD" `Text.isPrefixOf` greeting) $
      fail ("not an MPD server: " <> Text.unpack (Text.take 60 greeting))
    pure l

closeLive :: Live -> IO ()
closeLive l = Socket.close (sock l) `catchSync` \_ -> pure ()

close :: Connection -> IO ()
close c = do
  m <- takeMVar (live c)
  traverse_ closeLive m
  putMVar (live c) Nothing

readLine :: Live -> IO Text
readLine l = do
  buf <- readIORef (pending l)
  case Char8.elemIndex '\n' buf of
    Just i -> do
      writeIORef (pending l) (ByteString.drop (i + 1) buf)
      pure (decodeUtf8Lenient (ByteString.take i buf))
    Nothing -> do
      more <- SocketBS.recv (sock l) 65536
      if ByteString.null more
        then fail "MPD closed the connection"
        else writeIORef (pending l) (buf <> more) >> readLine l

readResponse :: Live -> IO Response
readResponse l = go []
  where
    go acc = do
      line <- readLine l
      if line == "OK"
        then pure (Done (reverse acc))
        else
          if "ACK " `Text.isPrefixOf` line
            then pure (Failed line)
            else go (maybe acc (: acc) (pair line))

exchange :: Live -> Text -> IO Response
exchange l line = do
  SocketBS.sendAll (sock l) (encodeUtf8 line <> "\n")
  readResponse l

-- | Send one command line and read its whole response, on a new
-- connection if the current one has closed. Throws only when MPD cannot
-- be reached at all.
command :: Connection -> Text -> IO Response
command c line = mask $ \restore -> do
  m <- takeMVar (live c)
  r <- trySync (restore (attempt m))
  case r of
    Right (l, resp) -> putMVar (live c) (Just l) >> pure resp
    Left e -> putMVar (live c) Nothing >> throwIO e
  where
    attempt m = do
      first <- case m of
        Nothing -> pure Nothing
        Just l -> do
          x <- trySync (exchange l line)
          case x of
            Right resp -> pure (Just (l, resp))
            Left _ -> closeLive l >> pure Nothing
      case first of
        Just done -> pure done
        Nothing ->
          bracketOnError (open (host c) (port c)) closeLive $ \l ->
            (l,) <$> exchange l line

-- | Wait in @idle@ for the given subsystems, calling back after each
-- wake. When MPD cannot be reached, it calls back every second until a
-- callback succeeds, since anything may have changed meanwhile, and then
-- idles again. Returns only by an exception from a callback after a
-- wake.
idleLoop :: Connection -> [Text] -> IO () -> IO ()
idleLoop c subsystems onChange = forever $ do
  r <- trySync (command c ("idle " <> Text.unwords subsystems))
  case r of
    Right _ -> onChange
    Left _ -> resync
  where
    resync = do
      threadDelay 1000000
      onChange `catchSync` \_ -> resync