{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Ondim.MultiWalk.Basic where

import Control.Monad.Except (MonadError (..))
import Control.MultiWalk.HasSub qualified as HS
import Data.HashMap.Strict qualified as Map
import Data.Text qualified as T
import GHC.Exception (SrcLoc)
import GHC.Exts qualified as GHC
import {-# SOURCE #-} Ondim.MultiWalk.Class
import {-# SOURCE #-} Ondim.MultiWalk.Combinators (Carrier)
import System.FilePath (takeExtensions)
import Type.Reflection (SomeTypeRep, TypeRep, someTypeRep)

-- * Monad

newtype Ondim m a = Ondim
  { unOndimT :: ReaderT TraceData (StateT (OndimState m) (ExceptT OndimException m)) a
  }
  deriving newtype (Functor, Applicative, Monad, MonadIO)

instance MonadTrans Ondim where
  lift = Ondim . lift . lift . lift

instance MonadState s m => MonadState s (Ondim m) where
  get = lift get
  put x = lift (put x)

instance MonadReader s m => MonadReader s (Ondim m) where
  ask = lift ask
  local f (Ondim (ReaderT g)) = Ondim $ ReaderT $ local f . g

instance MonadError e m => MonadError e (Ondim m) where
  throwError = lift . throwError
  catchError (x :: Ondim m a) c =
    let f :: TraceData -> OndimState m -> m (Either OndimException (a, OndimState m))
        f r s =
          let c' e = coerce (c e) r s
           in coerce x r s `catchError` c'
     in coerce f

-- * Filters and Expansions

data DefinitionSite
  = CodeDefinition SrcLoc
  | FileDefinition {definitionPath :: FilePath, definitionExt :: Text}
  | NoDefinition
  deriving (Eq, Show)

fileSite :: FilePath -> DefinitionSite
fileSite fp = FileDefinition fp exts
  where
    exts = T.drop 1 $ toText $ takeExtensions fp

callStackSite :: DefinitionSite
callStackSite = case GHC.toList callStack of
  x : _ -> CodeDefinition (snd x)
  [] -> NoDefinition

-- Expansions

type Expansion m t = t -> Ondim m [t]
newtype Namespace m = Namespace {getExpansions :: HashMap Text (SomeExpansion m)}
type GlobalExpansion m = forall a. (OndimNode a, Monad m) => Expansion m a

data SomeExpansion m where
  SomeExpansion :: TypeRep a -> DefinitionSite -> Expansion m a -> SomeExpansion m
  GlobalExpansion :: DefinitionSite -> GlobalExpansion m -> SomeExpansion m
  Template :: (OndimNode a) => TypeRep a -> DefinitionSite -> a -> SomeExpansion m
  NamespaceData :: Namespace m -> SomeExpansion m

instance Semigroup (Namespace m) where
  (Namespace x) <> (Namespace y) = Namespace $ Map.unionWith f x y
    where
      f (NamespaceData n) (NamespaceData m) = NamespaceData $ n <> m
      f z _ = z

instance Monoid (Namespace m) where
  mempty = Namespace mempty

-- Conversions

type Conversions = forall a b. TypeRep a -> TypeRep b -> a -> b

-- * State data

-- | Ondim's expansion state
newtype OndimState (m :: Type -> Type) = OndimState
  { -- | Named expansions
    expansions :: Namespace m
  }
  deriving (Generic)
  deriving newtype (Semigroup, Monoid)

-- * Exceptions

-- | Data used for debugging purposes
data TraceData = TraceData
  { depth :: Int,
    expansionTrace :: [(Text, DefinitionSite)],
    currentSite :: DefinitionSite,
    inhibitErrors :: Bool
  }
  deriving (Eq, Show)

initialTraceData :: TraceData
initialTraceData = TraceData 0 [] NoDefinition False

getCurrentSite :: Monad m => Ondim m DefinitionSite
getCurrentSite = Ondim $ asks currentSite

withSite :: Monad m => DefinitionSite -> Ondim m a -> Ondim m a
withSite site = Ondim . local (\s -> s {currentSite = site}) . unOndimT

data ExceptionType
  = MaxExpansionDepthExceeded
  | -- | Template errors are not meant to be catched from within the templates.
    -- Instead, they point at user errors that are supposed to be fixed.
    TemplateError
      CallStack
      -- ^ Call stack
      Text
      -- ^ Custom error message.
  | -- | Failures are expected in some sense.
    Failure
      SomeTypeRep
      -- ^ Type representation of the node which triggered the failure.
      Text
      -- ^ Identifier of the node which triggered the failure.
      OndimFailure
  deriving (Show, Exception)

-- | Failures related to the expansions.
data OndimFailure
  = -- | Identifier is not a bound expansion.
    NotBound
  | -- | Expansion bound under identifier has mismatched type.
    ExpansionWrongType
      SomeTypeRep
      -- ^ Type representation of the expansion that is bound under the identifier.
  | -- | Expansion bound under identifier has mismatched type.
    TemplateWrongType
      SomeTypeRep
      -- ^ Type representation of the expansion that is bound under the identifier.
  | -- | Custom failure.
    FailureOther Text
  deriving (Show, Exception)

data OndimException = OndimException ExceptionType TraceData
  deriving (Show, Exception)

-- | Run subcomputation without (most) "not bound" errors.
withoutNBErrors :: Monad m => Ondim m a -> Ondim m a
withoutNBErrors = Ondim . local f . unOndimT
  where
    f r = r {inhibitErrors = True}

-- | Run subcomputation with "not bound" errors.
withNBErrors :: Monad m => Ondim m a -> Ondim m a
withNBErrors = Ondim . local f . unOndimT
  where
    f r = r {inhibitErrors = False}

catchException ::
  Monad m =>
  Ondim m a ->
  (OndimException -> Ondim m a) ->
  Ondim m a
catchException (Ondim m) f = Ondim $ catchError m (unOndimT . f)

throwException :: Monad m => ExceptionType -> Ondim m a
throwException e = do
  td <- Ondim ask
  Ondim $ throwError (OndimException e td)

throwTemplateError :: (HasCallStack, Monad m) => Text -> Ondim m a
throwTemplateError t = throwException (TemplateError callStack t)

catchFailure ::
  Monad m =>
  Ondim m a ->
  (OndimFailure -> Text -> SomeTypeRep -> TraceData -> Ondim m a) ->
  Ondim m a
catchFailure (Ondim m) f = Ondim $ catchError m \(OndimException exc tdata) ->
  case exc of
    Failure trep name e -> unOndimT $ f e name trep tdata
    _other -> m

throwExpFailure ::
  forall t m a.
  (Monad m, Typeable t) =>
  Text ->
  OndimFailure ->
  Ondim m a
throwExpFailure t f =
  throwException $ Failure (someTypeRep (Proxy @t)) t f

-- * Combinators

data OCTag

type HasSub tag ls t = HS.HasSub OCTag tag ls t
type ToSpec a = HS.ToSpec OCTag a
type ToSpecSel s a = HS.ToSpecSel OCTag s a
type instance HS.Carrier OCTag a = Carrier a

-- * Attributes

-- | Alias for attributes
type Attribute = (Text, Text)
