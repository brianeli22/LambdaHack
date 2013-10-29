{-# LANGUAGE FlexibleContexts #-}
-- | Semantics of client commands.
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Client
  ( cmdClientAISem, cmdClientUISem
  , loopAI, loopUI, exeFrontend
  , MonadClient, MonadClientUI, MonadClientReadServer, MonadClientWriteServer
  ) where

import Data.Maybe

import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.AtomicSemCli
import Game.LambdaHack.Client.Binding
import Game.LambdaHack.Client.ClientSem
import Game.LambdaHack.Client.Config
import Game.LambdaHack.Client.LoopAction
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Animation (FSConfig (..))
import Game.LambdaHack.Common.AtomicCmd
import Game.LambdaHack.Common.ClientCmd
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.ServerCmd
import Game.LambdaHack.Common.State
import Game.LambdaHack.Frontend
import Game.LambdaHack.Utils.Assert

storeUndo :: MonadClient m => Atomic -> m ()
storeUndo _atomic =
  maybe skip (\a -> modifyClient $ \cli -> cli {sundo = a : sundo cli})
    $ Nothing   -- TODO: undoAtomic atomic

cmdClientAISem :: (MonadAtomic m, MonadClientWriteServer CmdSerTakeTime m)
               => CmdClientAI -> m ()
cmdClientAISem cmd = case cmd of
  CmdAtomicAI cmdA -> do
    cmds <- cmdAtomicFilterCli cmdA
    mapM_ cmdAtomicSemCli cmds
    mapM_ execCmdAtomic cmds
    mapM_ (storeUndo . CmdAtomic) cmds
  CmdQueryAI aid -> do
    cmdC <- queryAI aid
    writeServer cmdC

cmdClientUISem :: ( MonadAtomic m, MonadClientAbort m
                  , MonadClientUI m, MonadClientWriteServer CmdSer m )
               => CmdClientUI -> m ()
cmdClientUISem cmd =
  case cmd of
    CmdAtomicUI cmdA -> do
      cmds <- cmdAtomicFilterCli cmdA
      mapM_ cmdAtomicSemCli cmds
      mapM_ execCmdAtomic cmds
      mapM_ (drawCmdAtomicUI False) cmds
      mapM_ (storeUndo . CmdAtomic) cmds  -- TODO: only store cmdA?
    SfxAtomicUI sfx -> do
      drawSfxAtomicUI False sfx
      storeUndo $ SfxAtomic sfx
    CmdQueryUI aid -> do
      mleader <- getsClient _sleader
      assert (isJust mleader `blame` cmd) skip
      cmdH <- queryUI aid
      writeServer cmdH

wireSession :: (SessionUI -> State -> StateClient
                -> ChanServer CmdClientUI CmdSer -> IO ())
            -> (SessionUI -> State -> StateClient
                -> ChanServer CmdClientAI CmdSerTakeTime -> IO ())
            -> Kind.COps
            -> ((FactionId -> ChanFrontend -> ChanServer CmdClientUI CmdSer
                 -> IO ())
                -> (FactionId -> ChanServer CmdClientAI CmdSerTakeTime
                    -> IO ())
                -> IO ())
            -> IO ()
wireSession exeClientUI exeClientAI cops@Kind.COps{corule} exeServer = do
  -- UI config reloaded at each client start.
  sconfigUI <- mkConfigUI corule
  let !sbinding = stdBinding sconfigUI  -- evaluate to check for errors
      fsfont = configFont sconfigUI
      fsmaxFps = configMaxFps sconfigUI
  defHist <- defHistory
  let cli = defStateClient defHist sconfigUI
      s = updateCOps (const cops) emptyState
      executorAI fid =
        let noSession = assert `failure` fid
        in exeClientAI noSession s (cli fid True)
      executorUI fid fromF =
        let sfconn = connFrontend fid fromF
        in exeClientUI SessionUI{..} s (cli fid False)
  startupF FSConfig{..} $ exeServer executorUI executorAI

-- | Wire together game content, the main loop of game clients,
-- the main game loop assigned to this frontend (possibly containing
-- the server loop, if the whole game runs in one process),
-- UI config and the definitions of game commands.
exeFrontend :: ( MonadAtomic m, MonadClientAbort m, MonadClientUI m
               , MonadClientReadServer CmdClientUI m
               , MonadClientWriteServer CmdSer m
               , MonadAtomic n
               , MonadClientReadServer CmdClientAI n
               , MonadClientWriteServer CmdSerTakeTime n )
            => (m () -> SessionUI -> State -> StateClient
                -> ChanServer CmdClientUI CmdSer
                -> IO ())
            -> (n () -> SessionUI -> State -> StateClient
                -> ChanServer CmdClientAI CmdSerTakeTime
                -> IO ())
            -> Kind.COps
            -> ((FactionId -> ChanFrontend -> ChanServer CmdClientUI CmdSer
                 -> IO ())
               -> (FactionId -> ChanServer CmdClientAI CmdSerTakeTime
                   -> IO ())
               -> IO ())
            -> IO ()
exeFrontend executorUI executorAI cops exeServer = do
  let exeClientUI = executorUI $ loopUI cmdClientUISem
      exeClientAI = executorAI $ loopAI cmdClientAISem
  wireSession exeClientUI exeClientAI cops exeServer
