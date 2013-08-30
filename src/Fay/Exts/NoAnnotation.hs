module Fay.Exts.NoAnnotation where

import qualified Language.Haskell.Exts.Annotated as A

type X = ()

type Alt = A.Alt X
type BangType = A.BangType X
type ClassDecl = A.ClassDecl X
type Decl = A.Decl X
type DeclHead = A.DeclHead X
type Ex = A.Exp X
type Exp = A.Exp X
type ExportSpec = A.ExportSpec X
type FieldDecl = A.FieldDecl X
type FieldUpdate = A.FieldUpdate X
type GadtDecl = A.GadtDecl X
type GuardedAlts = A.GuardedAlts X
type GuardedRhs = A.GuardedRhs X
type ImportDecl = A.ImportDecl X
type ImportSpec = A.ImportSpec X
type Literal = A.Literal X
type Match = A.Match X
type Module = A.Module X
type ModuleName = A.ModuleName X
type ModulePragma = A.ModulePragma X
type Name = A.Name X
type Pat = A.Pat X
type PatField = A.PatField X
type QName = A.QName X
type QOp = A.QOp X
type QualConDecl = A.QualConDecl X
type QualStmt = A.QualStmt X
type Rhs = A.Rhs X
type SpecialCon = A.SpecialCon X
type SrcLoc = A.SrcLoc
type SrcSpan = A.SrcSpan
type SrcSpanInfo = A.SrcSpanInfo
type Stmt = A.Stmt X
type TyVarBind = A.TyVarBind X
type Type = A.Type X

unAnn :: Functor f => f a -> f ()
unAnn = fmap (const ())
