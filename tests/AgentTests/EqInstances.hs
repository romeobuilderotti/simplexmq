{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module AgentTests.EqInstances where

import Data.Type.Equality
import Simplex.Messaging.Agent.Store

instance Eq SomeConn where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance Eq (Connection d)

deriving instance Eq (SConnType d)

deriving instance Eq (StoredRcvQueue q)

deriving instance Eq (StoredSndQueue q)

deriving instance Eq (DBQueueId q)

deriving instance Eq ClientNtfCreds
