{-# LANGUAGE RecordWildCards, PatternGuards #-}
module Agda.Compiler.Treeless.Simplify (simplifyTTerm) where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Writer
import Data.Traversable (traverse)

import Agda.Syntax.Treeless
import Agda.Syntax.Internal (Substitution'(..))
import Agda.Syntax.Literal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Primitive
import Agda.TypeChecking.Substitute
import Agda.Utils.Maybe

import Agda.Compiler.Treeless.Subst
import Agda.Compiler.Treeless.NPlusK

type S = Reader (Substitution' TTerm)

runS :: S a -> a
runS m = runReader m IdS

lookupVar :: Int -> S TTerm
lookupVar i = asks (`lookupS` i)

underLams :: Int -> S a -> S a
underLams i = local (liftS i)

underLam :: S a -> S a
underLam = underLams 1

underLet :: TTerm -> S a -> S a
underLet u = local $ \rho -> wkS 1 $ composeS rho (singletonS 0 u)

data FunctionKit = FunctionKit
  { modAux, divAux :: Maybe QName }

simplifyTTerm :: TTerm -> TCM TTerm
simplifyTTerm t = do
  modAux <- getBuiltinName builtinNatModSucAux
  divAux <- getBuiltinName builtinNatDivSucAux
  return $ if isNothing modAux && isNothing divAux then t else
    runS $ simplify FunctionKit{ modAux = modAux, divAux = divAux } t

simplify :: FunctionKit -> TTerm -> S TTerm
simplify FunctionKit{..} = simpl
  where
    simpl t = case t of

      TApp (TDef f) [TLit (LitInt _ 0), m, n, m']
        | m == m', Just f == divAux -> simpl $ TApp (TPrim "div") [n, plus 1 m]
        | m == m', Just f == modAux -> simpl $ TApp (TPrim "mod") [n, plus 1 m]

      TVar{}         -> pure t
      TDef{}         -> pure t
      TPrim{}        -> pure t
      t@TApp{} | Just (k, n) <- plusView t -> do
        n <- simpl n
        case n of
          TVar x -> do
            u <- lookupVar x
            case u of
              TApp (TPrim "-") [TVar y, TLit (LitInt _ j)]
                | k == j    -> pure $ TVar y
                | k > j     -> pure $ plus (k - j) (TVar y)
                | otherwise -> pure $ TApp (TPrim "-") [TVar y, tInt (j - k)]
              _ -> pure $ plus k n
          _      -> pure $ plus k n
      TApp f es      -> TApp <$> simpl f <*> traverse simpl es
      TLam b         -> TLam <$> underLam (simpl b)
      TLit{}         -> pure t
      TCon{}         -> pure t
      TLet e b       -> do
        e <- simpl e
        TLet e <$> underLet e (simpl b)

      TCase x t d bs -> do
        d  <- simpl d
        bs <- traverse simplAlt bs
        tCase x t d bs

      TPi a b        -> TPi <$> simplTy a <*> underLam (simplTy b)
      TUnit          -> pure t
      TSort          -> pure t
      TErased        -> pure t
      TError{}       -> pure t

    simplAlt (TACon c a b) = TACon c a <$> underLams a (simpl b)
    simplAlt (TALit l b)   = TALit l   <$> simpl b
    simplAlt (TAPlus k b)  = TAPlus k  <$> underLam (simpl b)

    simplTy (TType t) = TType <$> simpl t

    tCase :: Int -> CaseType -> TTerm -> [TAlt] -> S TTerm
    tCase x t d bs
      | isError d =
        case reverse bs' of
          [] -> pure d
          TALit _ b   : as  -> pure $ tCase' x t b (reverse as)
          TAPlus k b  : as  -> do
                 -- TODO: retraversing the body (quadratic in nesting level!)
            b <- simpl (TLet (TApp (TPrim "-") [TVar x, tInt k]) b)
            pure $ tCase' x t b (reverse as)
          TACon c a b : _   -> pure $ tCase' x t d bs'
      | otherwise = pure $ TCase x t d bs'
      where
        bs' = filter (not . isErrorAlt) bs

        tCase' x t d [] = d
        tCase' x t d bs = TCase x t d bs

isErrorAlt :: TAlt -> Bool
isErrorAlt = isError . aBody

isError :: TTerm -> Bool
isError TError{} = True
isError _ = False
