{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

module Etch.Analysis.Semantics where

import qualified Data.HashMap.Lazy as HM
import Control.Monad.Except
import Control.Monad.State
import Control.Lens (use, (%=))
import Text.Show.Pretty (ppShow)
import qualified Etch.Types.SyntaxTree as Syntax
import Etch.Types.Analysis
import Etch.Types.ErrorContext
import Etch.Types.Lenses
import Etch.Types.SemanticTree

type MonadAnalysis m = (MonadError ErrorContext m, MonadState AnalysisState m)

analysis :: MonadAnalysis m => [Syntax.Statement] -> m [Typed Statement]
analysis statements = traverse statementAnalysis statements

statementAnalysis :: MonadAnalysis m => Syntax.Statement -> m (Typed Statement)
statementAnalysis (Syntax.DefStatement def)   = tymap DefStatement     <$> defAnalysis def
statementAnalysis (Syntax.ForeignStatement f) = tymap ForeignStatement <$> foreignAnalysis f
statementAnalysis (Syntax.ExprStatement expr) = tymap ExprStatement    <$> exprAnalysis expr

exprAnalysis :: MonadAnalysis m => Syntax.Expr -> m (Typed Expr)
exprAnalysis (Syntax.FunctionExpr function) = tymap FunctionExpr <$> functionAnalysis function
exprAnalysis (Syntax.CallExpr call)         = tymap CallExpr     <$> callAnalysis call
exprAnalysis (Syntax.BranchExpr branch)     = tymap BranchExpr   <$> branchAnalysis branch
exprAnalysis (Syntax.CompoundExpr compound) = tymap CompoundExpr <$> compoundAnalysis compound

compoundAnalysis :: MonadAnalysis m => Syntax.Compound -> m (Typed Compound)
compoundAnalysis (Syntax.OpCompound op)     = tymap OpCompound      <$> opAnalysis op
compoundAnalysis (Syntax.AtomCompound atom) = tymap PrimaryCompound <$> atomAnalysis atom

atomAnalysis :: MonadAnalysis m => Syntax.Atom -> m (Typed Primary)
atomAnalysis (Syntax.SigAtom sig@(Syntax.Sig primary atom)) = do
    pVal `As` actualTy <- primaryAnalysis primary
    atomAnalysis atom >>= \case
        TypePrimary (expectedTy `As` _) `As` _ -> if actualTy == expectedTy || actualTy == UnresolvedType
            then pure (pVal `As` expectedTy)
            else throwError $ ErrorContext "expected type does not match actual type" [ppShow expectedTy, ppShow actualTy, show sig]
        t@(_ `As` UnresolvedType)              -> pure (pVal `As` PrimaryType t)
        typed                                  -> throwError $ ErrorContext "not a type" [ppShow typed]
atomAnalysis (Syntax.PrimaryAtom primary) = primaryAnalysis primary

primaryAnalysis :: MonadAnalysis m => Syntax.Primary -> m (Typed Primary)
primaryAnalysis (Syntax.BlockPrimary block) = tymap BlockPrimary <$> blockAnalysis block
primaryAnalysis (Syntax.TuplePrimary exprs) = do
    typeds <- traverse exprAnalysis exprs
    pure $ TuplePrimary typeds `As` TupleType (typedTy <$> typeds)
primaryAnalysis (Syntax.NewPrimary exprs) = do
    typeds <- traverse exprAnalysis exprs
    newID <- use nextID
    nextID %= succ
    pure $ NewPrimary newID typeds `As` NewType newID (typedTy <$> typeds)
primaryAnalysis (Syntax.IdentPrimary ident) = pure (IdentPrimary ident `As` UnresolvedType)
primaryAnalysis (Syntax.IntegerPrimary x)   = pure (IntegerPrimary x   `As` IntType 32)
primaryAnalysis (Syntax.StringPrimary s)    = pure (StringPrimary s    `As` StringType)

defAnalysis :: MonadAnalysis m => Syntax.Def -> m (Typed Def)
defAnalysis (Syntax.Def name expr) = do
    e <- exprAnalysis expr
    scope %= HM.insert name (Term (typedTy e) HM.empty)
    pure $ tymap (Def name) e

foreignAnalysis :: MonadAnalysis m => Syntax.Foreign -> m (Typed Foreign)
foreignAnalysis (Syntax.Foreign (Syntax.Sig name atom)) = do
    a <- atomAnalysis atom
    scope %= HM.insert name (Term (typedTy a) HM.empty) -- XXX: need scopes
    pure (Foreign name `As` PrimaryType a)

functionAnalysis :: MonadAnalysis m => Syntax.Function -> m (Typed Function)
functionAnalysis (Syntax.Function (Syntax.ParamList params) expr) = do
    args <- traverse paramAnalysis params
    e <- exprAnalysis expr
    let paramTys = typedTy <$> args
    pure $ Function (ParamList args) e `As` FunctionType paramTys (typedTy e)

callAnalysis :: MonadAnalysis m => Syntax.Call -> m (Typed Call)
callAnalysis (Syntax.Call callable expr) = do
    c <- compoundAnalysis callable
    e <- exprAnalysis expr
    (Call c e `As`) <$> callTypeAnalysis (typedTy c)

callTypeAnalysis :: MonadAnalysis m => Type -> m Type
callTypeAnalysis (TupleType [ty])                    = callTypeAnalysis ty
callTypeAnalysis (FunctionType _ retTy)              = pure retTy
callTypeAnalysis (BuiltinType FunctionBuiltin)       = pure (BuiltinType FunctionBuiltin)
callTypeAnalysis (BuiltinType (Function2Builtin ty)) = pure (BuiltinType (Function2Builtin ty))
callTypeAnalysis (BuiltinType IntNBuiltin)           = pure (BuiltinType IntNBuiltin)
callTypeAnalysis (BuiltinType PtrBuiltin)            = pure (BuiltinType PtrBuiltin)
callTypeAnalysis UnresolvedType                      = pure (UnresolvedType)
callTypeAnalysis ty                                  = throwError $ ErrorContext "type is not callable" [ppShow ty]

branchAnalysis :: MonadAnalysis m => Syntax.Branch -> m (Typed Branch)
branchAnalysis (Syntax.Branch cond trueBranch falseBranch) = do
    c <- compoundAnalysis cond
    t <- exprAnalysis trueBranch
    f <- exprAnalysis falseBranch
    pure (Branch c t f `As` typedTy t)

opAnalysis :: MonadAnalysis m => Syntax.Op -> m (Typed Op)
opAnalysis (Syntax.Op op lhs rhs) = do
    l <- atomAnalysis lhs
    r <- compoundAnalysis rhs
    pure (Op op l r `As` typedTy l)

blockAnalysis :: MonadAnalysis m => Syntax.Block -> m (Typed Block)
blockAnalysis (Syntax.Block statements) = do
    s <- traverse statementAnalysis statements
    let retTy = if null s then TupleType [] else typedTy (last s)
    pure $ Block s `As` retTy

paramAnalysis :: MonadAnalysis m => Syntax.Param -> m (Typed Param)
paramAnalysis (Syntax.SigParam (Syntax.Sig name atom)) = do
    a <- atomAnalysis atom
    scope %= HM.insert name (Term (typedTy a) HM.empty) -- XXX: need scopes
    pure (name `As` PrimaryType a)
-- paramAnalysis (Syntax.SigParam (Syntax.AtomSig name ty)) = atomAnalysis >>= \case
--     TypePrimary t `As` _ ->

--        TypePrimary (expectedTy `As` _) `As` _ -> if actualTy == expectedTy || actualTy == UnresolvedType
--            then pure (pVal `As` expectedTy)
--            else fail ("expected type `" ++ show expectedTy ++ "` does not match actual type `" ++ show actualTy ++ "`: " ++ show sig)
paramAnalysis (Syntax.InferredParam name)            = pure (name `As` UnresolvedType)
