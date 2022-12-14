{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module TestsForTypeDirectedGenerics (runAllTestsForTpypeDirectedGenerics) where

import Common.FGGParser
import Common.Utils
import TypeDirectedGeneric.Translation
import qualified TypeDirectedGeneric.TargetLanguage as TL
import System.FilePath
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Control.Monad
import Text.Groom
import Text.Regex.TDFA hiding (match)

data TestSpec
  = TypecheckGood
  | TypecheckBad T.Text
  | EvalGood T.Text
  | EvalBad T.Text

parseTestSpec :: T.Text -> Either String TestSpec
parseTestSpec t =
  if | t == "TYPECHECK_GOOD" -> Right TypecheckGood
     | otherwise ->
       withArg EvalGood "EVAL_GOOD:" $
       withArg TypecheckBad "TYPECHECK_BAD:" $
       withArg EvalBad "EVAL_BAD:" $
       Left "invalid spec"
  where
    withArg :: (T.Text -> TestSpec)
            -> T.Text
            -> Either String TestSpec
            -> Either String TestSpec
    withArg f status next =
      case T.stripPrefix status t of
        Nothing -> next
        Just status -> Right (f (removeNoise status))

removeNoise :: T.Text -> T.Text
removeNoise (T.strip -> t) =
  let matches = map T.pack $ getAllTextMatches (T.unpack t =~ ("#<procedure:[^>]*>" :: String))
  in foldr (\m t -> T.replace m "#<procedure>" t) t matches

reportOk :: FilePath -> String -> IO ()
reportOk path msg = putStrLn $ "OK " ++ path ++ ": " ++ msg

reportError :: FilePath -> String -> [T.Text] -> IO ()
reportError path msg trace = do
  putStrLn ("ERROR " ++ path ++ ": " ++ msg)
  outputTrace trace
  fail "Test ERROR"

match :: T.Text -> T.Text -> Bool
match x t = x `T.isInfixOf` t

runTestForSpec :: FilePath -> TestSpec -> IO ()
runTestForSpec path spec = do
  let parseCfg = ParserConfig OldstyleGenerics
  prog <- parseFile path parseCfg
  let (result, trace) = runTranslation' prog
  case result of
    Left err ->
      case spec of
        TypecheckBad x ->
          if match x (T.pack err)
          then reportOk path "failed to typecheck as expected"
          else reportError path
                   ("failed to typecheck with unexpected error.\n" ++
                    "ERROR:  " ++ err ++ "\n" ++
                    "EXPECT: " ++ T.unpack x)
                   trace
        _ ->
          reportError path ("failed to typecheck but should succeed") trace
    Right racketProg ->
      case spec of
        TypecheckBad _ ->
          reportError path ("typechecked but should fail") trace
        TypecheckGood ->
          reportOk path ("typechecked as expected")
        EvalGood r -> checkEval racketProg (Right r)
        EvalBad r -> checkEval racketProg (Left r)
  where
    checkEval :: TL.Prog -> Either T.Text T.Text -> IO ()
    checkEval racketProg expectedResult = do
      let outFile = "/tmp/fgg-target"
      writeFile (outFile ++ ".txt") (groom racketProg)
      result <- TL.evalProg (outFile ++ ".rkt") stdlibForTrans racketProg
      case (expectedResult, result) of
        (Right x, Right (removeNoise -> t)) ->
          if T.strip x == T.strip t
          then reportOk path ("evaluated successful as expected")
          else reportError path
                 ("evaluated successful but to an unexpected result.\n" ++
                  "RESULT: " ++ T.unpack t ++ "\n" ++
                  "EXPECT: " ++ T.unpack x)
                 []
        (Right _, Left err) ->
          reportError path ("evaluation failed but should succeed: " ++ T.unpack err) []
        (Left x, Left err) ->
          if match x err
          then reportOk path ("evaluated failed as expected")
          else reportError path
                 ("evaluated failed but with an unexpected error.\n" ++
                  "ERROR:  " ++ T.unpack err ++ "\n" ++
                  "EXPECT: " ++ T.unpack x)
                 []
        (Left _, Right t) ->
          reportError path ("evaluation succeeded but should fail. Result: " ++ T.unpack t) []

runTest :: FilePath -> IO ()
runTest path = do
  src <- T.readFile path
  firstLine <- case T.lines src of
    [] -> fail ("File " ++ path ++ " is empty")
    (x:_) -> pure x
  case T.stripPrefix "/// TEST " (T.strip firstLine) of
    Nothing -> fail ("File " ++ path ++ " does not have to magic test header in the first line")
    Just spec ->
      case parseTestSpec spec of
        Left err -> fail ("Invalid test spec in first line of " ++ path ++ ": " ++ err)
        Right spec -> runTestForSpec path spec

runAllTestsForTpypeDirectedGenerics :: IO ()
runAllTestsForTpypeDirectedGenerics = do
  testFiles <-
    filter (\fp -> takeExtension fp `elem` [".fg", ".fgg"]) <$>
    traverseDir testDir
  when (length testFiles == 0) $
    fail ("No test files found in " ++ testDir)
  mapM_ runTest testFiles
  where
    testDir = "test-files/type-directed-generics"
