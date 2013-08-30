{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- | Preprocessing collecting names, data types, newtypes, imports, and exports
-- for all modules recursively.
module Fay.Compiler.InitialPass
  (initialPass
  ) where

import           Fay.Compiler.Config
import           Fay.Compiler.GADT
import           Fay.Compiler.Misc
import           Fay.Compiler.ModuleScope
import           Fay.Control.Monad.Extra
import           Fay.Control.Monad.IO
import           Fay.Data.List.Extra
import           Fay.Types
import qualified Fay.Exts as F
import qualified Fay.Exts.NoAnnotation as N
import Fay.Exts.NoAnnotation (unAnn)

import           Control.Applicative
import           Control.Monad.Error
import           Control.Monad.RWS
import qualified Data.Set as S
import qualified Data.Map as M
import           Language.Haskell.Exts.Annotated hiding (name, var)
import           Prelude hiding (mod, read)

-- | Preprocess and collect all information needed during code generation.
initialPass :: F.Module -> Compile ()
initialPass mod@(Module _ _ _pragmas imports decls) =
  withModuleScope $ do
    modify $ \s -> s { stateModuleName = (unAnn modName)
                     , stateModuleScope = findTopLevelNames modName decls
                     }
    forM_ imports compileImport
    forM_ decls scanRecordDecls
    forM_ decls scanNewtypeDecls
    case modExports of
      Just (ExportSpecList _ exps) -> mapM_ emitExport exps
      Nothing -> do
        exps <- moduleLocals (unAnn modName) <$> gets stateModuleScope
        modify $ flip (foldr addCurrentExport) exps
    modify $ \s -> s { stateModuleScopes = M.insert (unAnn modName )(stateModuleScope s) (stateModuleScopes s) }
  where
    modName = F.moduleName mod
    modExports = F.moduleExports mod
initialPass m = throwError (UnsupportedModuleSyntax "initialPass" m)

compileImport :: F.ImportDecl -> Compile ()
compileImport (ImportDecl _ _ _ _ Just{} _ _) = return ()
compileImport (ImportDecl _ name False _ Nothing Nothing Nothing) =
  compileImportWithFilter name (const $ return True)
compileImport (ImportDecl _ name False _ Nothing Nothing (Just (ImportSpecList _ True specs))) =
  compileImportWithFilter name (fmap not . imported specs)
compileImport (ImportDecl _ name False _ Nothing Nothing (Just (ImportSpecList _ False specs))) =
  compileImportWithFilter name (imported specs)
compileImport i =
  throwError $ UnsupportedImport i

compileWith :: (Show from,Parseable from)
            => FilePath
            -> CompileReader
            -> CompileState
            -> (from -> Compile ())
            -> String
            -> Compile (Either CompileError ((),CompileState,CompileWriter))
compileWith filepath r st with from =
  io $ runCompile r
                  st
                  (parseResult (throwError . uncurry ParseError)
                  with
                  (parseFay filepath from))

-- | Don't re-import the same modules.
unlessImported :: ModuleName a
               -> (N.QName -> Compile Bool)
               -> (FilePath -> String -> Compile ())
               -> Compile ()
unlessImported (ModuleName _ "Fay.Types") _ _ = return ()
unlessImported name importFilter importIt = do
  isImported <- lookup (unAnn name) <$> gets stateImported
  case isImported of
    Just _ -> return ()
    Nothing -> do
      dirs <- configDirectoryIncludePaths <$> config id
      (filepath,contents) <- findImport dirs (unAnn name)
      modify $ \s -> s { stateImported = ((unAnn name),filepath) : stateImported s }
      importIt filepath contents
  imports <- filterM importFilter . S.toList =<< gets (getExportsFor name)
  modify $ \s -> s { stateModuleScope = bindAsLocals imports (stateModuleScope s) }

-- | Find newtype declarations
scanNewtypeDecls :: F.Decl -> Compile ()
scanNewtypeDecls (DataDecl _ NewType{} _ _ constructors _) = compileNewtypeDecl constructors
scanNewtypeDecls _ = return ()

-- | Add new types to the state
compileNewtypeDecl :: [F.QualConDecl] -> Compile ()
compileNewtypeDecl [QualConDecl _ _ _ condecl] =
  case condecl of
      -- newtype declaration without destructor
    ConDecl _ name  [ty]            -> addNewtype name Nothing ty
    RecDecl _ cname [FieldDecl _ [dname] ty] -> addNewtype cname (Just dname) ty
    x -> error $ "compileNewtypeDecl case: Should be impossible (this is a bug). Got: " ++ show x
  where
    getBangTy :: F.BangType -> N.Type
    getBangTy (BangedTy _ t)   = unAnn t
    getBangTy (UnBangedTy _ t) = unAnn t
    getBangTy (UnpackedTy _ t) = unAnn t

    addNewtype cname dname ty = do
      qcname <- qualify cname
      qdname <- case dname of
                  Nothing -> return Nothing
                  Just n  -> Just <$> qualify n
      modify (\cs@CompileState{stateNewtypes=nts} ->
               cs{stateNewtypes=(qcname,qdname,getBangTy ty):nts})
compileNewtypeDecl q = error $ "compileNewtypeDecl: Should be impossible (this is a bug). Got: " ++ show q

declHeadName :: F.DeclHead -> F.Name
declHeadName d = case d of
  DHead _ n _ -> n
  DHInfix _ _ n _ -> n
  DHParen _ h -> declHeadName h

-- | Add record declarations to the state
scanRecordDecls :: F.Decl -> Compile ()
scanRecordDecls decl = do
  case decl of
    DataDecl _loc DataType{} _ctx (declHeadName -> name) qualcondecls _deriv -> do
      let ns = for qualcondecls (\(QualConDecl _loc' _tyvarbinds _ctx' condecl) -> conDeclName condecl)
      addRecordTypeState name ns
    _ -> return ()

  case decl of
    DataDecl _ DataType{} _ _ constructors _ -> dataDecl constructors
    GDataDecl _ DataType{} _ _ _ decls _ -> dataDecl (map convertGADT decls)
    _ -> return ()

  where
    addRecordTypeState (unAnn -> name) (map unAnn -> cons) = modify $ \s -> s
      { stateRecordTypes = (UnQual () name, map (UnQual ()) cons) : stateRecordTypes s }

    conDeclName (ConDecl _ n _) = n
    conDeclName (InfixConDecl _ _ n _) = n
    conDeclName (RecDecl _ n _) = n

    -- | Collect record definitions and store record name and field names.
    -- A ConDecl will have fields named slot1..slotN
    dataDecl :: [F.QualConDecl] -> Compile ()
    dataDecl constructors = do
      forM_ constructors $ \(QualConDecl _ _ _ condecl) ->
        case condecl of
          ConDecl _ name types -> do
            let fields =  map (Ident () . ("slot"++) . show . fst) . zip [1 :: Integer ..] $ types
            addRecordState name fields
          InfixConDecl _ _t1 name _t2 ->
            addRecordState name [F.mkIdent "slot1", F.mkIdent "slot2"]
          RecDecl _ name fields' -> do
            let fields = concatMap fieldDeclNames fields'
            addRecordState name fields

      where
        addRecordState :: Name a -> [Name b] -> Compile ()
        addRecordState (unAnn -> name) (map unAnn -> fields) = modify $ \s -> s
          { stateRecords = (UnQual () name,map (UnQual ()) fields) : stateRecords s }

-- | Is this name imported from anywhere?
imported :: [ImportSpec a] -> QName b -> Compile Bool
imported (map unAnn -> is) (unAnn -> qn) = anyM (matching qn) is
  where
    matching :: N.QName -> N.ImportSpec -> Compile Bool
    matching (Qual _ _ name) (IAbs _ typ) = return $ name == typ
    matching (Qual _ _ name) (IVar _ var) = return $ name == var
    matching (Qual _ _ name) (IThingAll _ typ) = do
      recs <- typeToRecs $ UnQual () (unAnn typ)
      if UnQual () (unAnn name) `elem` recs
        then return True
        else do
          fields <- typeToFields $ UnQual () (unAnn typ)
          return $ UnQual () (unAnn name) `elem` fields
    matching (Qual _ _ name) (IThingWith _ typ cns) =
      flip anyM cns $ \cn -> case cn of
        ConName _ _ -> do
          recs <- typeToRecs $ UnQual () (unAnn typ)
          return $ UnQual () (unAnn name) `elem` recs
        VarName _ _ -> do
          fields <- typeToFields $ UnQual () (unAnn typ)
          return $ UnQual () (unAnn name) `elem` fields
    matching q is' = error $ "compileImport: Unsupported QName ImportSpec combination " ++ show (q, is') ++ ", this is a bug!"

-- | Compile an import filtering the exports based on the current module's imports
compileImportWithFilter :: F.ModuleName -> (N.QName -> Compile Bool) -> Compile ()
compileImportWithFilter name importFilter =
  unlessImported name importFilter $ \filepath contents -> do
    read <- ask
    stat <- get
    result <- compileWith filepath read stat initialPass contents
    case result of
      Right ((),st,_) -> do
        imports <- filterM importFilter $ S.toList $ getCurrentExports st
        -- Merges the state gotten from passing through an imported
        -- module with the current state. We can assume no duplicate
        -- records exist since GHC would pick that up.
        modify $ \s -> s { stateRecords      = stateRecords st
                         , stateLocalScope   = S.empty
                         , stateRecordTypes  = stateRecordTypes st
                         , stateImported     = stateImported st
                         , stateNewtypes     = stateNewtypes st
                         , stateModuleScope  = bindAsLocals imports (stateModuleScope s)
                         , _stateExports     = _stateExports st
                         , stateModuleScopes = stateModuleScopes st
                         }
      Left err -> throwError err
