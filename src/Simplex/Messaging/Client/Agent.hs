{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Client.Agent where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Control.Monad.Trans.Reader
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (bimap, first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import Data.List (partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Text.Encoding
import Data.Tuple (swap)
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BrokerMsg, NotifierId, NtfPrivateAuthKey, ProtocolServer (..), QueueId, RcvPrivateAuthKey, RecipientId, SMPServer)
import Simplex.Messaging.Session
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (catchAll_, toChunks, ($>>=))
import System.Timeout (timeout)
import UnliftIO (async)
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type SMPClientVar = SessionVar (Either SMPClientError SMPClient)

data SMPClientAgentEvent
  = CAConnected SMPServer
  | CADisconnected SMPServer (Set SMPSub)
  | CAReconnected SMPServer
  | CAResubscribed SMPServer (NonEmpty SMPSub)
  | CASubError SMPServer (NonEmpty (SMPSub, SMPClientError))

data SMPSubParty = SPRecipient | SPNotifier
  deriving (Eq, Ord, Show)

type SMPSub = (SMPSubParty, QueueId)

-- type SMPServerSub = (SMPServer, SMPSub)

data SMPClientAgentConfig = SMPClientAgentConfig
  { smpCfg :: ProtocolClientConfig SMPVersion,
    reconnectInterval :: RetryInterval,
    msgQSize :: Natural,
    agentQSize :: Natural,
    agentSubsBatchSize :: Int
  }

defaultSMPClientAgentConfig :: SMPClientAgentConfig
defaultSMPClientAgentConfig =
  SMPClientAgentConfig
    { smpCfg = defaultSMPClientConfig {defaultTransport = ("5223", transport @TLS)},
      reconnectInterval =
        RetryInterval
          { initialInterval = second,
            increaseAfter = 10 * second,
            maxInterval = 10 * second
          },
      msgQSize = 256,
      agentQSize = 256,
      agentSubsBatchSize = 900
    }
  where
    second = 1000000

data SMPClientAgent = SMPClientAgent
  { agentCfg :: SMPClientAgentConfig,
    msgQ :: TBQueue (ServerTransmission SMPVersion BrokerMsg),
    agentQ :: TBQueue SMPClientAgentEvent,
    randomDrg :: TVar ChaChaDRG,
    smpClients :: TMap SMPServer SMPClientVar,
    srvSubs :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey),
    pendingSrvSubs :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey),
    reconnections :: TVar [Async ()],
    asyncClients :: TVar [Async ()],
    workerSeq :: TVar Int
  }

newtype InternalException e = InternalException {unInternalException :: e}
  deriving (Eq, Show)

instance Exception e => Exception (InternalException e)

