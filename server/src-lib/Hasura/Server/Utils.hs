module Hasura.Server.Utils where

import qualified Database.PG.Query.Connection as Q

import           Data.Aeson
import           Data.List.Split
import           Network.URI
import           System.Exit
import           System.Process

import qualified Data.ByteString              as B
import qualified Data.HashSet                 as Set
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as TE
import qualified Data.Text.Encoding.Error     as TE
import qualified Data.Text.IO                 as TI
import qualified Language.Haskell.TH.Syntax   as TH
import qualified Network.HTTP.Types           as HTTP
import qualified Text.Ginger                  as TG
import qualified Text.Regex.TDFA              as TDFA
import qualified Text.Regex.TDFA.ByteString   as TDFA

import           Hasura.Prelude

jsonHeader :: (T.Text, T.Text)
jsonHeader = ("Content-Type", "application/json; charset=utf-8")

userRoleHeader :: T.Text
userRoleHeader = "x-hasura-role"

deprecatedAccessKeyHeader :: T.Text
deprecatedAccessKeyHeader = "x-hasura-access-key"

adminSecretHeader :: T.Text
adminSecretHeader = "x-hasura-admin-secret"

userIdHeader :: T.Text
userIdHeader = "x-hasura-user-id"

bsToTxt :: B.ByteString -> T.Text
bsToTxt = TE.decodeUtf8With TE.lenientDecode

-- Parsing postgres database url
-- from: https://github.com/futurice/postgresql-simple-url/
parseDatabaseUrl :: String -> Maybe String -> Maybe Q.ConnInfo
parseDatabaseUrl databaseUrl opts = parseURI databaseUrl >>= uriToConnectInfo opts

uriToConnectInfo :: Maybe String -> URI -> Maybe Q.ConnInfo
uriToConnectInfo opts uri
  | uriScheme uri /= "postgres:" && uriScheme uri /= "postgresql:" = Nothing
  | otherwise = ($ Q.defaultConnInfo {Q.connOptions = opts}) <$> mkConnectInfo uri

type ConnectInfoChange = Q.ConnInfo -> Q.ConnInfo

mkConnectInfo :: URI -> Maybe ConnectInfoChange
mkConnectInfo uri = case uriPath uri of
                           ('/' : rest) | not (null rest) -> Just $ uriParameters uri
                           _                              -> Nothing

uriParameters :: URI -> ConnectInfoChange
uriParameters uri = (\info -> info { Q.connDatabase = tail $ uriPath uri }) . maybe id uriAuthParameters (uriAuthority uri)

dropLast :: [a] -> [a]
dropLast []     = []
dropLast [_]    = []
dropLast (x:xs) = x : dropLast xs

uriAuthParameters :: URIAuth -> ConnectInfoChange
uriAuthParameters uriAuth = port . host . auth
  where port = case uriPort uriAuth of
                 (':' : p) -> \info -> info { Q.connPort = read p }
                 _         -> id
        host = case uriRegName uriAuth of
                 h  -> \info -> info { Q.connHost = unEscapeString h }
        auth = case splitOn ":" (uriUserInfo uriAuth) of
                 [""]   -> id
                 [u]    -> \info -> info { Q.connUser = unEscapeString $ dropLast u }
                 [u, p] -> \info -> info { Q.connUser = unEscapeString u, Q.connPassword = unEscapeString $ dropLast p }
                 _      -> id

-- Running shell script during compile time
runScript :: FilePath -> TH.Q TH.Exp
runScript fp = do
  TH.addDependentFile fp
  fileContent <- TH.runIO $ TI.readFile fp
  (exitCode, stdOut, stdErr) <- TH.runIO $
    readProcessWithExitCode "/bin/sh" [] $ T.unpack fileContent
  when (exitCode /= ExitSuccess) $ fail $
    "Running shell script " ++ fp ++ " failed with exit code : "
    ++ show exitCode ++ " and with error : " ++ stdErr
  TH.lift stdOut

-- Ginger Templating
type GingerTmplt = TG.Template TG.SourcePos

parseGingerTmplt :: TG.Source -> Either String GingerTmplt
parseGingerTmplt src = either parseE Right res
  where
    res = runIdentity $ TG.parseGinger' parserOptions src
    parserOptions = TG.mkParserOptions resolver
    resolver = const $ return Nothing
    parseE e = Left $ TG.formatParserError (Just "") e

renderGingerTmplt :: (ToJSON a) => a -> GingerTmplt -> T.Text
renderGingerTmplt v = TG.easyRender (toJSON v)

-- find duplicates
duplicates :: Ord a => [a] -> [a]
duplicates = mapMaybe greaterThanOne . group . sort
  where
    greaterThanOne l = bool Nothing (Just $ head l) $ length l > 1

_1 :: (a, b, c) -> a
_1 (x, _, _) = x

_2 :: (a, b, c) -> b
_2 (_, y, _) = y

_3 :: (a, b, c) -> c
_3 (_, _, z) = z

-- regex related
matchRegex :: B.ByteString -> Bool -> T.Text -> Either String Bool
matchRegex regex caseSensitive src =
  fmap (`TDFA.match` TE.encodeUtf8 src) compiledRegexE
  where
    compOpt = TDFA.defaultCompOpt
      { TDFA.caseSensitive = caseSensitive
      , TDFA.multiline = True
      , TDFA.lastStarGreedy = True
      }
    execOption = TDFA.defaultExecOpt {TDFA.captureGroups = False}
    compiledRegexE = TDFA.compile compOpt execOption regex


fmapL :: (a -> a') -> Either a b -> Either a' b
fmapL fn (Left e) = Left (fn e)
fmapL _ (Right x) = pure x


-- ignore the following request headers from the client
filterRequestHeaders :: [HTTP.Header] -> [HTTP.Header]
filterRequestHeaders = filterHeaders reqHeaders
  where
    reqHeaders = Set.fromList
                 [ "Content-Length", "Content-MD5", "User-Agent", "Host"
                 , "Origin", "Referer" , "Accept", "Accept-Encoding"
                 , "Accept-Language", "Accept-Datetime"
                 , "Cache-Control", "Connection", "DNT"
                 ]


-- ignore the following response headers from remote
filterResponseHeaders :: [HTTP.Header] -> [HTTP.Header]
filterResponseHeaders = filterHeaders respHeaders
  where
    respHeaders = Set.fromList
                  [ "Server", "Transfer-Encoding", "Cache-Control"
                  , "Access-Control-Allow-Credentials"
                  , "Access-Control-Allow-Methods"
                  , "Access-Control-Allow-Origin"
                  , "Content-Type"
                  ]

filterHeaders :: Set.HashSet HTTP.HeaderName -> [HTTP.Header] -> [HTTP.Header]
filterHeaders list = filter (\(n, _) -> not $ n `Set.member` list)
