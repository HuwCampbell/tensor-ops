{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeOperators       #-}

module TensorOps.Run where

import           Data.Foldable
import           Data.Singletons
import           Data.Singletons.Prelude
import           Data.Type.Combinator
import           Data.Type.Product hiding (append', toList)
import           Data.Type.Product.Util
import           Data.Type.Sing
import           Data.Type.Uniform
import           TensorOps.Types
import           Type.Class.Witness
import qualified TensorOps.Tensor         as TT

runTOp
    :: forall (ns :: [[k]]) (ms :: [[k]]) (t :: [k] -> *).
     ( Tensor t
     , Floating (ElemT t)
     )
    => Sing ns
    -> Sing ms
    -> TOp ns ms
    -> Prod t ns
    -> Prod t ms
runTOp sNs sMs = (\\ witSings sNs) $
                 (\\ witSings sMs) $ \case
    Lift uNs uMs f -> case uMs of
                        UØ   -> \_ -> Ø
                        US _ -> vecToProd getI uMs . liftT (getVF <$> f) . prodToVec I uNs
                                  \\ uniformLength uMs
    GMul lM lO lN  -> \case
      x :< y :< Ø -> only (gmul lM lO lN x y)
    Transp _       -> only . transp . head'
    Shuffle i      -> select i
    SumRows        -> only . sumRows . head'
                        \\ sHead (sHead sNs)
    SumT u         -> only . sumT . toList . prodToVec I u
    -- Scale α        -> only . TT.map (*α) . head'
    Scale α        -> only . TT.scale α . head'
                        \\ sHead (sHead sNs)
    -- Fold _ f       -> only . foldT f     . head'

runTensorOp
    :: forall t ns ms. (Tensor t, Floating (ElemT t))
    => TensorOp ns ms
    -> Prod t ns
    -> Prod t ms
runTensorOp = \case
    OPØ                 -> id
    Pop sA sB sD o os -> runTensorOp os
                       . overProdInit (singLength sA)
                                      (singLength sD)
                                      (runTOp sA sB o)

    -- OP1 o    -> runTOp o
    -- oL :. oR -> runTensorOp oR . runTensorOp oL
    -- oL :* oR -> overProdSplit known (runTensorOp oL) (runTensorOp oR)
    -- oL :& oR -> uncurry append' . (runTensorOp oL &&& runTensorOp oR)
