{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
-- | Semantics of 'Command.Cmd' client commands that return server commands.
-- A couple of them do not take time, the rest does.
-- TODO: document
module Game.LambdaHack.Client.HumanGlobal
  ( moveLeader, exploreLeader, runLeader, waitHuman, pickupHuman, dropHuman
  , projectLeader, applyHuman, triggerDirHuman, triggerTileHuman
  , gameRestartHuman, gameExitHuman, gameSaveHuman, cfgDumpHuman
  ) where

import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.Function
import Data.List
import Data.Maybe
import qualified Data.Monoid as Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.Draw
import Game.LambdaHack.Client.HumanCmd (Trigger (..))
import Game.LambdaHack.Client.HumanLocal
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.RunAction
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.ServerCmd
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.TileKind as TileKind
import Game.LambdaHack.Utils.Assert

-- * Move

moveLeader :: MonadClientUI m => Vector -> m CmdSer
moveLeader dir = do
  leader <- getLeaderUI
  return $! MoveSer leader dir

-- * Explore

exploreLeader :: MonadClientUI m => Vector -> m CmdSer
exploreLeader dir = do
  leader <- getLeaderUI
  return $! ExploreSer leader dir

-- * Run

runLeader :: MonadClientUI m => Vector -> m CmdSer
runLeader dir = do
  leader <- getLeaderUI
  (dirR, distNew) <- runDir leader (dir, 0)
  modifyClient $ \cli -> cli {srunning = Just (dirR, distNew)}
  return $! RunSer leader dirR

-- * Wait

-- | Leader waits a turn (and blocks, etc.).
waitHuman :: MonadClientUI m => m CmdSer
waitHuman = do
  leader <- getLeaderUI
  return $ WaitSer leader

-- * Pickup

pickupHuman :: (MonadClientAbort m, MonadClientUI m) => m CmdSer
pickupHuman = do
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  lvl <- getsLevel (blid body) id
  -- Check if something is here to pick up. Items are never invisible.
  case EM.minViewWithKey $ lvl `atI` bpos body of
    Nothing -> abortWith "nothing here"
    Just ((iid, k), _) ->  do  -- pick up first item; TODO: let pl select item
      item <- getsState $ getItemBody iid
      let l = if jsymbol item == '$' then Just $ InvChar '$' else Nothing
      case assignLetter iid l body of
        Just l2 -> return $ PickupSer leader iid k l2
        Nothing -> abortWith "cannot carry any more"

-- * Drop

-- TODO: you can drop an item already on the floor, which works correctly,
-- but is weird and useless.
-- | Drop a single item.
dropHuman :: (MonadClientAbort m, MonadClientUI m) => m CmdSer
dropHuman = do
  -- TODO: allow dropping a given number of identical items.
  Kind.COps{coitem} <- getsState scops
  leader <- getLeaderUI
  bag <- getsState $ getActorBag leader
  inv <- getsState $ getActorInv leader
  ((iid, item), _k) <- getAnyItem leader "What to drop?" bag inv "in inventory"
  disco <- getsClient sdisco
  -- Do not advertise if an enemy drops an item. Probably junk.
  subject <- partAidLeader leader
  msgAdd $ makeSentence
    [ MU.SubjectVerbSg subject "drop"
    , partItemWs coitem disco 1 item ]
  return $ DropSer leader iid

allObjectsName :: Text
allObjectsName = "Objects"

-- | Let the human player choose any item from a list of items.
getAnyItem :: (MonadClientAbort m, MonadClientUI m)
           => ActorId
           -> Text     -- ^ prompt
           -> ItemBag  -- ^ all items in question
           -> ItemInv  -- ^ inventory characters
           -> Text     -- ^ how to refer to the collection of items
           -> m ((ItemId, Item), (Int, Container))
getAnyItem leader prompt = getItem leader prompt (const True) allObjectsName

data ItemDialogState = INone | ISuitable | IAll deriving Eq

-- | Let the human player choose a single, preferably suitable,
-- item from a list of items.
getItem :: (MonadClientAbort m, MonadClientUI m)
        => ActorId
        -> Text            -- ^ prompt message
        -> (Item -> Bool)  -- ^ which items to consider suitable
        -> Text            -- ^ how to describe suitable items
        -> ItemBag         -- ^ all items in question
        -> ItemInv         -- ^ inventory characters
        -> Text            -- ^ how to refer to the collection of items
        -> m ((ItemId, Item), (Int, Container))
getItem aid prompt p ptext bag inv isn = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  lvl <- getsLevel (blid b) id
  s <- getState
  body <- getsState $ getActorBody aid
  let checkItem (l, iid) =
        fmap (\k -> ((iid, getItemBody iid s), (k, l))) $ EM.lookup iid bag
      is0 = mapMaybe checkItem $ EM.assocs inv
      pos = bpos body
      tis = lvl `atI` pos
      floorFull = not $ EM.null tis
      (floorMsg, floorKey) | floorFull = (", -", [K.Char '-'])
                           | otherwise = ("", [])
      isp = filter (p . snd . fst) is0
      bestFull = not $ null isp
      (bestMsg, bestKey)
        | bestFull =
          let bestLetter = invChar $ maximum $ map (snd . snd) isp
          in (", RET(" <> T.singleton bestLetter <> ")", [K.Return])
        | otherwise = ("", [])
      keys ims =
        let mls = map (snd . snd) ims
            ks = bestKey ++ floorKey ++ [K.Char '?']
                 ++ map (K.Char . invChar) mls
        in zipWith K.KM (repeat K.NoModifier) ks
      choice ims =
        if null ims
        then "[?" <> floorMsg
        else let mls = map (snd . snd) ims
                 r = letterRange mls
             in "[" <> r <> ", ?" <> floorMsg <> bestMsg
      ask = do
        when (null is0 && EM.null tis) $
          abortWith "Not carrying anything."
        perform INone
      invP = EM.filter (\iid -> p (getItemBody iid s)) inv
      perform itemDialogState = do
        let (ims, invOver, msg) = case itemDialogState of
              INone     -> (isp, EM.empty, prompt)
              ISuitable -> (isp, invP, ptext <+> isn <> ".")
              IAll      -> (is0, inv, allObjectsName <+> isn <> ".")
        io <- itemOverlay bag invOver
        km@K.KM {..} <-
          displayChoiceUI (msg <+> choice ims) io (keys ims)
        assert (modifier == K.NoModifier) skip
        case key of
          K.Char '?' -> case itemDialogState of
            INone -> perform ISuitable
            ISuitable | ptext /= allObjectsName -> perform IAll
            _ -> perform INone
          K.Char '-' | floorFull ->
            -- TODO: let player select item
            return $ maximumBy (compare `on` fst . fst)
                   $ map (\(iid, k) ->
                           ((iid, getItemBody iid s),
                            (k, CFloor (blid b) pos)))
                   $ EM.assocs tis
          K.Char l | InvChar l `elem` map (snd . snd) ims ->
            case find ((InvChar l ==) . snd . snd) ims of
              Nothing -> assert `failure` (l,  ims)
              Just (iidItem, (k, l2)) ->
                return (iidItem, (k, CActor aid l2))
          K.Return | bestFull ->
            let (iidItem, (k, l2)) = maximumBy (compare `on` snd . snd) isp
            in return (iidItem, (k, CActor aid l2))
          _ -> assert `failure` "perform: unexpected key:" <+> K.showKM km
  ask

-- * Project

projectLeader :: (MonadClientAbort m, MonadClientUI m)
              => [Trigger] -> m CmdSer
projectLeader ts = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  let lid = blid b
  ms <- getsState $ actorNotProjList (isAtWar fact) lid
  lxsize <- getsLevel lid lxsize
  lysize <- getsLevel lid lysize
  if foesAdjacent lxsize lysize (bpos b) ms
    then abortWith "You can't aim in melee."
    else actorProjectGI leader ts

actorProjectGI :: (MonadClientAbort m, MonadClientUI m)
               => ActorId -> [Trigger] -> m CmdSer
actorProjectGI aid ts = do
  seps <- getsClient seps
  target <- targetToPos
  let (verb1, object1) = case ts of
        [] -> ("aim", "object")
        tr : _ -> (verb tr, object tr)
      triggerSyms = triggerSymbols ts
  case target of
    Just p -> do
      bag <- getsState $ getActorBag aid
      inv <- getsState $ getActorInv aid
      ((iid, _), (_, container)) <-
        getGroupItem aid bag inv object1 triggerSyms
          (makePhrase ["What to", verb1 MU.:> "?"]) "in inventory"
      stgtMode <- getsClient stgtMode
      case stgtMode of
        Just (TgtAuto _) -> endTargeting True
        _ -> return ()
      return $! ProjectSer aid p seps iid container
    Nothing -> assert `failure` (aid, "target unexpectedly invalid")

triggerSymbols :: [Trigger] -> [Char]
triggerSymbols [] = []
triggerSymbols (ApplyItem{..} : ts) = symbol : triggerSymbols ts
triggerSymbols (_ : ts) = triggerSymbols ts

-- * Apply

applyHuman :: (MonadClientAbort m, MonadClientUI m)
           => [Trigger] -> m CmdSer
applyHuman ts = do
  leader <- getLeaderUI
  bag <- getsState $ getActorBag leader
  inv <- getsState $ getActorInv leader
  let (verb1, object1) = case ts of
        [] -> ("activate", "object")
        tr : _ -> (verb tr, object tr)
      triggerSyms = triggerSymbols ts
  ((iid, _), (_, container)) <-
    getGroupItem leader bag inv object1 triggerSyms
                 (makePhrase ["What to", verb1 MU.:> "?"]) "in inventory"
  return $! ApplySer leader iid container

-- | Let a human player choose any item with a given group name.
-- Note that this does not guarantee the chosen item belongs to the group,
-- as the player can override the choice.
getGroupItem :: (MonadClientAbort m, MonadClientUI m)
             => ActorId
             -> ItemBag  -- ^ all objects in question
             -> ItemInv  -- ^ inventory characters
             -> MU.Part  -- ^ name of the group
             -> [Char]   -- ^ accepted item symbols
             -> Text     -- ^ prompt
             -> Text     -- ^ how to refer to the collection of objects
             -> m ((ItemId, Item), (Int, Container))
getGroupItem leader is inv object syms prompt packName = do
  let choice i = jsymbol i `elem` syms
      header = makePhrase [MU.Capitalize (MU.Ws object)]
  getItem leader prompt choice header is inv packName

-- * TriggerDir

-- | Ask for a direction and trigger a tile, if possible.
triggerDirHuman :: (MonadClientAbort m, MonadClientUI m)
                => [Trigger] -> m CmdSer
triggerDirHuman ts = do
  let verb1 = case ts of
        [] -> "trigger"
        tr : _ -> verb tr
      keys = zipWith K.KM (repeat K.NoModifier) K.dirAllMoveKey
      prompt = makePhrase ["What to", verb1 MU.:> "? [movement key"]
  e <- displayChoiceUI prompt [] keys
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  let dpos dir = bpos b `shift` dir
  lxsize <- getsLevel (blid b) lxsize
  K.handleDir lxsize e (bumpTile leader ts . dpos) (neverMind True)

-- | Player tries to trigger a tile using a feature.
-- To help the player, only visible features can be triggered.
bumpTile :: (MonadClientAbort m, MonadClientUI m)
         => ActorId -> [Trigger] -> Point -> m CmdSer
bumpTile leader ts dpos = do
  Kind.COps{cotile} <- getsState scops
  b <- getsState $ getActorBody leader
  lvl <- getsLevel (blid b) id
  let t = lvl `at` dpos
      triggerFeats = triggerFeatures ts
  -- A tile can be triggered even if an invisible monster occupies it.
  -- TODO: let the user choose whether to attack or activate.
  case filter (\feat -> Tile.hasFeature cotile feat t) triggerFeats of
    [] -> guessBump cotile triggerFeats t
    feat : _ -> do  -- trigger the first that matches
      verifyTrigger leader feat
      return $ TriggerSer leader dpos

triggerFeatures :: [Trigger] -> [F.Feature]
triggerFeatures [] = []
triggerFeatures (BumpFeature{..} : ts) = feature : triggerFeatures ts
triggerFeatures (_ : ts) = triggerFeatures ts

-- | Verify important feature triggers, such as fleeing the dungeon.
verifyTrigger :: (MonadClientAbort m, MonadClientUI m)
              => ActorId -> F.Feature -> m ()
verifyTrigger leader feat = case feat of
  F.Cause Effect.Quit -> do
    Kind.COps{coitem=Kind.Ops{oname, ouniqGroup}} <- getsState scops
    s <- getState
    b <- getsState $ getActorBody leader
    side <- getsClient sside
    spawning <- getsState $ flip isSpawningFaction side
    when spawning $ abortWith
      "This is the way out, but where would you go in this alien world?"
    go <- displayYesNo "This is the way out. Really leave now?"
    when (not go) $ abortWith "Game resumed."
    let (bag, total) = calculateTotal side (blid b) s
    if total == 0 then do
      -- The player can back off at each of these steps.
      go1 <- displayMore ColorBW
               "Afraid of the challenge? Leaving so soon and empty-handed?"
      when (not go1) $ abortWith "Brave soul!"
      go2 <- displayMore ColorBW
               "This time try to grab some loot before escape!"
      when (not go2) $ abortWith "Here's your chance!"
    else do
      let currencyName = MU.Text $ oname $ ouniqGroup "currency"
          winMsg = makeSentence
            [ "Congratulations, you won!"
            , "Here's your loot, worth"
            , MU.CarWs total currencyName ]
      io <- floorItemOverlay bag
      slides <- overlayToSlideshow winMsg io
      partingSlide <- promptToSlideshow "Can it be done better, though?"
      void $ getInitConfirms [] $ slides Monoid.<> partingSlide
  _ -> return ()

-- | Guess and report why the bump command failed.
guessBump :: MonadClientAbort m => Kind.Ops TileKind -> [F.Feature] -> Kind.Id TileKind -> m a
guessBump cotile (F.Openable : _) t | Tile.hasFeature cotile F.Closable t =
  abortWith "already open"
guessBump _ (F.Openable : _) _ =
  abortWith "not a door"
guessBump cotile (F.Closable : _) t | Tile.hasFeature cotile F.Openable t =
  abortWith "already closed"
guessBump _ (F.Closable : _) _ =
  abortWith "not a door"
guessBump cotile (F.Cause (Effect.Ascend _) : _) t
  | Tile.hasFeature cotile F.Descendable t =
    abortWith "the way goes down, not up"
guessBump _ (F.Cause (Effect.Ascend _) : _) _ =
  abortWith "no stairs up"
guessBump cotile (F.Cause (Effect.Descend _) : _) t
  | Tile.hasFeature cotile F.Ascendable t =
    abortWith "the way goes up, not down"
guessBump _ (F.Cause (Effect.Descend _) : _) _ =
  abortWith "no stairs down"
guessBump _ _ _ = neverMind True

-- * TriggerTile

-- | Leader tries to trigger the tile he's standing on.
triggerTileHuman :: (MonadClientAbort m, MonadClientUI m)
                 => [Trigger] -> m CmdSer
triggerTileHuman ts = do
  leader <- getLeaderUI
  ppos <- getsState (bpos . getActorBody leader)
  bumpTile leader ts ppos

-- * GameRestart; does not take time

gameRestartHuman :: (MonadClientAbort m, MonadClientUI m) => Text -> m CmdSer
gameRestartHuman t = do
  let msg = "You just requested a new" <+> t <+> "game."
  b1 <- displayMore ColorFull msg
  when (not b1) $ neverMind True
  b2 <- displayYesNo "Current progress will be lost! Really restart the game?"
  when (not b2) $ abortWith "Yea, would be a pity to leave them to die."
  msgAdd "Restarting the game now."
  leader <- getLeaderUI
  return $ GameRestartSer leader t

-- * GameExit; does not take time

gameExitHuman :: (MonadClientAbort m, MonadClientUI m) => m CmdSer
gameExitHuman = do
  b <- displayYesNo "Really save and exit?"
  if b then do
    slides <- scoreToSlideshow Camping
    partingSlide <- promptToSlideshow "See you soon, stronger and braver!"
    void $ getInitConfirms [] $ slides Monoid.<> partingSlide
    leader <- getLeaderUI
    return $ GameExitSer leader
  else abortWith "Save and exit canceled."

-- * GameSave; does not take time

gameSaveHuman :: MonadClientUI m => m CmdSer
gameSaveHuman = do
  leader <- getLeaderUI
  -- TODO: do not save to history:
  msgAdd "Game backup will be saved at the end of the turn."
  -- Let the server save, while the client continues taking commands.
  return $ GameSaveSer leader

-- * CfgDump; does not take time

cfgDumpHuman :: MonadClientUI m => m CmdSer
cfgDumpHuman = do
  leader <- getLeaderUI
  return $ CfgDumpSer leader