instance Exception e => MonadUnliftIO (ExceptT e IO) where
  {-# INLINE withRunInIO #-}
  withRunInIO :: ((forall a. ExceptT e IO a -> IO a) -> IO b) -> ExceptT e IO b
  withRunInIO inner =
    ExceptT . fmap (first unInternalException) . E.try $
      withRunInIO $ \run ->
        inner $ run . (either (E.throwIO . InternalException) pure <=< runExceptT)

-- as MonadUnliftIO instance for IO is `withRunInIO inner = inner id`,
-- the last two lines could be replaced with:
-- inner $ either (E.throwIO . InternalException) pure <=< runExceptT

instance Exception e => MonadUnliftIO (ExceptT e (ReaderT r IO)) where
  {-# INLINE withRunInIO #-}
  withRunInIO :: ((forall a. ExceptT e (ReaderT r IO) a -> IO a) -> IO b) -> ExceptT e (ReaderT r IO) b
  withRunInIO inner =
    withExceptT unInternalException . ExceptT . E.try $
      withRunInIO $ \run ->
        inner $ run . (either (E.throwIO . InternalException) pure <=< runExceptT)

newSMPClientAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> STM SMPClientAgent
newSMPClientAgent agentCfg@SMPClientAgentConfig {msgQSize, agentQSize} randomDrg = do
  msgQ <- newTBQueue msgQSize
  agentQ <- newTBQueue agentQSize
  smpClients <- TM.empty
  srvSubs <- TM.empty
  pendingSrvSubs <- TM.empty
  reconnections <- newTVar []
  asyncClients <- newTVar []
  workerSeq <- newTVar 0
  pure
    SMPClientAgent
      { agentCfg,
        msgQ,
        agentQ,
        randomDrg,
        smpClients,
        srvSubs,
        pendingSrvSubs,
        reconnections,
        asyncClients,
        workerSeq
      }

getSMPServerClient' :: SMPClientAgent -> SMPServer -> ExceptT SMPClientError IO SMPClient
getSMPServerClient' ca@SMPClientAgent {agentCfg, smpClients, msgQ, randomDrg, workerSeq} srv =
  atomically getClientVar >>= either newSMPClient waitForSMPClient
  where
    getClientVar :: STM (Either SMPClientVar SMPClientVar)
    getClientVar = getSessVar workerSeq srv smpClients

    waitForSMPClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    waitForSMPClient v = do
      let ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
      smpClient_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar $ sessionVar v)
      liftEither $ case smpClient_ of
        Just (Right smpClient) -> Right smpClient
        Just (Left e) -> Left e
        Nothing -> Left PCEResponseTimeout

    newSMPClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    newSMPClient v = tryConnectClient pure (liftIO tryConnectAsync)
      where
        tryConnectClient :: (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO () -> ExceptT SMPClientError IO a
        tryConnectClient successAction retryAction =
          tryE (connectClient v) >>= \r -> case r of
            Right smp -> do
              logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
              atomically $ putTMVar (sessionVar v) r
              successAction smp
            Left e -> do
              if e == PCENetworkError || e == PCEResponseTimeout
                then retryAction
                else atomically $ do
                  putTMVar (sessionVar v) (Left e)
                  removeSessVar v srv smpClients
              throwE e
        tryConnectAsync :: IO ()
        tryConnectAsync = do
          a <- async $ void $ runExceptT connectAsync
          atomically $ modifyTVar' (asyncClients ca) (a :)
        connectAsync :: ExceptT SMPClientError IO ()
        connectAsync =
          withRetryInterval (reconnectInterval agentCfg) $ \_ loop ->
            void $ tryConnectClient (const reconnectClient) loop

    connectClient :: SMPClientVar -> ExceptT SMPClientError IO SMPClient
    connectClient v = ExceptT $ getProtocolClient randomDrg (1, srv, Nothing) (smpCfg agentCfg) (Just msgQ) (clientDisconnected v)

    clientDisconnected :: SMPClientVar -> SMPClient -> IO ()
    clientDisconnected v _ = do
      removeClientAndSubs v >>= (`forM_` serverDown)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: SMPClientVar -> IO (Maybe (Map SMPSub C.APrivateAuthKey))
    removeClientAndSubs v = atomically $ do
      removeSessVar v srv smpClients
      TM.lookupDelete srv (srvSubs ca) >>= mapM updateSubs
      where
        updateSubs sVar = do
          ss <- readTVar sVar
          addPendingSubs sVar ss
          pure ss

        addPendingSubs sVar ss = do
          let ps = pendingSrvSubs ca
          TM.lookup srv ps >>= \case
            Just ss' -> TM.union ss ss'
            _ -> TM.insert srv sVar ps

    serverDown :: Map SMPSub C.APrivateAuthKey -> IO ()
    serverDown ss = unless (M.null ss) $ do
      notify . CADisconnected srv $ M.keysSet ss
      reconnectServer

    reconnectServer :: IO ()
    reconnectServer = do
      a <- async $ void $ runExceptT tryReconnectClient
      atomically $ modifyTVar' (reconnections ca) (a :)

    tryReconnectClient :: ExceptT SMPClientError IO ()
    tryReconnectClient = do
      withRetryInterval (reconnectInterval agentCfg) $ \_ loop ->
        reconnectClient `catchE` const loop

    reconnectClient :: ExceptT SMPClientError IO ()
    reconnectClient = do
      withSMP ca srv $ \smp -> do
        liftIO $ notify $ CAReconnected srv
        cs_ <- atomically $ mapM readTVar =<< TM.lookup srv (pendingSrvSubs ca)
        forM_ cs_ $ \cs -> do
          subs' <- filterM (fmap not . atomically . hasSub (srvSubs ca) srv . fst) $ M.assocs cs
          let (nSubs, rSubs) = partition (isNotifier . fst . fst) subs'
          subscribe_ smp SPNotifier nSubs
          subscribe_ smp SPRecipient rSubs
      where
        isNotifier = \case
          SPNotifier -> True
          SPRecipient -> False

        subscribe_ :: SMPClient -> SMPSubParty -> [(SMPSub, C.APrivateAuthKey)] -> ExceptT SMPClientError IO ()
        subscribe_ smp party = mapM_ subscribeBatch . toChunks (agentSubsBatchSize agentCfg)
          where
            subscribeBatch subs' = do
              let subs'' :: (NonEmpty (QueueId, C.APrivateAuthKey)) = L.map (first snd) subs'
              rs <- liftIO $ smpSubscribeQueues party ca smp srv subs''
              let rs' :: (NonEmpty ((SMPSub, C.APrivateAuthKey), Either SMPClientError ())) =
                    L.zipWith (first . const) subs' rs
                  rs'' :: [Either (SMPSub, SMPClientError) (SMPSub, C.APrivateAuthKey)] =
                    map (\(sub, r) -> bimap (fst sub,) (const sub) r) $ L.toList rs'
                  (errs, oks) = partitionEithers rs''
                  (tempErrs, finalErrs) = partition (temporaryClientError . snd) errs
              mapM_ (atomically . addSubscription ca srv) oks
              mapM_ (liftIO . notify . CAResubscribed srv) $ L.nonEmpty $ map fst oks
              mapM_ (atomically . removePendingSubscription ca srv . fst) finalErrs
              mapM_ (liftIO . notify . CASubError srv) $ L.nonEmpty finalErrs
              mapM_ (throwE . snd) $ listToMaybe tempErrs

    notify :: SMPClientAgentEvent -> IO ()
    notify evt = atomically $ writeTBQueue (agentQ ca) evt

closeSMPClientAgent :: SMPClientAgent -> IO ()
closeSMPClientAgent c = do
  closeSMPServerClients c
  cancelActions $ reconnections c
  cancelActions $ asyncClients c

closeSMPServerClients :: SMPClientAgent -> IO ()
closeSMPServerClients c = atomically (smpClients c `swapTVar` M.empty) >>= mapM_ (forkIO . closeClient)
  where
    closeClient v =
      atomically (readTMVar $ sessionVar v) >>= \case
        Right smp -> closeProtocolClient smp `catchAll_` pure ()
        _ -> pure ()

cancelActions :: Foldable f => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel

withSMP :: SMPClientAgent -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO a
withSMP ca srv action = (getSMPServerClient' ca srv >>= action) `catchE` logSMPError
  where
    logSMPError :: SMPClientError -> ExceptT SMPClientError IO a
    logSMPError e = do
      liftIO $ putStrLn $ "SMP error (" <> show srv <> "): " <> show e
      throwE e

subscribeQueue :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> ExceptT SMPClientError IO ()
subscribeQueue ca srv sub = do
  atomically $ addPendingSubscription ca srv sub
  withSMP ca srv $ \smp -> subscribe_ smp `catchE` handleErr
  where
    subscribe_ smp = do
      smpSubscribe smp sub
      atomically $ addSubscription ca srv sub

    handleErr e = do
      atomically . when (e /= PCENetworkError && e /= PCEResponseTimeout) $
        removePendingSubscription ca srv (fst sub)
      throwE e

subscribeQueuesSMP :: SMPClientAgent -> SMPServer -> NonEmpty (RecipientId, RcvPrivateAuthKey) -> IO (NonEmpty (RecipientId, Either SMPClientError ()))
subscribeQueuesSMP = subscribeQueues_ SPRecipient

subscribeQueuesNtfs :: SMPClientAgent -> SMPServer -> NonEmpty (NotifierId, NtfPrivateAuthKey) -> IO (NonEmpty (NotifierId, Either SMPClientError ()))
subscribeQueuesNtfs = subscribeQueues_ SPNotifier

subscribeQueues_ :: SMPSubParty -> SMPClientAgent -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO (NonEmpty (QueueId, Either SMPClientError ()))
subscribeQueues_ party ca srv subs = do
  atomically $ forM_ subs $ addPendingSubscription ca srv . first (party,)
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Left e -> pure $ L.map ((,Left e) . fst) subs
    Right smp -> smpSubscribeQueues party ca smp srv subs

smpSubscribeQueues :: SMPSubParty -> SMPClientAgent -> SMPClient -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO (NonEmpty (QueueId, Either SMPClientError ()))
smpSubscribeQueues party ca smp srv subs = do
  rs <- L.zip subs <$> subscribe smp (L.map swap subs)
  atomically $ forM rs $ \(sub, r) ->
    (fst sub,) <$> case r of
      Right () -> do
        addSubscription ca srv $ first (party,) sub
        pure $ Right ()
      Left e -> do
        when (e /= PCENetworkError && e /= PCEResponseTimeout) $
          removePendingSubscription ca srv (party, fst sub)
        pure $ Left e
  where
    subscribe = case party of
      SPRecipient -> subscribeSMPQueues
      SPNotifier -> subscribeSMPQueuesNtfs

showServer :: SMPServer -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)

smpSubscribe :: SMPClient -> (SMPSub, C.APrivateAuthKey) -> ExceptT SMPClientError IO ()
smpSubscribe smp ((party, queueId), privKey) = subscribe_ smp privKey queueId
  where
    subscribe_ = case party of
      SPRecipient -> subscribeSMPQueue
      SPNotifier -> subscribeSMPQueueNotifications

addSubscription :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> STM ()
addSubscription ca srv sub = do
  addSub_ (srvSubs ca) srv sub
  removePendingSubscription ca srv $ fst sub

addPendingSubscription :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> STM ()
addPendingSubscription = addSub_ . pendingSrvSubs

addSub_ :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> STM ()
addSub_ subs srv (s, key) =
  TM.lookup srv subs >>= \case
    Just m -> TM.insert s key m
    _ -> TM.singleton s key >>= \v -> TM.insert srv v subs

removeSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removeSubscription = removeSub_ . srvSubs

removePendingSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removePendingSubscription = removeSub_ . pendingSrvSubs

removeSub_ :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> SMPSub -> STM ()
removeSub_ subs srv s = TM.lookup srv subs >>= mapM_ (TM.delete s)

getSubKey :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> SMPSub -> STM (Maybe C.APrivateAuthKey)
getSubKey subs srv s = TM.lookup srv subs $>>= TM.lookup s

hasSub :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> SMPSub -> STM Bool
hasSub subs srv s = maybe (pure False) (TM.member s) =<< TM.lookup srv subs
