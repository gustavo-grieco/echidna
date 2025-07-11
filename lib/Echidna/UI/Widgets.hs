{-# LANGUAGE CPP #-}

module Echidna.UI.Widgets where

import Brick hiding (style)
import Brick.AttrMap qualified as A
import Brick.Widgets.Border
import Brick.Widgets.Center
import Brick.Widgets.Dialog qualified as B
import Control.Monad.Reader (MonadReader, asks, ask)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.ST (RealWorld)
import Data.List (nub, intersperse, sortBy)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, isJust, fromJust)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.String.AnsiEscapeCodes.Strip.Text (stripAnsiEscapeCodes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (LocalTime, NominalDiffTime, formatTime, defaultTimeLocale, diffLocalTime)
import Data.Version (showVersion)
import Graphics.Vty qualified as V
import Paths_echidna qualified (version)
import Text.Printf (printf)
import Text.Wrap

import Echidna.ABI
import Echidna.Types.Campaign
import Echidna.Types.Config
import Echidna.Types.Test
import Echidna.Types.Tx (Tx(..))
import Echidna.UI.Report
import Echidna.Utility (timePrefix)

import EVM.Format (showTraceTree)
import EVM.Types (Addr, Contract, W256, VM(..), VMType(Concrete))

data UIState = UIState
  { status :: UIStateStatus
  , campaigns :: [WorkerState]
  , timeStarted :: LocalTime
  , timeStopped :: Maybe LocalTime
  , now :: LocalTime
  , slitherSucceeded :: Bool
  , fetchedContracts :: Map Addr (Maybe Contract)
  , fetchedSlots :: Map Addr (Map W256 (Maybe W256))
  , fetchedDialog :: B.Dialog () Name
  , displayFetchedDialog :: Bool
  , displayLogPane :: Bool
  , displayTestsPane :: Bool
  , focusedPane :: FocusedPane

  , events :: Seq (LocalTime, CampaignEvent)
  , workersAlive :: Int

  , corpusSize :: Int
  , coverage :: Int
  , numCodehashes :: Int
  , lastNewCov :: LocalTime
  -- ^ last timestamp of 'NewCoverage' event

  , campaignWidget :: Widget Name
  -- ^ Pre-computed widget to avoid IO in drawing

  , tests :: [EchidnaTest]
  }

data UIStateStatus = Uninitialized | Running

data FocusedPane = TestsPane | LogPane
  deriving (Eq)

attrs :: A.AttrMap
attrs = A.attrMap (V.white `on` V.black)
  [ (attrName "alert", fg V.brightRed `V.withStyle` V.blink `V.withStyle` V.bold)
  , (attrName "failure", fg V.brightRed)
  , (attrName "maximum", fg V.brightBlue)
  , (attrName "bold", fg V.white `V.withStyle` V.bold)
  , (attrName "tx", fg V.brightWhite)
  , (attrName "working", fg V.brightBlue)
  , (attrName "success", fg V.brightGreen)
  , (attrName "title", fg V.brightYellow `V.withStyle` V.bold)
  , (attrName "subtitle", fg V.brightCyan `V.withStyle` V.bold)
  , (attrName "time", fg (V.rgbColor (0x70 :: Int) 0x70 0x70))
  ]

bold :: Widget n -> Widget n
bold = withAttr (attrName "bold")

alert :: Widget n -> Widget n
alert = withAttr (attrName "alert")

failure :: Widget n -> Widget n
failure = withAttr (attrName "failure")

success :: Widget n -> Widget n
success = withAttr (attrName "success")

data Name
  = LogViewPort
  | TestsViewPort
  | SBClick ClickableScrollbarElement Name
  deriving (Ord, Show, Eq)

-- | Render 'Campaign' progress as a 'Widget'.
campaignStatus :: (MonadReader Env m, MonadIO m) => UIState -> m (Widget Name)
campaignStatus uiState = do
  tests <- testsWidget uiState.tests

  if uiState.workersAlive == 0 then
    mainbox tests (finalStatus "Campaign complete, C-c or esc to exit")
  else
    case uiState.status of
      Uninitialized ->
        mainbox (padLeft (Pad 1) $ str "Starting up, please wait...") emptyWidget
      Running ->
        mainbox tests emptyWidget
  where
  mainbox inner underneath = do
    env <- ask
    pure $ hCenter . hLimit 160 $
      joinBorders $ borderWithLabel (echidnaTitle env.cfg.projectName) $
      summaryWidget env uiState
      <=>
      (if uiState.displayTestsPane then
        hBorderWithLabel testsTitle
        <=>
        inner
      else emptyWidget)
      <=>
      (if uiState.displayLogPane then
        hBorderWithLabel logTitle
        <=>
        logPane uiState
      else emptyWidget)
      <=>
      underneath
  echidnaTitle projectName =
    let projectTitle = case projectName of
          Just name -> " (" <> T.unpack name <> ")"
          Nothing -> ""
    in str "[ " <+>
       withAttr (attrName "title")
         (str $ "Echidna " <> showVersion Paths_echidna.version <> projectTitle) <+>
       str " ]"
  finalStatus s = hBorder <=> hCenter (bold $ str s)
  testsTitle =
    withAttr (attrName "subtitle") $ str $
    " Tests (" <> show (length uiState.tests) <> ") " <>
    if uiState.focusedPane == TestsPane then "[*]" else ""
  logTitle =
    withAttr (attrName "subtitle") $ str $
    " Log (" <> show (length uiState.events) <> ") " <>
    if uiState.focusedPane == LogPane then "[*]" else ""

logPane :: UIState -> Widget Name
logPane uiState =
  vLimitPercent 33 .
  padLeft (Pad 1) $
  withClickableVScrollBars SBClick .
  withVScrollBars OnRight .
  withVScrollBarHandles .
  viewport LogViewPort Vertical $
  foldl (<=>) emptyWidget (showLogLine <$> Seq.reverse uiState.events)

showLogLine :: (LocalTime, CampaignEvent) -> Widget Name
showLogLine (time, event@(WorkerEvent workerId workerType _)) =
  withAttr (attrName "time") (str $ timePrefix time <> "[Worker " <> show workerId <> symSuffix <> "] ")
    <+> strBreak (ppCampaignEvent event)
  where
  symSuffix = case workerType of
    SymbolicWorker -> ", symbolic"
    _ -> ""
showLogLine (time, event) =
  withAttr (attrName "time") (str $ timePrefix time <> " ") <+> strBreak (ppCampaignEvent event)

summaryWidget :: Env -> UIState -> Widget Name
summaryWidget env uiState =
  vLimit 5 $ -- limit to 5 rows
    hLimitPercent 33 leftSide <+> vBorder <+>
    hLimitPercent 50 middle <+> vBorder <+>
    rightSide
  where
  leftSide =
    padLeft (Pad 1) $
      (str ("Time elapsed: " <> timeElapsed uiState uiState.timeStarted) <+> fill ' ')
      <=>
      (str "Workers: " <+> outOf uiState.workersAlive (length uiState.campaigns))
      <=>
      str ("Seed: " ++ ppSeed uiState.campaigns)
      <=>
      perfWidget uiState
      <=>
      gasPerfWidget uiState
      <=>
      str ("Total calls: " <> progress (sum $ (.ncalls) <$> uiState.campaigns)
                                     env.cfg.campaignConf.testLimit)
  middle =
    padLeft (Pad 1) $
      str ("Unique instructions: " <> show uiState.coverage)
      <=>
      str ("Unique codehashes: " <> show uiState.numCodehashes)
      <=>
      str ("Corpus size: " <> show uiState.corpusSize <> " seqs")
      <=>
      str ("New coverage: " <> timeElapsed uiState uiState.lastNewCov <> " ago") <+> fill ' '
      <=>
      slitherWidget uiState.slitherSucceeded
  rightSide =
    padLeft (Pad 1)
      (rpcInfoWidget uiState.fetchedContracts uiState.fetchedSlots env.chainId)

timeElapsed :: UIState -> LocalTime -> String
timeElapsed uiState since =
  formatNominalDiffTime $
    diffLocalTime (fromMaybe uiState.now uiState.timeStopped) since

formatNominalDiffTime :: NominalDiffTime -> String
formatNominalDiffTime diff =
  let fmt = if | diff < 60       -> "%Ss"
               | diff < 60*60    -> "%Mm %Ss"
               | diff < 24*60*60 -> "%Hh %Mm %Ss"
               | otherwise       -> "%dd %Hh %Mm %Ss"
  in formatTime defaultTimeLocale fmt diff

rpcInfoWidget
  :: Map Addr (Maybe Contract)
  -> Map Addr (Map W256 (Maybe W256))
  -> Maybe W256
  -> Widget Name
rpcInfoWidget contracts slots chainId =
  (str "Chain ID: " <+> str (maybe "-" show chainId))
  <=>
  (str "Fetched contracts: " <+> countWidget (Map.elems contracts))
  <=>
  (str "Fetched slots: " <+> countWidget (concat $ Map.elems (Map.elems <$> slots)))
  where
  countWidget fetches =
    let successful = filter isJust fetches
    in outOf (length successful) (length fetches)

slitherWidget
  :: Bool
  -> Widget Name
slitherWidget slitherSucceeded = if slitherSucceeded
  then success (str "Slither succeeded")
  else alert (str "No Slither in use!")

outOf :: Int -> Int -> Widget n
outOf n m =
  let style = if n == m then success else failure
  in style . str $ progress n m

perfWidget :: UIState -> Widget n
perfWidget uiState =
  str $ "Calls/s: " <>
    if totalTime > 0
       then show $ totalCalls `div` totalTime
       else "-"
  where
  totalCalls = sum $ (.ncalls) <$> uiState.campaigns
  totalTime = round $
    diffLocalTime (fromMaybe uiState.now uiState.timeStopped)
                  uiState.timeStarted

gasPerfWidget :: UIState -> Widget n
gasPerfWidget uiState =
  str $ "Gas/s: " <>
    if totalTime > 0
       then show $ totalGas `div` totalTime
       else "-"
  where
  totalGas = sum $ (.totalGas) <$> uiState.campaigns
  totalTime = round $
    diffLocalTime (fromMaybe uiState.now uiState.timeStopped)
                  uiState.timeStarted

fetchedDialogWidget :: UIState -> Widget Name
fetchedDialogWidget uiState =
  B.renderDialog uiState.fetchedDialog $ padLeftRight 1 $
    foldl (<=>) emptyWidget (Map.mapWithKey renderContract uiState.fetchedContracts)
  where
  renderContract addr (Just _code) =
    bold (str (show addr))
    <=>
    renderSlots addr
  renderContract addr Nothing =
    bold $ failure (str (show addr))
  renderSlots addr =
    foldl (<=>) emptyWidget $
      Map.mapWithKey renderSlot (fromMaybe mempty $ Map.lookup addr uiState.fetchedSlots)
  renderSlot slot (Just value) =
    padLeft (Pad 1) $ strBreak (show slot <> " => " <> show value)
  renderSlot slot Nothing =
    padLeft (Pad 1) $ failure $ str (show slot)

failedFirst :: EchidnaTest -> EchidnaTest -> Ordering
failedFirst t1 _ | didFail t1 = LT
                 | otherwise  = GT

testsWidget :: (MonadReader Env m, MonadIO m) => [EchidnaTest] -> m (Widget Name)
testsWidget tests' =
  withClickableVScrollBars SBClick .
  withVScrollBars OnRight .
  withVScrollBarHandles .
  viewport TestsViewPort Vertical .
  foldl (<=>) emptyWidget . intersperse hBorder <$>
    traverse testWidget (sortBy failedFirst tests')

testWidget :: (MonadReader Env m, MonadIO m) => EchidnaTest -> m (Widget Name)
testWidget test =
  case test.testType of
    Exploration          -> widget tsWidget "exploration" ""
    PropertyTest n _     -> widget tsWidget n ""
    OptimizationTest n _ -> widget optWidget n "optimizing "
    AssertionTest _ s _  -> widget tsWidget (encodeSig s) "assertion in "
    CallTest n _         -> widget tsWidget n ""
  where
  widget f n infront = do
    (status, details) <- f test.state test
    pure $ padLeft (Pad 1) $
      str infront <+> name n <+> str ": " <+> status
      <=> padTop (Pad 1) details
  name n = bold $ str (T.unpack n)

tsWidget
  :: (MonadReader Env m, MonadIO m)
  => TestState
  -> EchidnaTest
  -> m (Widget Name, Widget Name)
tsWidget (Failed e) _    = pure (str "could not evaluate", str $ show e)
tsWidget Solved     test = failWidget Nothing test
tsWidget Passed     _    = pure (success $ str "PASSED!", emptyWidget)
tsWidget Open       _    = pure (success $ str "passing", emptyWidget)
tsWidget (Large n)  test = do
  m <- asks (.cfg.campaignConf.shrinkLimit)
  failWidget (if n < m then Just (n,m) else Nothing) test

titleWidget :: Widget n
titleWidget = str "Call sequence" <+> str ":"

tracesWidget :: MonadReader Env m => VM Concrete RealWorld -> m (Widget n)
tracesWidget vm = do
  dappInfo <- asks (.dapp)
  -- TODO: showTraceTree does coloring with ANSI escape codes, we need to strip
  -- those because they break the Brick TUI. Fix in hevm so we can display
  -- colors here as well.
  let traces = stripAnsiEscapeCodes $ showTraceTree dappInfo vm
  pure $
    if T.null traces then str ""
    else str "Traces" <+> str ":" <=> txtBreak traces

failWidget
  :: (MonadReader Env m, MonadIO m)
  => Maybe (Int, Int)
  -> EchidnaTest
  -> m (Widget Name, Widget Name)
failWidget _ test | null test.reproducer =
  pure (failureBadge, str "*no transactions made*")
failWidget b test = do
  -- TODO: we know this is set for failed tests, ideally we should improve this
  -- with better types in EchidnaTest
  let vm = fromJust test.vm
  s <- seqWidget vm test.reproducer
  traces <- tracesWidget vm
  pure
    ( failureBadge <+> str (" with " ++ show test.result)
    , shrinkWidget b test <=> titleWidget <=> s <=> str " " <=> traces
    )

optWidget
  :: (MonadReader Env m, MonadIO m)
  => TestState
  -> EchidnaTest
  -> m (Widget Name, Widget Name)
optWidget (Failed e) _ = pure (str "could not evaluate", str $ show e)
optWidget Solved     _ = error "optimization tests cannot be solved"
optWidget Passed     t = pure (str $ "max value found: " ++ show t.value, emptyWidget)
optWidget Open       t =
  pure (withAttr (attrName "working") $ str $
    "optimizing, max value: " ++ show t.value, emptyWidget)
optWidget (Large n)  test = do
  m <- asks (.cfg.campaignConf.shrinkLimit)
  maxWidget (if n < m then Just (n,m) else Nothing) test

maxWidget
  :: (MonadReader Env m, MonadIO m)
  => Maybe (Int, Int)
  -> EchidnaTest
  -> m (Widget Name, Widget Name)
maxWidget _ test | null test.reproducer =
  pure (failureBadge, str "*no transactions made*")
maxWidget b test = do
  let vm = fromJust test.vm
  s <- seqWidget vm test.reproducer
  traces <- tracesWidget vm
  pure
    ( maximumBadge <+> str (" max value: " ++ show test.value)
    , shrinkWidget b test <=> titleWidget <=> s <=> str " " <=> traces
    )

shrinkWidget :: Maybe (Int, Int) -> EchidnaTest -> Widget Name
shrinkWidget b test =
  case b of
    Nothing -> emptyWidget
    Just (n,m) ->
      str "Current action: " <+>
      withAttr (attrName "working")
               (str ("shrinking " ++ progress n m ++ showWorker))
  where
  showWorker = maybe "" (\i -> " (worker " <> show i <> ")") test.workerId

seqWidget :: (MonadReader Env m, MonadIO m) => VM Concrete RealWorld -> [Tx] -> m (Widget Name)
seqWidget vm xs = do
  ppTxs <- mapM (ppTx vm $ length (nub $ (.src) <$> xs) /= 1) xs
  let ordinals = str . printf "%d. " <$> [1 :: Int ..]
  pure $
    foldl (<=>) emptyWidget $
      zipWith (<+>) ordinals (withAttr (attrName "tx") . strBreak <$> ppTxs)

failureBadge :: Widget Name
failureBadge = failure $ str "FAILED!"

maximumBadge :: Widget Name
maximumBadge = withAttr (attrName "maximum") $ str "OPTIMIZED!"

strBreak :: String -> Widget n
strBreak = strWrapWith $ defaultWrapSettings { breakLongWords = True }

txtBreak :: Text -> Widget n
txtBreak = txtWrapWith $ defaultWrapSettings { breakLongWords = True }
