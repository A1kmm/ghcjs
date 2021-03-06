{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExtendedDefaultRules      #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TupleSections             #-}
{-
  A cabal-install wrapper for GHCJS
  - invokes cabal-install with the correct arguments to build ghcjs packages
  - uses the GHCJS cache to install .js files for installed packages
     (temporary fix until proper GHCJS support is merged into the Cabal library)
-}

module Main where

import           Prelude                hiding (FilePath, catch)

import           System.Exit            (exitWith)
import           System.Process         (rawSystem, readProcess)

import           Crypto.Skein
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8  as C8
import           Data.Char              (isSpace)
import           Data.Maybe             (catMaybes, fromMaybe)
import           Filesystem.Path        (dropExtension, empty, extension)
import           Shelly
import           System.Directory       (getModificationTime)
#if MIN_VERSION_directory(1,2,0)
import           Data.Time              (UTCTime)
#endif
import           Control.Monad          (forM_)
import           Data.List              (isPrefixOf)
import qualified Data.Map               as M
import           Data.Monoid            (mappend)
import qualified Data.Text              as T
import qualified Data.Text.Lazy         as L
import           System.Environment     (getArgs)

import           Compiler.Info
import           Control.Exception      (SomeException, catch)
import           Crypto.Conduit         (hashFile)
import qualified Data.Serialize         as C
import           System.Directory       (createDirectoryIfMissing,
                                         getAppUserDataDirectory,
                                         removeDirectoryRecursive)

import           Compiler.Info
import           Compiler.Variants

default (L.Text)
(<>) = mappend

extraArgs = do
  prefix <- getAppUserDataDirectory "ghcjs-cabal"
  return [ "--with-compiler=ghcjs"
         , "--with-hc-pkg=ghcjs-pkg"
         , "--with-hsc2hs=hsc2hs"
         , "--disable-documentation"
         , "--prefix=" <> prefix <> "/" <> getGhcjsCompilerVersion
         , "--bindir=" <> prefix <> "/" <> "bin"
         ]

main :: IO ()
main = do
  emptyCache
  args <- getArgs
  extra <- extraArgs
  ec <- if any (`elem` ["install", "configure"]) args
    then rawSystem "cabal" (extra ++ args)
    else rawSystem "cabal" args
  installFromCache
  exitWith ec

emptyCache :: IO ()
emptyCache = do
  cache <- getGlobalCache
  removeDirectoryRecursive cache `catch` (\(_::SomeException) -> return ())
  createDirectoryIfMissing True cache `catch` (\(_::SomeException) -> return ())

{-
   install from cache:
   1. search package dirs for .hi files without accompanying .js
   2. calculate skein hash for .hi file
   3. copy [skein].js file from the cache
-}
installFromCache :: IO ()
installFromCache = do
  hiFiles <- collectHiFiles
  cache <- fmap fromString getGlobalCache
  mapM_ (installCachedFile cache) hiFiles

-- fixme: should we also handle .hi_dyn ?
installCachedFile :: FilePath -> FilePath -> IO ()
installCachedFile cache hiFile = do
  (hash :: Skein_512_512) <- hashFile (toString hiFile ++ ".hi")
  let hns = hashedNames cache hash
  shelly $ forM_ hns $ \(hne, hn) -> do
    e <- test_f hn
    when e $ cp hn (hiFile `addExt` hne)

hashedNames :: FilePath -> Skein_512_512 -> [(String, FilePath)]
hashedNames cache hash = map (\v -> let ve = variantExtension v in (ve, base `addExt` ve)) variants
    where
      base     = cache </> fromString basename
      basename = C8.unpack . B16.encode . C.encode $ hash

collectHiFiles :: IO [FilePath]
collectHiFiles = do
  importDirs <- allImportDirs
  fmap concat $ mapM (fmap collectLonelyHi . allFiles . fromString) importDirs

#if MIN_VERSION_directory(1,2,0)
allFiles :: FilePath -> IO [(FilePath, UTCTime)]
#endif
allFiles fp = do
  files <- shelly $ find fp
  mapM addModificationTime files

#if MIN_VERSION_directory(1,2,0)
addModificationTime :: FilePath -> IO (FilePath, UTCTime)
#endif
addModificationTime file = fmap (file,) $ getModificationTime (toString file)

-- paths of .hi files without corresponding .js files (without extension)
-- .js files older than the .hi file are counted as missing (reinstalls!)
#if MIN_VERSION_directory(1,2,0)
collectLonelyHi :: [(FilePath,UTCTime)] -> [FilePath]
#endif
collectLonelyHi files = map fst $ filter isLonely his
    where
      allMap = M.fromList files
      his    = catMaybes $ map (\(f,m) -> fmap (,m) $ retrieveBase "hi" f) files
      isLonely hi = any (variantMissing hi) variants
      variantMissing (hi, him) v = let ve = variantExtension v
                                   in  fromMaybe True $ do
                                         jsm <- M.lookup (hi `addExt` ve) allMap
                                         return (jsm < him)

addExt :: FilePath -> String -> FilePath
addExt fp e = fp <.> L.pack (tail e)


retrieveBase :: T.Text -> FilePath -> Maybe FilePath
retrieveBase ext path
    | extension path == Just ext = Just (dropExtension path)
    | otherwise                  = Nothing
    where

-- read the import dirs of all installed ghcjs packages
-- fixme: this is not a proper parser, fails for multiline import-dirs, but seems to work on cabal output
allImportDirs :: IO [String]
allImportDirs = do
  out <- readProcess "ghcjs-pkg" ["dump"] ""
  return $ filter (not.null) $ concatMap getImportDir $ lines out
      where
        prefix = "import-dirs:" :: String
        getImportDir line
          | prefix `isPrefixOf` line = [trim $ drop (length prefix) line]
          | otherwise                        = []



trim :: String -> String
trim = let f = reverse . dropWhile isSpace in f . f

fromString :: String -> FilePath
fromString = fromText . L.pack

toString :: FilePath -> String
toString = L.unpack . toTextIgnore

