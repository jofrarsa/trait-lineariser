module Main where

import Prelude hiding                        (getContents, readFile, writeFile)

import Control.Exception

import Control.Applicative
import Control.Monad
import Control.Lens

import Data.Traversable
import Data.Foldable
import Data.List
import Data.Maybe
import qualified Data.HashMap.Strict as HashMap

import Data.String.Here.Interpolated
import Data.String.Here.Uninterpolated
import Data.Text                             (Text)
import qualified Data.Text.IO as Text
import qualified Data.Text as Text

import Data.Encoding.Exception               (DecodingException)
import Data.Encoding.UTF8
import Data.Encoding.CP1252

import Text.Megaparsec

import System.Exit                           (exitFailure)
import System.FilePath                       ((</>), takeExtension)
import System.Directory                      (listDirectory)
import System.IO.Encoding                    (getContents, readFile, writeFile)

import qualified Options.Applicative as Args

import Control.Concurrent.Async
import System.Console.Concurrent
import System.Console.Regions

import Types -- TODO remove
import Traits
import Localisation

noteBriefly :: String -> IO ()
noteBriefly = outputConcurrent

note :: String -> IO ()
note = noteBriefly . (<> "\n")

note' :: [String] -> IO ()
note' = note . mconcat

noteFailure :: String -> IO noreturn
noteFailure message = note message *> exitFailure

-- | Read a game or mod file. Uses the CP1252 encoding that Victoria II expects.
fileContents :: FilePath -> IO Text
fileContents path = do
    let ?enc = CP1252
    -- N.b., System.IO.Encoding functions report decoding errors as pure exceptions
    --          vvvvvvvvvvvv
    unicode <- (evaluate =<< readFile path) `catch` decodingError
    pure $! Text.pack unicode

      where
        decodingError :: DecodingException -> IO String
        decodingError err = do
            note [iTrim|
Decoding of one localisation file failed, skipping it:
    ‘${ path }’: ${err}
|]
            -- We get away with this because the empty string is valid and corresponds to empty
            -- localisation with no entries.
            pure ""

parseArgs :: IO (Maybe FilePath, [FilePath])
parseArgs = Args.execParser $ Args.info (Args.helper <*> args) desc
  where
    args = (,) <$> modPath <*> extraLoc

    modPath = optional . Args.argument Args.str $
        Args.help [iTrim|
            Base path of the mod of interest. From this path, the traits file is expected to be
            located at `common/traits.txt`. (If the mod is not yet providing a traits file, you
            should copy over the unmodded traits file.)

            Additionally, localisation files are expected to be located in the `location`
            subdirectory. Localisation keys for each of the trait are required to be present there
            in order for the linearised localisation to be produced. If this is not already the
            case, consider temporarily copying unmodded localisation files.

            The current working directory is assumed if the path is not provided. All files will be
            assumed to be using the WINDOWS-1252 encoding that the game expects.
            |]
        <> Args.metavar "PATH/TO/MOD"

    extraLoc = Args.many $ Args.strOption $
        Args.long "extra-localisation"
        <> Args.short 'x'
        <> Args.help [iTrim|
            Extra base paths. They will be used for the purpose of collating localisation. It can be
            useful to include the path to the game installation this way.
            |]
        <> Args.metavar "another/base/path"

    desc =
        Args.fullDesc
        <> Args.progDesc [iTrim|
            Linearise the personalities and backgrounds that generals and admirals can have. Output
            consists of a `traits.txt` file containing linearised traits, and a `traits.csv` file
            containing localisation keys. Both files will be output to the current working
            directory.
            |]

main :: IO ()
main = displayConsoleRegions $ do
    (modPath, extraPaths) <- over _1 (fromMaybe ".") <$> parseArgs

    let traitsPath = modPath </> "common" </> "traits.txt"
        -- N.b. order is significant, see below.
        paths      = modPath:extraPaths

        localisationPath base      = base </> "localisation"
        localisationFile base path = localisationPath base </> path

    traitsContent <- fileContents traitsPath

    when (lineariserHeader `Text.isPrefixOf` traitsContent) $ do
        noteFailure [iTrim|
Traits file ‘${traitsPath}’ seems to already have been auto-generated by this program, aborting. If
you still want to attempt to linearise the file, remove the auto-generation header:

${ Text.unpack lineariserHeader }
|]

    traits <- case runParser traitsStructure traitsPath traitsContent of
        Left errs -> do
            noteFailure [iTrim|
Parsing of traits file failed:

${ errorBundlePretty errs }
|]

        Right traits -> do
            let personalities = length $ _traitsPersonalities traits
                backgrounds   = length $ _traitsBackgrounds traits

            for_ [ ("personality", personalities)
                 , ("background", backgrounds)
                 ] $ \(kind, count) -> when (count == 1) $ do
                      noteFailure [iTrim|
Nothing to linearise as there is only one ${kind::String}, aborting. (Did you run the program on an
already linearised trait file?)
|]

            note' [ [i|Found ${personalities} personalities and ${backgrounds} backgrounds,|]
                  , [i| linearising to ${ personalities * backgrounds } composite traits.|]
                  ]

            pure traits

    let (personalities, backgrounds) = traitsLocalisationKeys traits

    localisation <- fmap (HashMap.unions . concat) . forConcurrently paths $ \base ->
        withConsoleRegion Linear $ \region -> do
            let regionOpener = [i|Adding localisation from base path ‘${base}’…|] :: String
            setConsoleRegion region regionOpener

            let pickCSVs = filter csvExtension
                csvExtension = (== ".csv") . takeExtension

            -- N.b. order is very significant. The key that appears in the first file in lexical[1]
            -- order is the one that sets the translation, subsequent ones are redundant.
            --
            -- [1]: presumably, at any rate, since this has not been tested in depth
            locFiles <- (sort . pickCSVs) <$> listDirectory (localisationPath base)

            finishConsoleRegion region $ regionOpener
                <> [i| found ${ length locFiles } localisation files.|]

            forConcurrently locFiles $ \path -> do
                contents <- fileContents $ localisationFile base path
                case runParser localisations path contents of
                    Left errs -> do
                        note [iTrim|
    Parsing of one localisation file failed, skipping it:
    ${ errorBundlePretty errs }
    |]
                        pure mempty

                    Right keys -> pure keys

    note [iTrim|Found ${ HashMap.size localisation } localisation entries.|]

    let (orphans, entries) = lineariseLocalisation localisation personalities backgrounds

    note [iTrim|The following could not be translated:
    ${ Text.unpack . Text.intercalate ", " $ toList orphans }
|]

    let ?enc = CP1252
    writeFile "traits.txt" . Text.unpack . formatTraits       $ lineariseTraits traits
    writeFile "traits.csv" . Text.unpack . formatLocalisation $ entries
