{-# LANGUAGE DeriveFoldable      #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveTraversable   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeInType          #-}
{-# LANGUAGE TypeOperators       #-}

module Data.Vector.Sized where

import           Control.DeepSeq
import           Data.Finite
import           Data.Finite.Internal
import           Data.Kind
import           Data.Proxy
import           Data.Singletons
import           Data.Singletons.TypeLits
import           Data.Distributive
import           Data.Type.Combinator
import           GHC.Generics
import           GHC.TypeLits
import           GHC.TypeLits.Util
import           Prelude hiding           ((!!))
import           Text.Printf
import qualified Data.Vector              as V


type Vector n = VectorT n I

newtype VectorT :: Nat -> (Type -> Type) -> Type -> Type where
    UnsafeV :: { getV :: V.Vector (f a) }
            -> VectorT n f a

deriving instance                  Generic (VectorT n f a)
deriving instance Show (f a)    => Show (VectorT n f a)
deriving instance Functor f     => Functor (VectorT n f)
deriving instance Traversable f => Traversable (VectorT n f)
deriving instance Foldable f    => Foldable (VectorT n f)

instance (KnownNat n, Distributive f) => Distributive (VectorT n f) where
    distribute xs = generate $ \i -> distribute $ fmap (! i) xs
    {-# INLINE distribute #-}

instance NFData (f a) => NFData (VectorT n f a)

instance (KnownNat n, Applicative f) => Applicative (VectorT n f) where
    pure x = UnsafeV $ V.replicate n (pure x)
      where
        n = fromIntegral $ natVal (Proxy @n)
    {-# INLINE pure #-}
    UnsafeV fs <*> UnsafeV xs = UnsafeV (V.zipWith (<*>) fs xs)
    {-# INLINE (<*>) #-}

mkVectorT
    :: forall n f a. KnownNat n
    => V.Vector (f a)
    -> Maybe (VectorT n f a)
mkVectorT v | V.length v == n = Just (UnsafeV v)
            | otherwise       = Nothing
  where
    n = fromIntegral $ natVal (Proxy @n)
{-# INLINE mkVectorT #-}

mkVector
    :: forall n a. KnownNat n
    => V.Vector a
    -> Maybe (Vector n a)
mkVector = mkVectorT . fmap I
{-# INLINE mkVector #-}

mkVectorT'
    :: forall n f a. KnownNat n
    => V.Vector (f a)
    -> VectorT n f a
mkVectorT' v | V.length v == n = UnsafeV v
             | otherwise       = error
                               $ printf "mkVectorT: Mismatched vector length. %d, expected %d" (V.length v) n
  where
    n = fromIntegral $ natVal (Proxy @n)
{-# INLINE mkVectorT' #-}

mkVector'
    :: forall n a. KnownNat n
    => V.Vector a
    -> Vector n a
mkVector' = mkVectorT' . fmap I
{-# INLINE mkVector' #-}

generate
    :: forall n f a. KnownNat n
    => (Finite n -> f a)
    -> VectorT n f a
generate f = UnsafeV $ V.generate n (f . Finite . fromIntegral)
  where
    n = fromIntegral $ natVal (Proxy @n)
{-# INLINE generate #-}

generateA
    :: forall n f a g. (KnownNat n, Applicative g)
    => (Finite n -> g (f a))
    -> g (VectorT n f a)
generateA f = UnsafeV <$> sequenceA (V.generate n (f . Finite . fromIntegral))
  where
    n = fromIntegral $ natVal (Proxy @n)
{-# INLINE generateA #-}

replicate
    :: KnownNat n
    => f a
    -> VectorT n f a
replicate x = generate (\_ -> x)
{-# INLINE replicate #-}

(!) :: VectorT n f a
    -> Finite n
    -> f a
UnsafeV v ! i = v `V.unsafeIndex` fromIntegral (getFinite i)
{-# INLINE (!) #-}

(!!)
    :: Vector n a
    -> Finite n
    -> a
v !! i = getI $ v ! i
{-# INLINE (!!) #-}

withVectorT
    :: forall f a r. ()
    => V.Vector (f a)
    -> (forall n. KnownNat n => VectorT n f a -> r)
    -> r
withVectorT v f =
    withSomeSing n $ \(SNat :: Sing (n :: Nat)) ->
      f (UnsafeV v :: VectorT n f a)
  where
    n :: Integer
    n = fromIntegral (V.length v)
{-# INLINE withVectorT #-}

withVector
    :: forall a r. ()
    => V.Vector a
    -> (forall n. KnownNat n => Vector n a -> r)
    -> r
withVector v f = withVectorT (I <$> v) f
{-# INLINE withVector #-}

liftVec
    :: (Applicative f, Traversable g)
    => (g a -> b)
    -> g (f a)
    -> f b
liftVec f xs = f <$> sequenceA xs
{-# INLINE liftVec #-}

vecFunc
    :: KnownNat n
    => (a -> Vector n b)
    -> Vector n (a -> b)
vecFunc f = generate (\i -> I $ (!! i) . f)
{-# INLINE vecFunc #-}

vap :: (f a -> g b -> h c)
    -> VectorT n f a
    -> VectorT n g b
    -> VectorT n h c
vap f (UnsafeV xs) (UnsafeV ys) = UnsafeV (V.zipWith f xs ys)
{-# INLINE vap #-}

vmap
    :: (f a -> g b)
    -> VectorT n f a
    -> VectorT n g b
vmap f (UnsafeV xs) = UnsafeV (f <$> xs)
{-# INLINE vmap #-}

data Uncons :: Nat -> (Type -> Type) -> Type -> Type where
    VNil  :: Uncons 0 f a
    VCons :: KnownNat n => !(f a) -> !(VectorT n f a) -> Uncons (n + 1) f a

uncons
    :: forall n f a. KnownNat n
    => VectorT n f a
    -> Uncons n f a
uncons (UnsafeV v) = case inductive (Proxy @n) of
    NatZ   -> VNil
    NatS _ -> VCons (V.unsafeHead v) (UnsafeV (V.unsafeTail v))
{-# INLINE uncons #-}

fromUncons
    :: Uncons n f a
    -> VectorT n f a
fromUncons = \case
    VNil                 -> UnsafeV V.empty
    VCons x (UnsafeV xs) -> UnsafeV (V.cons x xs)
{-# INLINE fromUncons #-}

cons
    :: f a
    -> VectorT n f a
    -> VectorT (n + 1) f a
x `cons` UnsafeV xs = UnsafeV (x `V.cons` xs)
{-# INLINE cons #-}

empty :: VectorT 0 f a
empty = UnsafeV (V.empty)
{-# INLINE empty #-}

head
    :: VectorT (m + 1) f a
    -> f a
head (UnsafeV v) = V.unsafeHead v
{-# INLINE head #-}

tail
    :: VectorT (m + 1) f a
    -> VectorT m f a
tail (UnsafeV v) = UnsafeV (V.unsafeTail v)
{-# INLINE tail #-}

itraverse
    :: Applicative h
    => (Finite n -> f a -> h (g b))
    -> VectorT n f a
    -> h (VectorT n g b)
itraverse f (UnsafeV v) = UnsafeV
    <$> sequenceA (V.imap (\i x -> f (Finite (fromIntegral i)) x) v)
{-# INLINE itraverse #-}
