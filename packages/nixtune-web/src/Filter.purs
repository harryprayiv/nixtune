-- | MPD filter expressions, built from values the page holds.
-- |
-- | A value travels through three layers on its way to MPD, and each one
-- | has its own escaping:
-- |
-- |   regex      inside `=~`, PCRE metacharacters are escaped so a name
-- |              like "AC/DC (Live)" matches itself and nothing else
-- |   filter     every value sits in single quotes, with backslash and
-- |              single quote escaped; MPD's filter parser undoes this
-- |   protocol   the whole expression is one double-quoted argument,
-- |              with backslash and double quote escaped; MPD's command
-- |              tokenizer undoes this. That is Mpd.quote, applied by
-- |              whoever puts the expression into a command.
-- |
-- | Getting a layer wrong does not raise an error. It matches nothing, or
-- | the wrong thing, so every expression the page sends is built here and
-- | nowhere else.
module Filter
  ( Term
  , literal
  , regexLiteral
  , equals
  , anyOf
  , contains
  , conjoin
  ) where

import Prelude

import Data.Foldable (foldl)
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)

-- | One parenthesised filter expression, escaped for the filter layer and
-- | not yet for the protocol.
newtype Term = Term String

-- | A value as a filter-layer string literal.
literal :: String -> String
literal v = "'" <> escape v <> "'"
  where
  escape = replaceAll (Pattern "\\") (Replacement "\\\\") >>> replaceAll (Pattern "'") (Replacement "\\'")

-- | A value as a regular expression that matches exactly that text.
-- | Backslash goes first, so the backslashes the rest add are not
-- | themselves escaped again.
regexLiteral :: String -> String
regexLiteral v = foldl step (replaceAll (Pattern "\\") (Replacement "\\\\") v) metas
  where
  metas = [ "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}" ]
  step acc m = replaceAll (Pattern m) (Replacement ("\\" <> m)) acc

-- | The tag has exactly this value. MPD applies its tag fallbacks, so
-- | albumartist also matches a file that has only artist.
equals :: String -> String -> Term
equals tag v = Term ("(" <> tag <> " == " <> literal v <> ")")

-- | The tag has any one of these values. MPD filters have no OR, so more
-- | than one value is one anchored alternation, which needs MPD built
-- | with pcre. One value uses `==`, which needs nothing.
anyOf :: String -> Array String -> Maybe Term
anyOf tag vs = case vs of
  [] -> Nothing
  [ v ] -> Just (equals tag v)
  _ -> Just (Term ("(" <> tag <> " =~ " <> literal ("^(?:" <> joinWith "|" (map regexLiteral vs) <> ")$") <> ")"))

-- | Some tag of the song contains this text, ignoring case.
contains :: String -> Term
contains q = Term ("(any contains_ci " <> literal q <> ")")

-- | All of these at once, as one expression, or Nothing for no filter.
conjoin :: Array Term -> Maybe String
conjoin ts = case map (\(Term t) -> t) ts of
  [] -> Nothing
  [ t ] -> Just t
  many -> Just ("(" <> joinWith " AND " many <> ")")