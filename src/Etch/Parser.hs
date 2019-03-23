{-# LANGUAGE OverloadedStrings #-}

module Etch.Parser where

import qualified Data.Attoparsec.Text as Atto (parse)
import Data.Attoparsec.Text hiding (parse)
import Data.Text
import Control.Applicative ((<|>), many)
import Control.Monad (when)
import qualified Etch.Lexer as L
import Etch.Types.ErrorContext
import Etch.Types.SyntaxTree

parse :: Text -> Either ErrorContext [Statement]
parse text = f (Atto.parse statementParser text)
  where f (Fail area contexts err) = Left $ ErrorContext ("parser failure: " ++ err) (unpack area : contexts)
        f (Partial cont)           = f (cont "")
        f (Done "" result)         = pure [result]
        f (Done remainder result)  = (result :) <$> parse remainder

statementParser :: Parser Statement
statementParser = DefStatement  <$> defParser
              <|> ExprStatement <$> exprParser

exprParser :: Parser Expr
exprParser = CallExpr     <$> callParser
         <|> BranchExpr   <$> branchParser
         <|> CompoundExpr <$> compoundParser

compoundParser :: Parser Compound
compoundParser = OpCompound      <$> opParser
             <|> AtomCompound <$> atomParser

atomParser :: Parser Atom
atomParser = SigAtom     <$> sigParser primaryParser
         <|> PrimaryAtom <$> primaryParser

primaryParser :: Parser Primary
primaryParser = BlockPrimary   <$> blockParser
            <|> TypePrimary    <$> typeParser
            <|> TuplePrimary   <$> tupleParser exprParser '(' ',' ')'
            <|> IdentPrimary   <$> L.identifierParser
            <|> IntegerPrimary <$> L.integerParser
            <|> StringPrimary  <$> L.stringLiteralParser

sigParser :: Parser a -> Parser (Sig a)
sigParser p = Sig     <$> p <* L.charParser ':' <*> typeParser
          <|> AtomSig <$> p <* L.charParser ':' <*> atomParser

defParser :: Parser Def
defParser = Def <$> L.identifierParser <* L.charParser '=' <*> exprParser

callParser :: Parser Call
callParser = Call <$> compoundParser <* L.charsParser "<-" <*> exprParser

branchParser :: Parser Branch
branchParser = Branch <$> compoundParser
                      <*  L.charParser '?'
                      <*> exprParser
                      <*  L.charParser ':'
                      <*> exprParser

opParser :: Parser Op
opParser = do
    lhs <- atomParser
    op  <- L.operatorParser
    when (op == "->") (fail "operator `->` is reserved")
    when (op == "<-") (fail "operator `<-` is reserved")
    Op op lhs <$> compoundParser

blockParser :: Parser Block
blockParser = Block <$> paramListParser <* L.charsParser "->" <*> blockInnerParser
          <|> Block (ParamList [])                            <$> blockInnerParser

blockInnerParser :: Parser [Statement]
blockInnerParser = L.charParser '{'
                *> many statementParser
               <*  L.charParser '}'

typeParser :: Parser Type
typeParser = IntType 32 <$  L.charsParser "int"
         <|> NewType    <$> paramListParser <* L.charsParser "->" <*> tupleParser atomParser '<' ',' '>'
         <|> NewType (ParamList [])                               <$> tupleParser atomParser '<' ',' '>'

paramListParser :: Parser ParamList
paramListParser = ParamList <$> tupleParser paramParser '(' ',' ')'
              <|> ParamList <$> pure <$> paramParser

paramParser :: Parser Param
paramParser = SigParam      <$> sigParser L.identifierParser
          <|> InferredParam <$> L.identifierParser

tupleParser :: Parser a -> Char -> Char -> Char -> Parser [a]
tupleParser p start sep end = L.charParser start
                           *> p `sepBy` L.charParser sep
                           <* L.charParser end
