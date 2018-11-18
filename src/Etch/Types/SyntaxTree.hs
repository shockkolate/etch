module Etch.Types.SyntaxTree where

import Data.Text (Text)

data Statement = SigStatement Sig
               | DefStatement Def
               | ExprStatement Expr
                 deriving Show

data Expr = CallExpr Call
          | BranchExpr Branch
          | CompoundExpr Compound
            deriving Show

data Compound = OpCompound Op
              | PrimaryCompound Primary
                deriving Show

data Primary = BlockPrimary Block
             | TuplePrimary [Expr]
             | IdentPrimary Text
             | IntegerPrimary Integer
             | StringPrimary Text
               deriving Show

data Sig = Sig Expr Type
           deriving Show

data Type = IntType
            deriving Show

data Def = Def Text Expr
           deriving Show

data Call = Call Compound Expr
            deriving Show

data Branch = Branch Compound Expr Expr
              deriving Show

data Op = Op Text Primary Compound
          deriving Show

data Block = Block [Text] [Statement]
             deriving Show