{-# LANGUAGE EmptyCase            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE InstanceSigs         #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeInType           #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

module TensorOps.Backend.BTensor
  ( BTensor
  ) where

import           Control.Applicative
import           Data.Distributive
import           Data.Kind
import           Data.Monoid
import           Data.Nested hiding             (unScalar, unVector)
import           Data.Singletons
import           Data.Singletons.Prelude hiding (Reverse, Head, sReverse, (:-))
import           Data.Type.Combinator
import           Data.Type.Length               as TCL
import           Data.Type.Length.Util          as TCL
import           Data.Type.Nat
import           Data.Type.Product              as TCP
import           Data.Type.Product.Util         as TCP
import           Data.Type.Sing
import           Data.Type.Uniform
import           Statistics.Distribution
import           TensorOps.BLAS
import           TensorOps.NatKind
import           TensorOps.Types
import           Type.Class.Higher
import           Type.Class.Higher.Util
import           Type.Class.Witness
import           Type.Family.List
import           Type.Family.List.Util
import           Type.Family.Nat
import qualified Data.Type.Vector               as TCV
import qualified Data.Type.Vector.Util          as TCV


data BTensor :: (k -> Type -> Type) -> (BShape k -> Type) -> [k] -> Type where
    BTS :: { unScalar :: !(ElemB b)     } -> BTensor v b '[]
    BTV :: { unVector :: !(b ('BV n))   } -> BTensor v b '[n]
    BTM :: { unMatrix :: !(b ('BM n m)) } -> BTensor v b '[n,m]
    BTN :: { unNested :: !(v n (BTensor v b (o ': m ': ns))) }
        -> BTensor v b (n ': o ': m ': ns)

instance ( BLAS b
         , Vec v
         , Nesting1 Proxy Functor v
         , Nesting1 Sing Applicative v
         , SingI ns
         , Num (ElemB b)
         )
        => Num (BTensor v b ns) where
    (+) = zipBase sing
                  (+)
                  (\_          xs ys -> axpy 1 xs (Just ys))
                  (\(SBM _ sM) xs ys -> gemm 1 xs (eye sM) (Just (1, ys)))
    (-) = zipBase sing
                  (-)
                  (\_          xs ys -> axpy (-1) ys (Just xs))
                  (\(SBM _ sM) xs ys -> gemm 1 xs (eye sM) (Just (-1, ys)))
    (*) = zipBTensorElems sing (*)
    negate = mapBase sing
                     negate
                     (\_          xs -> axpy (-1) xs Nothing)
                     (\(SBM _ sM) xs -> gemm 1 xs (eye sM) Nothing)
    abs    = mapBTensorElems abs
    signum = mapBTensorElems signum
    fromInteger i = genBTensor sing $ \_ -> fromInteger i

-- | TODO: add RULES pragmas so that this can be done without checking
-- lengths at runtime in the common case that the lengths are known at
-- compile-time.
--
-- Also, totally forgot about matrix-scalar multiplication here, but there
-- isn't really any way of making it work without a lot of empty cases.
-- should probably handle one level up.
dispatchBLAS
    :: forall b ms os ns v. (Floating (ElemB b), BLAS b)
    => MaxLength N1 ms
    -> MaxLength N1 os
    -> MaxLength N1 ns
    -> BTensor v b (ms         ++ os)
    -> BTensor v b (Reverse os ++ ns)
    -> BTensor v b (ms         ++ ns)
dispatchBLAS lM lO lN v r = case (lM, lO, lN) of
    (MLZ    , MLZ    , MLZ    ) -> case (v, r) of
      -- scalar-scalar
      (BTS x, BTS y) -> BTS $ x * y
    (MLZ    , MLZ    , MLS MLZ) -> case (v, r) of
      -- scalar-vector
      (BTS x, BTV y) -> BTV $ axpy x y Nothing
    (MLZ    , MLS MLZ, MLZ    ) -> case (v, r) of
      -- dot
      (BTV x, BTV y) -> BTS $ x `dot` y
    (MLZ    , MLS MLZ, MLS MLZ) -> case (v, r) of
      -- vector-matrix
      -- TODO: transpose?
      (BTV x, BTM y) -> BTV $ gemv 1 (transpB y) x Nothing
    (MLS MLZ, MLZ    , MLZ    ) -> case (v, r) of
      -- vector-scalar
      (BTV x, BTS y) -> BTV $ axpy y x Nothing
    (MLS MLZ, MLZ    , MLS MLZ) -> case (v, r) of
      -- vector-scalar
      (BTV x, BTV y) -> BTM $ ger x y
    (MLS MLZ, MLS MLZ, MLZ    ) -> case (v, r) of
      -- matrx-vector
      (BTM x, BTV y) -> BTV $ gemv 1 x y Nothing
    (MLS MLZ, MLS MLZ, MLS MLZ) -> case (v, r) of
      -- matrix-matrix
      (BTM x, BTM y) -> BTM $ gemm 1 x y Nothing

mapRows
    :: forall k (v :: k -> Type -> Type) ns ms os b. (Vec v, BLAS b)
    => Sing ns
    -> Length os
    -> (BTensor v b ms -> BTensor v b os)
    -> BTensor v b (ns ++ ms)
    -> BTensor v b (ns ++ os)
mapRows sN lO f = getI . bRows sN lO (I . f)


bRows
    :: forall k (v :: k -> Type -> Type) ns ms os b f. (Applicative f, Vec v, BLAS b)
    => Sing ns
    -> Length os
    -> (BTensor v b ms -> f (BTensor v b os))
    -> BTensor v b (ns ++ ms)
    -> f (BTensor v b (ns ++ os))
bRows sN lO f = bIxRows sN lO (\_ -> f)

mapIxRows
    :: forall k (v :: k -> Type -> Type) ns ms os b. (Vec v, BLAS b)
    => Sing ns
    -> Length os
    -> (Prod (IndexN k) ns -> BTensor v b ms -> BTensor v b os)
    -> BTensor v b (ns ++ ms)
    -> BTensor v b (ns ++ os)
mapIxRows sN lO f = getI . bIxRows sN lO (\i -> I . f i)

foldMapIxRows
    :: forall k (v :: k -> Type -> Type) ns ms m b. (Vec v, Monoid m, BLAS b)
    => Sing ns
    -> (Prod (IndexN k) ns -> BTensor v b ms -> m)
    -> BTensor v b (ns ++ ms)
    -> m
foldMapIxRows s f = getConst . bIxRows s LZ (\i -> Const . f i)

bIxRows
    :: forall k (v :: k -> Type -> Type) ns ms os b f. (Applicative f, Vec v, BLAS b)
    => Sing ns
    -> Length os
    -> (Prod (IndexN k) ns -> BTensor v b ms -> f (BTensor v b os))
    -> BTensor v b (ns ++ ms)
    -> f (BTensor v b (ns ++ os))
bIxRows = \case
    SNil   -> \_  f -> f Ø
    s `SCons` ss -> \lO f -> \case
      BTV xs -> case ss of
        -- ns ~ '[n]
        -- ms ~ '[]
        SNil -> case lO of
          -- ns ++ os ~ '[n]
          LZ        -> BTV <$> iElemsB (\i -> fmap unScalar . f (pbvProd i) . BTS) xs
          -- ns ++ os ~ '[n,m]
          LS LZ     -> BTM <$> bgenRowsA (\i -> unVector <$> f (i :< Ø) (BTS $ indexB (PBV i) xs))
                         \\ s
          LS (LS _) -> BTN <$> vGenA s (\i -> f (i :< Ø) (BTS $ indexB (PBV i) xs))
      BTM xs -> case ss of
        -- ns ~ '[n]
        -- ms ~ '[m]
        SNil -> case lO of
          -- ns ++ os ~ '[n]
          LZ        -> BTV <$> bgenA (SBV s) (\(PBV i) -> unScalar <$> f (i :< Ø) (BTV (indexRowB i xs)))
          -- ns ++ os ~ '[n,o]
          LS LZ     -> BTM <$> iRowsB (\i -> fmap unVector . f (i :< Ø) . BTV) xs
          LS (LS _) -> BTN <$> vGenA s (\i -> f (i :< Ø) (BTV (indexRowB i xs)))
        -- ns ~ '[n,m]
        -- ms ~ '[]
        s' `SCons` ss' -> (\\ s') $ case ss' of
          SNil -> case lO of
            LZ   -> BTM <$> iElemsB (\i -> fmap unScalar . f (pbmProd i) . BTS) xs
            LS _ -> BTN <$>
                      vGenA s (\i ->
                          btn lO <$>
                            vGenA s' (\j ->
                                f (i :< j :< Ø) (BTS (indexB (PBM i j) xs))
                              )
                        )
      BTN xs -> (\\ s) $
          fmap (btn (singLength ss `TCL.append'` lO))
        . vITraverse (\i -> bIxRows ss lO (\is -> f (i :< is)))
        $ xs

indexRowBTensor
    :: forall k (b :: BShape k -> Type) v ns ms.
     ( BLAS b
     , Vec v
     )
    => Prod (IndexN k) ns
    -> BTensor v b (ns ++ ms)
    -> BTensor v b ms
indexRowBTensor = \case
    Ø       -> id
    i :< is -> \case
      BTV xs -> case is of
        Ø      -> BTS $ indexB    (PBV i)   xs
      BTM xs -> case is of
        Ø      -> BTV $ indexRowB i         xs
        j :< Ø -> BTS $ indexB    (PBM i j) xs
      BTN xs -> indexRowBTensor is (vIndex i xs)

mapBTensorElems
    :: (Vec v, BLAS b)
    => (ElemB b -> ElemB b)
    -> BTensor v b ns
    -> BTensor v b ns
mapBTensorElems f = getI . bTensorElems (I . f)

bTensorElems
    :: forall k (v :: k -> Type -> Type) ns b f. (Applicative f, Vec v, BLAS b)
    => (ElemB b -> f (ElemB b))
    -> BTensor v b ns
    -> f (BTensor v b ns)
bTensorElems f = \case
    BTS x  -> BTS <$> f x
    BTV xs -> BTV <$> elemsB f xs
    BTM xs -> BTM <$> elemsB f xs
    BTN xs -> BTN <$> vITraverse (\_ x -> bTensorElems f x) xs

ifoldMapBTensor
    :: forall k (v :: k -> Type -> Type) ns m b. (Monoid m, Vec v, BLAS b)
    => (Prod (IndexN k) ns -> ElemB b -> m)
    -> BTensor v b ns
    -> m
ifoldMapBTensor f = getConst . bTensorIxElems (\i -> Const . f i)

bTensorIxElems
    :: forall k (v :: k -> Type -> Type) ns b f. (Applicative f, Vec v, BLAS b)
    => (Prod (IndexN k) ns -> ElemB b -> f (ElemB b))
    -> BTensor v b ns
    -> f (BTensor v b ns)
bTensorIxElems f = \case
    BTS x  -> BTS <$> f Ø x
    BTV xs -> BTV <$> iElemsB (f . pbvProd) xs
    BTM xs -> BTM <$> iElemsB (f . pbmProd) xs
    BTN xs -> BTN <$> vITraverse (\i -> bTensorIxElems (\is -> f (i :< is))) xs

zipBTensorElems
    :: forall v b ns. (BLAS b, Nesting1 Sing Applicative v)
    => Sing ns
    -> (ElemB b -> ElemB b -> ElemB b)
    -> BTensor v b ns
    -> BTensor v b ns
    -> BTensor v b ns
zipBTensorElems = \case
    SNil -> \f -> \case
      BTS x -> \case
        BTS y -> BTS (f x y)
    sN `SCons` SNil -> \f -> \case
      BTV xs -> \case
        BTV ys -> BTV (zipB (SBV sN) f xs ys)
    sN `SCons` (sM `SCons` SNil) -> \f -> \case
      BTM xs -> \case
        BTM ys -> BTM (zipB (SBM sN sM) f xs ys)
    (s :: Sing k) `SCons` ss@(_ `SCons` (_ `SCons` _)) -> \f -> \case
      BTN xs -> \case
        BTN ys -> BTN (zipBTensorElems ss f <$> xs <*> ys)
                    \\ (nesting1 s :: Wit (Applicative (v k)))

liftBTensor
    :: forall v b ns m n.
     ( BLAS b
     , Nesting1 Proxy Functor      v
     , Nesting1 Sing  Distributive v
     )
    => Sing ns
    -> TCV.Vec m (TCV.Vec n (ElemB b) -> ElemB b)
    -> TCV.Vec n (BTensor v b ns)
    -> TCV.Vec m (BTensor v b ns)
liftBTensor = \case
    SNil                         -> \fs xs ->
        let xs' = unScalar <$> xs
        in  BTS . ($ xs') <$> fs
    sN `SCons` SNil              -> \fs xs ->
        let xs' = unVector <$> xs
        in  BTV <$> liftB (SBV sN)    fs xs'
    sN `SCons` (sM `SCons` SNil) -> \fs xs ->
        let xs' = unMatrix <$> xs
        in  BTM <$> liftB (SBM sN sM) fs xs'
    (s :: Sing k) `SCons` ss@(_ `SCons` (_ `SCons` _)) -> \fs xs ->
        let xs' = unNested <$> xs
        in  (\\ (nesting1 s     :: Wit (Distributive (v k)))) $
              flip fmap fs $ \f ->
                BTN . fmap (getI . TCV.head') $
                  TCV.liftVecD (liftBTensor ss (I f TCV.:* TCV.ØV))
                               xs'
            -- (\\ (nesting1 Proxy :: Wit (Traversable  (v k)))) $
            --   fmap BTN . sequenceA . TCV.liftVecD (liftBTensor ss fs)
            --     $ xs'

mapBTM
    :: forall k (v :: k -> Type -> Type) ns n m ms b. (Vec v, BLAS b)
    => Sing ns
    -> Length ms
    -> (b ('BM n m) -> BTensor v b ms)
    -> BTensor v b (ns ++ [n,m])
    -> BTensor v b (ns ++ ms)
mapBTM sN lM f = getI . traverseBTM sN lM (I . f)

foldMapBTM
    :: (Monoid a, Vec v, BLAS b)
    => Length ns
    -> (b ('BM n m) -> a)
    -> BTensor v b (ns ++ [n,m])
    -> a
foldMapBTM l f = ifoldMapBTM l (\_ -> f)

traverseBTM
    :: forall k (v :: k -> Type -> Type) ns n m ms b f. (Applicative f, Vec v, BLAS b)
    => Sing ns
    -> Length ms
    -> (b ('BM n m) -> f (BTensor v b ms))
    -> BTensor v b (ns ++ [n,m])
    -> f (BTensor v b (ns ++ ms))
traverseBTM = \case
    SNil         -> \_ f -> \case
      BTM x  -> f x
    s `SCons` ss -> \lM f -> \case
      BTV _  -> case ss of
      BTM _  -> case ss of
      BTN xs -> (\\ s) $
          fmap (btn (singLength ss `TCL.append'` lM))
        . vITraverse (\_ -> traverseBTM ss lM f)
        $ xs

imapBTM
    :: forall k (v :: k -> Type -> Type) ns n m ms b. (Vec v, BLAS b)
    => Sing ns
    -> Length ms
    -> (Prod (IndexN k) ns -> b ('BM n m) -> BTensor v b ms)
    -> BTensor v b (ns ++ [n,m])
    -> BTensor v b (ns ++ ms)
imapBTM sN lM f = getI . itraverseBTM sN lM (\i -> I . f i)

ifoldMapBTM
    :: (Vec v, Monoid a, BLAS b)
    => Length ns
    -> (Prod (IndexN k) ns -> b ('BM n m) -> a)
    -> BTensor v b (ns ++ [n,m])
    -> a
ifoldMapBTM = \case
    LZ -> \f -> \case
      BTM xs -> f Ø xs
    LS l -> \f -> \case
      BTV _  -> case l of
      BTM _  -> case l of
      BTN xs -> vIFoldMap (\i -> ifoldMapBTM l (\is -> f (i :< is))) xs

itraverseBTM
    :: forall k (v :: k -> Type -> Type) ns n m ms b f. (Applicative f, Vec v, BLAS b)
    => Sing ns
    -> Length ms
    -> (Prod (IndexN k) ns -> b ('BM n m) -> f (BTensor v b ms))
    -> BTensor v b (ns ++ [n,m])
    -> f (BTensor v b (ns ++ ms))
itraverseBTM = \case
    SNil         -> \_ f -> \case
      BTM x  -> f Ø x
    s `SCons` ss -> \lM f -> \case
      BTV _  -> case ss of
      BTM _  -> case ss of
      BTN xs -> (\\ s) $
          fmap (btn (singLength ss `TCL.append'` lM))
        . vITraverse (\i -> itraverseBTM ss lM (\is ys -> f (i :< is) ys))
        $ xs

mapBase
    :: forall v b ns. (Nesting1 Proxy Functor v)
    => Sing ns
    -> (ElemB b -> ElemB b)
    -> (forall n. Sing n -> b ('BV n) -> b ('BV n))
    -> (forall n m. Sing ('BM n m) -> b ('BM n m) -> b ('BM n m))
    -> BTensor v b ns
    -> BTensor v b ns
mapBase = \case
    SNil -> \f _ _ -> \case
      BTS x  -> BTS (f x)
    sN `SCons` SNil -> \_ g _ -> \case
      BTV xs -> BTV (g sN          xs)
    sN `SCons` (sM `SCons` SNil) -> \_ _ h -> \case
      BTM xs -> BTM (h (SBM sN sM) xs)
    (_ :: Sing k) `SCons` ss@(_ `SCons` (_ `SCons` _)) -> \f g h -> \case
      BTN xs -> BTN (mapBase ss f g h <$> xs)
                  \\ (nesting1 Proxy :: Wit (Functor (v k)))

zipBase
    :: forall v b ns. (Nesting1 Sing Applicative v)
    => Sing ns
    -> (ElemB b -> ElemB b -> ElemB b)
    -> (forall n. Sing n -> b ('BV n) -> b ('BV n) -> b ('BV n))
    -> (forall n m. Sing ('BM n m) -> b ('BM n m) -> b ('BM n m) -> b ('BM n m))
    -> BTensor v b ns
    -> BTensor v b ns
    -> BTensor v b ns
zipBase = \case
    SNil -> \f _ _ -> \case
      BTS x -> \case
        BTS y -> BTS (f x y)
    sN `SCons` SNil -> \_ g _ -> \case
      BTV xs -> \case
        BTV ys -> BTV (g sN          xs ys)
    sN `SCons` (sM `SCons` SNil) -> \_ _ h -> \case
      BTM xs -> \case
        BTM ys -> BTM (h (SBM sN sM) xs ys)
    (s :: Sing k) `SCons` ss@(_ `SCons` (_ `SCons` _)) -> \f g h -> \case
      BTN xs -> \case
        BTN ys -> BTN $ zipBase ss f g h <$> xs <*> ys
                    \\ (nesting1 s :: Wit (Applicative (v k)))

genBTensorA
    :: forall k (b :: BShape k -> Type) v (ns :: [k]) f. (Applicative f, BLAS b, Vec v)
    => Sing ns
    -> (Prod (IndexN k) ns -> f (ElemB b))
    -> f (BTensor v b ns)
genBTensorA = \case
    SNil                                   -> \f ->
        BTS <$> f Ø
    sN `SCons` SNil                        -> \f ->
        BTV <$> bgenA (SBV sN)    (f . pbvProd)
    sN `SCons` (sM `SCons` SNil)           -> \f ->
        BTM <$> bgenA (SBM sN sM) (f . pbmProd)
    s `SCons` ss@(_ `SCons` (_ `SCons` _)) -> \f ->
        BTN <$> vGenA s (\i -> genBTensorA ss (\is -> f (i :< is)))

genBTensor
    :: forall k (b :: BShape k -> Type) v (ns :: [k]). (BLAS b, Vec v)
    => Sing ns
    -> (Prod (IndexN k) ns -> ElemB b)
    -> BTensor v b ns
genBTensor s f = getI $ genBTensorA s (I . f)

indexBTensor
    :: forall k (b :: BShape k -> Type) v ns. (BLAS b, Vec v)
    => Prod (IndexN k) ns
    -> BTensor v b ns
    -> ElemB b
indexBTensor = \case
    Ø      -> \case
      BTS x  -> x
    i :< Ø -> \case
      BTV xs -> indexB (PBV i) xs
    i :< j :< Ø -> \case
      BTM xs -> indexB (PBM i j) xs
    i :< js@(_ :< _ :< _) -> \case
      BTN xs -> indexBTensor js (vIndex i xs)

btn :: (BLAS b, Vec v, SingI n)
    => Length ns
    -> v n (BTensor v b ns)
    -> BTensor v b (n ': ns)
btn = \case
    LZ        -> \xs ->
      BTV $ bgen sing (unScalar . (`vIndex` xs) . unPBV)
    LS LZ     -> \xs ->
      BTM $ bgenRows  (unVector . (`vIndex` xs))
    LS (LS _) -> BTN

-- | General strategy:
--
-- *   We can only outsource to BLAS (using 'dispatchBLAS') in the case
--     that @os@ and @ns@ have length 0 or 1.  Anything else, fall back to
--     the basic reverse-indexing method in "Data.Nested".
-- *   If @ms@ is length 2 or higher, "traverse down" to the length 0 or
--     1 tail...and then sum them up.
gmulB
    :: forall k (b :: BShape k -> Type) v ms os ns.
     ( Floating (ElemB b)
     , SingI ns
     , BLAS b
     , Vec v
     , Nesting1 Proxy Functor     v
     , Nesting1 Sing  Applicative v
     )
    => Sing ms
    -> Length os
    -> Length ns
    -> BTensor v b (ms         ++ os)
    -> BTensor v b (Reverse os ++ ns)
    -> BTensor v b (ms         ++ ns)
gmulB sM lO lN v r = case splitting (S_ Z_) (lengthProd lN) of
    Fewer mlN _ -> case splittingEnd (S_ (S_ Z_)) (lengthProd lO) of
      FewerEnd MLZ             _ -> gmulBLAS sM MLZ       mlN v r
      FewerEnd (MLS MLZ)       _ -> gmulBLAS sM (MLS MLZ) mlN v r
      FewerEnd (MLS (MLS MLZ)) _ -> case mlN of
        MLZ -> case r of
          BTM ys -> mapBTM sM LZ (\xs -> BTS $ traceB (gemm 1 xs ys Nothing)) v
        MLS MLZ -> naiveGMul sM lO lN v r
      SplitEnd _ _ _ -> naiveGMul sM lO lN v r
    Split _ _ _ -> naiveGMul sM lO lN v r

-- | Naive implementation of 'gmul' (based on the implementation for
-- 'NTensor') that does not utilize any BLAS capabilities.
naiveGMul
    :: forall k (b :: BShape k -> Type) v ms os ns.
     ( BLAS b
     , Vec v
     , Num (ElemB b)
     , Nesting1 Proxy Functor     v
     , Nesting1 Sing  Applicative v
     , SingI ns
     )
    => Sing ms
    -> Length os
    -> Length ns
    -> BTensor v b (ms         ++ os)
    -> BTensor v b (Reverse os ++ ns)
    -> BTensor v b (ms         ++ ns)
naiveGMul sM _ lN v r =
    mapRows sM lN (getSum . ifoldMapBTensor (\i -> Sum . f i)) v
  where
    f  :: Prod (IndexN k) os
       -> ElemB b
       -> BTensor v b ns
    f is x = mapBase sing
                     (x *)
                     (\_ ys -> axpy x ys Nothing)
                     (\(SBM _ s) ys -> gemm x ys (eye s) Nothing)
                     (indexRowBTensor (TCP.reverse' is) r)

-- | A 'gmul' that runs my dispatching BLAS commands when it can.
-- Contains the type-level constraint that @os@ and @ns@ have to have
-- either length 0 or 1.
gmulBLAS
    :: forall b ms os ns v.
     ( Floating (ElemB b)
     , BLAS b
     , Vec v
     , SingI ns
     , Nesting1 Proxy Functor     v
     , Nesting1 Sing  Applicative v
     )
    => Sing ms
    -> MaxLength N1 os
    -> MaxLength N1 ns
    -> BTensor v b (ms         ++ os)
    -> BTensor v b (Reverse os ++ ns)
    -> BTensor v b (ms         ++ ns)
gmulBLAS sM mlO mlN v r = case mlO of
    MLZ -> case splittingEnd (S_ (S_ Z_)) spM of
      FewerEnd MLZ             _ -> dispatchBLAS MLZ       mlO  mlN v r
      FewerEnd (MLS MLZ)       _ -> dispatchBLAS (MLS MLZ) mlO mlN v r
      FewerEnd (MLS (MLS MLZ)) (_ :< s :< Ø) -> case v of
        BTM xs -> case mlN of
          MLZ     -> case r of
            BTS y  -> BTM $ gemm y xs (eye s) Nothing
          -- TODO: can this be made non-naive?
          -- ms ~ '[m1,m2]
          -- os ~ '[]
          -- ns ~ '[n]
          MLS MLZ -> naiveGMul sM LZ (fromMaxLength mlN) v r
      SplitEnd (ELS (ELS ELZ)) spM0 spM1@(_ :< s :< Ø) -> case mlN of
        MLZ -> case r of
          BTS y -> mapBTM (prodSing   spM0)
                          (prodLength spM1)
                          (\xs -> BTM $ gemm y xs (eye s) Nothing)
                          v
                     \\ appendNil lM
        -- TODO: can this be made non-naive?
        -- ms ~ (ms0 ++ '[m1,m2])
        -- os ~ '[]
        -- ns ~ '[n]
        MLS MLZ -> naiveGMul sM LZ (fromMaxLength mlN) v r
    MLS MLZ -> case splittingEnd (S_ Z_) spM of
      FewerEnd mlM       _         -> dispatchBLAS mlM mlO mlN v r
      SplitEnd (ELS ELZ) spM0 spM1 ->
        let sM0 = prodSing spM0
            lM0 = prodLength spM0
            lM1 = prodLength spM1
        in  (\\ appendAssoc (TCL.tail' lM0)
                            lM1
                            (LS LZ :: Length os)
            ) $ case mlN of
          MLZ -> case r of
            BTV ys -> mapBTM sM0 lM1 (\xs -> BTV $ gemv 1 xs ys Nothing) v
                        \\ appendNil lM
          MLS MLZ -> case r of
            BTM ys -> mapBTM sM0
                            (lM1 `TCL.append'` (LS LZ :: Length ns))
                            (\xs -> BTM $ gemm 1 xs ys Nothing)
                            v
                        \\ appendAssoc (TCL.tail' lM0)
                                       lM1
                                       (LS LZ :: Length ns)
  where
    spM = singProd sM
    lM = singLength sM

diagBTensor
    :: forall k (b :: BShape k -> Type) v n ns.
     ( SingI (n ': ns)
     , BLAS b
     , Vec v
     , Num (ElemB b)
     , Eq (IndexN k n)
     )
    => Uniform n ns
    -> BTensor v b '[n]
    -> BTensor v b (n ': ns)
diagBTensor = \case
    UØ    -> id
    US UØ -> \case
      BTV xs -> BTM $ diagB xs
    u@(US (US _)) -> \(BTV xs) ->
      genBTensor sing (\i -> case TCV.uniformVec (prodToVec I (US u) i) of
                               Nothing -> 0
                               Just (I i') -> indexB (PBV i') xs
                      )

transpBTensor
    :: (BLAS b, Vec v)
    => Sing ns
    -> BTensor v b ns
    -> BTensor v b (Reverse ns)
transpBTensor s = \case
    BTS x      -> BTS x
    BTV xs     -> BTV xs
    BTM xs     -> BTM $ transpB xs
    xs@(BTN _) -> (\\ reverseReverse (singLength s)) $
                    genBTensor (sReverse s) $ \i ->
                      indexBTensor (TCP.reverse' i) xs

instance
      ( Vec (v :: k -> Type -> Type)
      , BLAS b
      , Floating (ElemB b)
      , Nesting1 Proxy Functor      v
      , Nesting1 Sing  Applicative  v
      , Nesting1 Sing  Distributive v
      , Eq1 (IndexN k)
      )
  => Tensor (BTensor v b) where
    type ElemT (BTensor v b) = ElemB b

    liftT
        :: SingI ns
        => TCV.Vec m (TCV.Vec n (ElemB b) -> ElemB b)
        -> TCV.Vec n (BTensor v b ns)
        -> TCV.Vec m (BTensor v b ns)
    liftT = liftBTensor sing

    gmul
        :: forall ms os ns. SingI (ms ++ ns)
        => Length ms
        -> Length os
        -> Length ns
        -> BTensor v b (ms         ++ os)
        -> BTensor v b (Reverse os ++ ns)
        -> BTensor v b (ms         ++ ns)
    gmul lM lO lN = gmulB sM lO lN \\ sN
      where
        sM :: Sing ms
        sN :: Sing ns
        (sM, sN) = splitSing lM sing

    diag
        :: forall n ns. SingI (n ': ns)
        => Uniform n ns
        -> BTensor v b '[n]
        -> BTensor v b (n ': ns)
    diag = diagBTensor
             \\ (produceEq1 :: Eq1 (IndexN k) :- Eq (IndexN k n))

    getDiag
        :: SingI n
        => Uniform n ns
        -> BTensor v b (n ': n ': ns)
        -> BTensor v b '[n]
    getDiag = \case
      UØ   -> \case
        BTM xs -> BTV $ getDiagB xs
      u@(US _) -> \xs ->
        genBTensor sing $ \(i :< Ø) ->
          indexBTensor (TCP.replicate i (US (US u))) xs

    transp = transpBTensor sing

    generateA = genBTensorA sing

    genRand d g = generateA (\_ -> realToFrac <$> genContVar d g)

    ixRows
        :: forall f ms os ns. (Applicative f, SingI (ms ++ os))
        => Length ms
        -> Length os
        -> (Prod (IndexN k) ms -> BTensor v b ns -> f (BTensor v b os))
        -> BTensor v b (ms ++ ns)
        -> f (BTensor v b (ms ++ os))
    ixRows lM lO = bIxRows sM lO
      where
        sM :: Sing ms
        sM = takeSing lM lO (sing :: Sing (ms ++ os))

    (!) = flip indexBTensor

