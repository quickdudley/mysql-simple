{-# LANGUAGE BangPatterns, DeriveDataTypeable, OverloadedStrings #-}

-- |
-- Module:      Database.MySQL.Simple
-- Copyright:   (c) 2011 MailRank, Inc.
-- License:     BSD3
-- Maintainer:  Bryan O'Sullivan <bos@mailrank.com>
-- Stability:   experimental
-- Portability: portable
--
-- A mid-level client library for the MySQL database, aimed at ease of
-- use and high performance.

module Database.MySQL.Simple
    (
    -- * Writing queries
    -- $use

    -- ** The Query type
    -- $querytype

    -- ** Parameter substitution
    -- $subst

    -- *** Type inference
    -- $inference

    -- ** Substituting a single parameter
    -- $only

    -- ** Representing a list of values
    -- $in

    -- ** Modifying multiple rows at once
    -- $many

    -- * Types
      Base.ConnectInfo(..)
    , Connection
    , Query
    , In(..)
    , Only(..)
    -- ** Exceptions
    , FormatError(fmtMessage, fmtQuery, fmtParams)
    , QueryError(qeMessage, qeQuery)
    , ResultError(errSQLType, errHaskellType, errMessage)
    -- * Connection management
    , Base.connect
    , Base.defaultConnectInfo
    , Base.close
    -- * Queries that return results
    , query
    , query_
    -- * Statements that do not return results
    , execute
    , execute_
    , executeMany
    , Base.insertID
    -- * Transaction handling
    , withTransaction
    , Base.autocommit
    , Base.commit
    , Base.rollback
    -- * Helper functions
    , formatMany
    , formatQuery
    ) where

import Blaze.ByteString.Builder (Builder, fromByteString, toByteString)
import Blaze.ByteString.Builder.Char8 (fromChar)
import Control.Applicative ((<$>), pure)
import Control.Exception (Exception, onException, throw)
import Control.Monad.Fix (fix)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.List (intersperse)
import Data.Monoid (mappend, mconcat)
import Data.Typeable (Typeable)
import Database.MySQL.Base (Connection)
import Database.MySQL.Simple.Param (Action(..), inQuotes)
import Database.MySQL.Simple.QueryParams (QueryParams(..))
import Database.MySQL.Simple.QueryResults (QueryResults(..))
import Database.MySQL.Simple.Result (ResultError(..))
import Database.MySQL.Simple.Types (In(..), Only(..), Query(..))
import Text.Regex.PCRE.Light (compile, caseless, match)
import qualified Data.ByteString.Char8 as B
import qualified Database.MySQL.Base as Base

-- | Exception thrown if a 'Query' could not be formatted correctly.
-- This may occur if the number of \'@?@\' characters in the query
-- string does not match the number of parameters provided.
data FormatError = FormatError {
      fmtMessage :: String
    , fmtQuery :: Query
    , fmtParams :: [ByteString]
    } deriving (Eq, Show, Typeable)

instance Exception FormatError

-- | Exception thrown if 'query' is used to perform an @INSERT@-like
-- operation, or 'execute' is used to perform a @SELECT@-like operation.
data QueryError = QueryError {
      qeMessage :: String
    , qeQuery :: Query
    } deriving (Eq, Show, Typeable)

instance Exception QueryError

-- | Format a query string.
--
-- This function is exposed to help with debugging and logging. Do not
-- use it to prepare queries for execution.
--
-- String parameters are escaped according to the character set in use
-- on the 'Connection'.
--
-- Throws 'FormatError' if the query string could not be formatted
-- correctly.
formatQuery :: QueryParams q => Connection -> Query -> q -> IO ByteString
formatQuery conn q@(Query template) qs
    | null xs && '?' `B.notElem` template = return template
    | otherwise = toByteString <$> buildQuery conn q template xs
  where xs = renderParams qs

-- | Format a query string with a variable number of rows.
--
-- This function is exposed to help with debugging and logging. Do not
-- use it to prepare queries for execution.
--
-- The query string must contain exactly one substitution group,
-- identified by the SQL keyword \"@VALUES@\" (case insensitive)
-- followed by an \"@(@\" character, a series of one or more \"@?@\"
-- characters separated by commas, and a \"@)@\" character. White
-- space in a substitution group is permitted.
--
-- Throws 'FormatError' if the query string could not be formatted
-- correctly.
formatMany :: (QueryParams q) => Connection -> Query -> [q] -> IO ByteString
formatMany _ q [] = fmtError "no rows supplied" q []
formatMany conn q@(Query template) qs = do
  case match re template [] of
    Just [_,before,qbits,after] -> do
      bs <- mapM (buildQuery conn q qbits . renderParams) qs
      return . toByteString . mconcat $ fromByteString before :
                                        intersperse (fromChar ',') bs ++
                                        [fromByteString after]
    _ -> error "foo"
  where
   re = compile "^([^?]+\\bvalues\\s*)\
                 \(\\(\\s*[?](?:\\s*,\\s*[?])*\\s*\\))\
                 \([^?]*)$"
        [caseless]

buildQuery :: Connection -> Query -> ByteString -> [Action] -> IO Builder
buildQuery conn q template xs = zipParams (split template) <$> mapM sub xs
  where sub (Plain b)  = pure b
        sub (Escape s) = (inQuotes . fromByteString) <$> Base.escape conn s
        sub (Many ys)  = mconcat <$> mapM sub ys
        split s = fromByteString h : if B.null t then [] else split (B.tail t)
            where (h,t) = B.break (=='?') s
        zipParams (t:ts) (p:ps) = t `mappend` p `mappend` zipParams ts ps
        zipParams [t] []        = t
        zipParams _ _ = fmtError (show (B.count '?' template) ++
                                  " '?' characters, but " ++
                                  show (length xs) ++ " parameters") q xs

-- | Execute an @INSERT@, @UPDATE@, or other SQL query that is not
-- expected to return results.
--
-- Returns the number of rows affected.
--
-- Throws 'FormatError' if the query could not be formatted correctly.
execute :: (QueryParams q) => Connection -> Query -> q -> IO Int64
execute conn template qs = do
  Base.query conn =<< formatQuery conn template qs
  finishExecute template conn

-- | A version of 'execute' that does not perform query substitution.
execute_ :: Connection -> Query -> IO Int64
execute_ conn q@(Query stmt) = do
  Base.query conn stmt
  finishExecute q conn

-- | Execute a multi-row @INSERT@, @UPDATE@, or other SQL query that is not
-- expected to return results.
--
-- Returns the number of rows affected.
--
-- Throws 'FormatError' if the query could not be formatted correctly.
executeMany :: (QueryParams q) => Connection -> Query -> [q] -> IO Int64
executeMany _ _ [] = return 0
executeMany conn q qs = do
  Base.query conn =<< formatMany conn q qs
  finishExecute q conn

finishExecute :: Query -> Connection -> IO Int64
finishExecute q conn = do
  ncols <- Base.fieldCount (Left conn)
  if ncols /= 0
    then throw $ QueryError ("execute resulted in " ++ show ncols ++
                             "-column result") q
    else Base.affectedRows conn

-- | Perform a @SELECT@ or other SQL query that is expected to return
-- results.
--
-- All results are retrieved and converted before this function
-- returns.
--
-- Exceptions that may be thrown:
--
-- * 'FormatError': the query string could not be formatted correctly.
--
-- * 'QueryError': the result contains no columns (i.e. you should be
--   using 'execute' instead of 'query').
--
-- * 'ResultError': result conversion failed.
query :: (QueryParams q, QueryResults r)
         => Connection -> Query -> q -> IO [r]
query conn template qs = do
  Base.query conn =<< formatQuery conn template qs
  finishQuery template conn

-- | A version of 'query' that does not perform query substitution.
query_ :: (QueryResults r) => Connection -> Query -> IO [r]
query_ conn q@(Query que) = do
  Base.query conn que
  finishQuery q conn

finishQuery :: (QueryResults r) => Query -> Connection -> IO [r]
finishQuery q conn = do
  r <- Base.storeResult conn
  ncols <- Base.fieldCount (Right r)
  if ncols == 0
    then throw $ QueryError "query resulted in zero-column result" q
    else do
      fs <- Base.fetchFields r
      flip fix [] $ \loop acc -> do
        row <- Base.fetchRow r
        case row of
          [] -> return (reverse acc)
          _  -> let !c = convertResults fs row
                in loop (c:acc)

-- | Execute an action inside a SQL transaction.
--
-- You are assumed to have started the transaction yourself.
--
-- If your action succeeds, the transaction will be 'Base.commit'ted
-- before this function returns.
--
-- If your action throws any exception (not just a SQL exception), the
-- transaction will be rolled back 'Base.rollback' before the
-- exception is propagated.
withTransaction :: Connection -> IO a -> IO a
withTransaction conn act = do
  r <- act `onException` Base.rollback conn
  Base.commit conn
  return r

fmtError :: String -> Query -> [Action] -> a
fmtError msg q xs = throw FormatError {
                      fmtMessage = msg
                    , fmtQuery = q
                    , fmtParams = map twiddle xs
                    }
  where twiddle (Plain b)  = toByteString b
        twiddle (Escape s) = s
        twiddle (Many ys)  = B.concat (map twiddle ys)

-- $use
--
-- SQL-based applications are somewhat notorious for their
-- susceptibility to attacks through the injection of maliciously
-- crafted data. The primary reason for widespread vulnerability to
-- SQL injections is that many applications are sloppy in handling
-- user data when constructing SQL queries.
--
-- This library provides a 'Query' type and a parameter substitution
-- facility to address both ease of use and security.

-- $querytype
-- 
-- A 'Query' is a @newtype@-wrapped 'ByteString'. It intentionally
-- exposes a tiny API that is not compatible with the 'ByteString'
-- API; this makes it difficult to construct queries from fragments of
-- strings.  The 'query' and 'execute' functions require queries to be
-- of type 'Query'.
--
-- To most easily construct a query, enable GHC's @OverloadedStrings@
-- language extension and write your query as a normal literal string.
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- >
-- > import Database.MySQL.Simple
-- >
-- > hello = do
-- >   conn <- connect defaultConnectInfo
-- >   query conn "select 2 + 2"
--
-- A 'Query' value does not represent the actual query that will be
-- executed, but is a template for constructing the final query.

-- $subst
--
-- Since applications need to be able to construct queries with
-- parameters that change, this library provides a query substitution
-- capability.
--
-- The 'Query' template accepted by 'query' and 'execute' can contain
-- any number of \"@?@\" characters.  Both 'query' and 'execute'
-- accept a third argument, typically a tuple. When constructing the
-- real query to execute, these functions replace the first \"@?@\" in
-- the template with the first element of the tuple, the second
-- \"@?@\" with the second element, and so on. If necessary, each
-- tuple element will be quoted and escaped prior to substitution;
-- this defeats the single most common injection vector for malicious
-- data.
--
-- For example, given the following 'Query' template:
--
-- > select * from user where first_name = ? and age > ?
--
-- And a tuple of this form:
--
-- > ("Boris" :: String, 37 :: Int)
--
-- The query to be executed will look like this after substitution:
--
-- > select * from user where first_name = 'Boris' and age > 37
--
-- If there is a mismatch between the number of \"@?@\" characters in
-- your template and the number of elements in your tuple, a
-- 'FormatError' will be thrown.
--
-- Note that the substitution functions do not attempt to parse or
-- validate your query. It's up to you to write syntactically valid
-- SQL, and to ensure that each \"@?@\" in your query template is
-- matched with the right tuple element.

-- $inference
--
-- Automated type inference means that you will often be able to avoid
-- supplying explicit type signatures for the elements of a tuple.
-- However, sometimes the compiler will not be able to infer your
-- types. Consider a care where you write a numeric literal in a
-- parameter tuple:
--
-- > query conn "select ? + ?" (40,2)
--
-- The above query will be rejected by the compiler, because it does
-- not know the specific numeric types of the literals @40@ and @2@.
-- This is easily fixed:
--
-- > query conn "select ? + ?" (40 :: Double, 2 :: Double)
--
-- The same kind of problem can arise with string literals if you have
-- the @OverloadedStrings@ language extension enabled.  Again, just
-- use an explicit type signature if this happens.

-- $only
--
-- Haskell lacks a single-element tuple type, so if you have just one
-- value you want substituted into a query, what should you do?
--
-- The obvious approach would appear to be something like this:
--
-- > instance (Param a) => QueryParam a where
-- >     ...
--
-- Unfortunately, this wreaks havoc with type inference, so we take a
-- different tack. To represent a single value @val@ as a parameter, write
-- a singleton list @[val]@, use 'Just' @val@, or use 'Only' @val@.
--
-- Here's an example using a singleton list:
--
-- > execute conn "insert into users (first_name) values (?)"
-- >              ["Nuala"]

-- $in
--
-- Suppose you want to write a query using an @IN@ clause:
--
-- > select * from users where first_name in ('Anna', 'Boris', 'Carla')
--
-- In such cases, it's common for both the elements and length of the
-- list after the @IN@ keyword to vary from query to query.
--
-- To address this case, use the 'In' type wrapper, and use a single
-- \"@?@\" character to represent the list.  Omit the parentheses
-- around the list; these will be added for you.
--
-- Here's an example:
--
-- > query conn "select * from users where first_name in ?" $
-- >       In ["Anna", "Boris", "Carla"]
--
-- If your 'In'-wrapped list is empty, the string @\"(null)\"@ will be
-- substituted instead, to ensure that your clause remains
-- syntactically valid.

-- $many
--
-- If you know that you have many rows of data to insert into a table,
-- it is much more efficient to perform all the insertions in a single
-- multi-row @INSERT@ statement than individually.
--
-- The 'executeMany' function is intended specifically for helping
-- with multi-row @INSERT@ and @UPDATE@ statements. Its rules for
-- query substitution are different than those for 'execute'.
--
-- What 'executeMany' searches for in your 'Query' template is a
-- single substring of the form:
--
-- > values (?,?,?)
--
-- The rules are as follows:
--
-- * The keyword @VALUES@ is matched case insensitively.
--
-- * There must be no other \"@?@\" characters anywhere in your
--   template.
--
-- * There must one or more \"@?@\" in the parentheses.
--
-- * Extra white space is fine.
--
-- The last argument to 'executeMany' is a list of parameter
-- tuples. These will be substituted into the query where the @(?,?)@
-- string appears, in a form suitable for use in a multi-row @INSERT@
-- or @UPDATE@..
--
-- Here is an example:
--
-- > executeMany conn
-- >   "insert into users (first_name,last_name) values (?,?)"
-- >   [("Boris","Karloff"),("Ed","Wood")]
--
-- The query that will be executed here will look like this
-- (reformatted for tidiness):
--
-- > insert into users (first_name,last_name) values
-- >   ('Boris','Karloff'),('Ed','Wood')
