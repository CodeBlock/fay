{-# OPTIONS -fno-warn-name-shadowing -fno-warn-orphans #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}


-- | Compile expressions.

module Fay.Compiler.Exp where

import Fay.Compiler.Misc
import Fay.Compiler.Pattern
import Fay.Compiler.Print
import Fay.Compiler.FFI             (compileFFIExp)
import Fay.Types
import qualified Fay.Exts as F
import Fay.Exts (noI)
import Fay.Exts.NoAnnotation (unAnn)

import Control.Applicative
import Control.Monad.Error
import Control.Monad.RWS
import Data.Maybe
import Language.Haskell.Exts.Annotated

-- | Compile Haskell expression.
compileExp :: F.Exp -> Compile JsExp
compileExp exp =
  case exp of
    Paren _ exp                     -> compileExp exp
    Var _ qname                     -> compileVar qname
    Lit _ lit                       -> compileLit lit
    App _ exp1 exp2                 -> compileApp exp1 exp2
    NegApp _ exp                    -> compileNegApp exp
    InfixApp _ exp1 op exp2         -> compileInfixApp exp1 op exp2
    Let _ (BDecls _ decls) exp      -> compileLet decls exp
    List _ []                       -> return JsNull
    List _ xs                       -> compileList xs
    Tuple _ _boxed xs               -> compileList xs
    If _ cond conseq alt            -> compileIf cond conseq alt
    Case _ exp alts                 -> compileCase exp alts
    Con _ (UnQual _ (Ident _ "True"))  -> return (JsLit (JsBool True))
    Con _ (UnQual _ (Ident _ "False")) -> return (JsLit (JsBool False))
    Con _ qname                     -> compileVar qname
    Do _ stmts                      -> compileDoBlock stmts
    Lambda _ pats exp               -> compileLambda pats exp
    LeftSection _ e o               -> compileExp =<< desugarLeftSection e o
    RightSection _ o e              -> compileExp =<< desugarRightSection o e
    EnumFrom _ i                    -> compileEnumFrom i
    EnumFromTo _ i i'               -> compileEnumFromTo i i'
    EnumFromThen _ a b              -> compileEnumFromThen a b
    EnumFromThenTo _ a b z          -> compileEnumFromThenTo a b z
    RecConstr _ name fieldUpdates   -> compileRecConstr name fieldUpdates
    RecUpdate _ rec  fieldUpdates   -> compileRecUpdate rec fieldUpdates
    ListComp _ exp stmts            -> compileExp =<< desugarListComp exp stmts
    ExpTypeSig srcloc exp sig     ->
      case ffiExp exp of
        Nothing -> compileExp exp
        Just formatstr -> compileFFIExp srcloc Nothing formatstr sig

    exp -> throwError (UnsupportedExpression exp)

-- | Compiling instance.
instance CompilesTo F.Exp JsExp where compileTo = compileExp

-- | Turn a tuple constructor into a normal lambda expression.
tupleConToFunction :: Boxed -> Int -> F.Exp
tupleConToFunction b n = Lambda noI params body
  where names  = take n (Ident noI . pure <$> ['a'..])
        params = PVar noI <$> names
        body   = Tuple noI b (Var noI . UnQual noI <$> names)

-- | Compile variable.
compileVar :: F.QName -> Compile JsExp
compileVar qname = do
  case qname of
    Special _ (TupleCon _ b n) -> compileExp (tupleConToFunction b n)
    _ -> do
      qname <- unsafeResolveName qname
      return (JsName (JsNameVar qname))

-- | Compile Haskell literal.
compileLit :: F.Literal -> Compile JsExp
compileLit lit =
  case lit of
    Char _ ch _      -> return (JsLit (JsChar ch))
    Int _ integer _   -> return (JsLit (JsInt (fromIntegral integer))) -- FIXME:
    Frac _ rational _ -> return (JsLit (JsFloating (fromRational rational)))
    -- TODO: Use real JS strings instead of array, probably it will
    -- lead to the same result.
    String _ string _ -> do
      fromString <- gets stateUseFromString
      if fromString
        then return (JsLit (JsStr string))
        else return (JsApp (JsName (JsBuiltIn "list")) [JsLit (JsStr string)])
    lit           -> throwError (UnsupportedLiteral lit)

-- | Compile simple application.
compileApp :: F.Exp -> F.Exp -> Compile JsExp
compileApp exp1@(Con _ q) exp2 =
  maybe (compileApp' exp1 exp2) (const $ compileExp exp2) =<< lookupNewtypeConst q
compileApp exp1@(Var _ q) exp2 =
  maybe (compileApp' exp1 exp2) (const $ compileExp exp2) =<< lookupNewtypeDest q
compileApp exp1 exp2 =
  compileApp' exp1 exp2

-- | Helper for compileApp.
compileApp' :: F.Exp -> F.Exp -> Compile JsExp
compileApp' exp1 exp2 = do
  flattenApps <- config configFlattenApps
  jsexp1 <- compileExp exp1
  (if flattenApps then method2 else method1) jsexp1 exp2
    where
    -- Method 1:
    -- In this approach code ends up looking like this:
    -- a(a(a(a(a(a(a(a(a(a(L)(c))(b))(0))(0))(y))(t))(a(a(F)(3*a(a(d)+a(a(f)/20))))*a(a(f)/2)))(140+a(f)))(y))(t)})
    -- Which might be OK for speed, but increases the JS stack a fair bit.
    method1 :: JsExp -> F.Exp -> Compile JsExp
    method1 exp1 exp2 =
      JsApp <$> (forceFlatName <$> return exp1)
            <*> fmap return (compileExp exp2)
      where
        forceFlatName name = JsApp (JsName JsForce) [name]

    -- Method 2:
    -- In this approach code ends up looking like this:
    -- d(O,a,b,0,0,B,w,e(d(I,3*e(e(c)+e(e(g)/20))))*e(e(g)/2),140+e(g),B,w)}),d(K,g,e(c)+0.05))
    -- Which should be much better for the stack and readability, but probably not great for speed.
    method2 :: JsExp -> F.Exp -> Compile JsExp
    method2 exp1 exp2 = fmap flatten $
      JsApp <$> return exp1
            <*> fmap return (compileExp exp2)
      where
        flatten (JsApp op args) =
         case op of
           JsApp l r -> JsApp l (r ++ args)
           _        -> JsApp (JsName JsApply) (op : args)
        flatten x = x

-- | Compile a negate application
compileNegApp :: F.Exp -> Compile JsExp
compileNegApp e = JsNegApp . force <$> compileExp e

-- | Compile an infix application, optimizing the JS cases.
compileInfixApp :: F.Exp -> F.QOp -> F.Exp -> Compile JsExp
compileInfixApp exp1 ap exp2 = compileExp (App noI (App noI (Var noI op) exp1) exp2)

  where op = getOp ap
        getOp (QVarOp _ op) = op
        getOp (QConOp _ op) = op

-- | Compile a let expression.
compileLet :: [F.Decl] -> F.Exp -> Compile JsExp
compileLet decls exp =
  withScope $ do
    generateScope $ mapM compileLetDecl decls
    binds <- mapM compileLetDecl decls
    body <- compileExp exp
    return (JsApp (JsFun Nothing [] [] (Just $ stmtsThunk $ concat binds ++ [JsEarlyReturn body])) [])

-- | Compile let declaration.
compileLetDecl :: F.Decl -> Compile [JsStmt]
compileLetDecl decl = do
  compileDecls <- asks readerCompileDecls
  case decl of
    decl@PatBind{} -> compileDecls False [decl]
    decl@FunBind{} -> compileDecls False [decl]
    TypeSig{}      -> return []
    _              -> throwError (UnsupportedLetBinding decl)

-- | Compile a list expression.
compileList :: [F.Exp] -> Compile JsExp
compileList xs = do
  exps <- mapM compileExp xs
  return (makeList exps)

-- | Compile an if.
compileIf :: F.Exp -> F.Exp -> F.Exp -> Compile JsExp
compileIf cond conseq alt =
  JsTernaryIf <$> fmap force (compileExp cond)
              <*> compileExp conseq
              <*> compileExp alt

-- | Compile case expressions.
compileCase :: F.Exp -> [F.Alt] -> Compile JsExp
compileCase exp alts = do
  exp <- compileExp exp
  withScopedTmpJsName $ \tmpName -> do
    pats <- fmap optimizePatConditions $ mapM (compilePatAlt (JsName tmpName)) alts
    return $
      JsApp (JsFun Nothing
                   [tmpName]
                   (concat pats)
                   (if any isWildCardAlt alts
                       then Nothing
                       else Just (throwExp "unhandled case" (JsName tmpName))))
            [exp]

-- | Compile the given pattern against the given expression.
compilePatAlt :: JsExp -> F.Alt -> Compile [JsStmt]
compilePatAlt exp alt@(Alt _ pat rhs wheres) = case wheres of
  Just (BDecls _ (_ : _)) -> throwError (UnsupportedWhereInAlt alt)
  Just (IPBinds _ (_ : _)) -> throwError (UnsupportedWhereInAlt alt)
  _ -> withScope $ do
    generateScope $ compilePat exp pat []
    alt <- compileGuardedAlt rhs
    compilePat exp pat [alt]

-- | Compile a guarded alt.
compileGuardedAlt :: F.GuardedAlts -> Compile JsStmt
compileGuardedAlt alt =
  case alt of
    UnGuardedAlt _ exp -> JsEarlyReturn <$> compileExp exp
    GuardedAlts _ alts -> compileGuards (map altToRhs alts)
   where
    altToRhs (GuardedAlt l s e) = GuardedRhs l s e

-- | Compile guards
compileGuards :: [F.GuardedRhs] -> Compile JsStmt
compileGuards ((GuardedRhs _ (Qualifier _ (Var _ (UnQual _ (Ident _ "otherwise"))):_) exp):_) =
  (\e -> JsIf (JsLit $ JsBool True) [JsEarlyReturn e] []) <$> compileExp exp
compileGuards (GuardedRhs _ (Qualifier _ guard:_) exp : rest) =
  makeIf <$> fmap force (compileExp guard)
         <*> compileExp exp
         <*> if null rest then return [] else do
           gs' <- compileGuards rest
           return [gs']
    where makeIf gs e gss = JsIf gs [JsEarlyReturn e] gss

compileGuards rhss = throwError . UnsupportedRhs . GuardedRhss noI $ rhss

-- | Compile a do block.
compileDoBlock :: [F.Stmt] -> Compile JsExp
compileDoBlock stmts = do
  doblock <- foldM compileStmt Nothing (reverse stmts)
  maybe (throwError EmptyDoBlock) compileExp doblock

-- | Compile a lambda.
compileLambda :: [F.Pat] -> F.Exp -> Compile JsExp
compileLambda pats exp =
  withScope $ do
    generateScope $ generateStatements JsNull
    exp   <- compileExp exp
    stmts <- generateStatements exp
    case stmts of
      [JsEarlyReturn fun@JsFun{}] -> return fun
      _ -> error "Unexpected statements in compileLambda"

  where unhandledcase = throw "unhandled case" . JsName
        allfree = all isWildCardPat pats
        generateStatements exp =
          foldM (\inner (param,pat) -> do
                  stmts <- compilePat (JsName param) pat inner
                  return [JsEarlyReturn (JsFun Nothing [param] (stmts ++ [unhandledcase param | not allfree]) Nothing)])
                [JsEarlyReturn exp]
                (reverse (zip uniqueNames pats))

-- | Desugar left sections to lambdas.
desugarLeftSection :: F.Exp -> F.QOp -> Compile F.Exp
desugarLeftSection e o = withScopedTmpName $ \tmp ->
    return (Lambda noI [PVar noI tmp] (InfixApp noI e o (Var noI (UnQual noI tmp))))

-- | Desugar left sections to lambdas.
desugarRightSection :: F.QOp -> F.Exp -> Compile F.Exp
desugarRightSection o e = withScopedTmpName $ \tmp ->
    return (Lambda noI [PVar noI tmp] (InfixApp noI (Var noI (UnQual noI tmp)) o e))

-- | Compile [e1..] arithmetic sequences.
compileEnumFrom :: F.Exp -> Compile JsExp
compileEnumFrom i = do
  e <- compileExp i
  name <- unsafeResolveName $ UnQual () $ Ident () "enumFrom"
  return (JsApp (JsName (JsNameVar name)) [e])

-- | Compile [e1..e3] arithmetic sequences.
compileEnumFromTo :: F.Exp -> F.Exp -> Compile JsExp
compileEnumFromTo i i' = do
  f <- compileExp i
  t <- compileExp i'
  name <- unsafeResolveName $ UnQual () $ Ident () "enumFromTo"
  cfg <- config id
  return $ case optEnumFromTo cfg f t of
    Just s -> s
    _ -> JsApp (JsApp (JsName (JsNameVar name)) [f]) [t]

-- | Compile [e1,e2..] arithmetic sequences.
compileEnumFromThen :: F.Exp -> F.Exp -> Compile JsExp
compileEnumFromThen a b = do
  fr <- compileExp a
  th <- compileExp b
  name <- unsafeResolveName $ UnQual () $ Ident () "enumFromThen"
  return (JsApp (JsApp (JsName (JsNameVar name)) [fr]) [th])

-- | Compile [e1,e2..e3] arithmetic sequences.
compileEnumFromThenTo :: F.Exp -> F.Exp -> F.Exp -> Compile JsExp
compileEnumFromThenTo a b z = do
  fr <- compileExp a
  th <- compileExp b
  to <- compileExp z
  name <- unsafeResolveName $ UnQual () $ Ident () "enumFromThenTo"
  cfg <- config id
  return $ case optEnumFromThenTo cfg fr th to of
    Just s -> s
    _ -> JsApp (JsApp (JsApp (JsName (JsNameVar name)) [fr]) [th]) [to]

-- | Compile a record construction with named fields
-- | GHC will warn on uninitialized fields, they will be undefined in JS.
compileRecConstr :: F.QName -> [F.FieldUpdate] -> Compile JsExp
compileRecConstr (unAnn -> name) fieldUpdates = do
    -- var obj = new $_Type()
    qname <- unsafeResolveName name
    let record = JsVar (JsNameVar name) (JsNew (JsConstructor qname) [])
    setFields <- liftM concat (forM fieldUpdates (updateStmt name))
    return $ JsApp (JsFun Nothing [] (record:setFields) (Just (JsName (JsNameVar name)))) []
  where updateStmt :: QName a -> F.FieldUpdate -> Compile [JsStmt]
        updateStmt (unAnn -> o) (FieldUpdate _ (unAnn -> field) value) = do
          exp <- compileExp value
          return [JsSetProp (JsNameVar o) (JsNameVar field) exp]
        updateStmt (unAnn -> name) (FieldWildcard _) = do
          records <- liftM stateRecords get
          let fields = fromJust (lookup name records)
          return (map (\fieldName -> JsSetProp (JsNameVar name)
                                               (JsNameVar fieldName)
                                               (JsName (JsNameVar fieldName)))
                      fields)
        -- TODO: FieldPun
        -- I couldn't find a code that generates (FieldUpdate (FieldPun ..))
        updateStmt _ u = error ("updateStmt: " ++ show u)

-- | Compile a record update.
compileRecUpdate :: F.Exp -> [F.FieldUpdate] -> Compile JsExp
compileRecUpdate rec fieldUpdates = do
    record <- force <$> compileExp rec
    let copyName = UnQual () $ Ident () "$_record_to_update"
        copy = JsVar (JsNameVar copyName)
                     (JsRawExp ("Object.create(" ++ printJSString record ++ ")"))
    setFields <- forM fieldUpdates (updateExp copyName)
    return $ JsApp (JsFun Nothing [] (copy:setFields) (Just (JsName (JsNameVar copyName)))) []
  where updateExp :: QName a -> F.FieldUpdate -> Compile JsStmt
        updateExp (unAnn -> copyName) (FieldUpdate _ (unAnn -> field) value) =
          JsSetProp (JsNameVar copyName) (JsNameVar field) <$> compileExp value
        updateExp (unAnn -> copyName) (FieldPun _ (unAnn -> name)) =
          -- let a = 1 in C {a}
          return $ JsSetProp (JsNameVar copyName)
                             (JsNameVar (UnQual () name))
                             (JsName (JsNameVar (UnQual () name)))
        -- TODO: FieldWildcard
        -- I also couldn't find a code that generates (FieldUpdate FieldWildCard)
        updateExp _ FieldWildcard{} = error "unsupported update: FieldWildcard"

-- | Desugar list comprehensions.
desugarListComp :: F.Exp -> [F.QualStmt] -> Compile F.Exp
desugarListComp e [] =
    return (List noI [ e ])
desugarListComp e (QualStmt _ (Generator _ p e2) : stmts) = do
    nested <- desugarListComp e stmts
    withScopedTmpName $ \f ->
      return (Let noI (BDecls noI [ FunBind noI [
          Match noI f [ p             ] (UnGuardedRhs noI nested) Nothing
        , Match noI f [ PWildCard noI ] (UnGuardedRhs noI (List noI [])) Nothing
        ]]) (App noI (App noI (Var noI (UnQual noI (Ident noI "concatMap"))) (Var noI (UnQual noI f))) e2))
desugarListComp e (QualStmt _ (Qualifier _ e2)       : stmts) = do
    nested <- desugarListComp e stmts
    return (If noI e2 nested (List noI []))
desugarListComp e (QualStmt _ (LetStmt _ bs)         : stmts) = do
    nested <- desugarListComp e stmts
    return (Let noI bs nested)
desugarListComp _ (s                             : _    ) =
    throwError (UnsupportedQualStmt s)

-- | Make a Fay list.
makeList :: [JsExp] -> JsExp
makeList exps = JsApp (JsName $ JsBuiltIn "list") [JsList exps]

-- | Compile a statement of a do block.
compileStmt :: Maybe F.Exp -> F.Stmt -> Compile (Maybe F.Exp)
compileStmt inner stmt =
  case inner of
    Nothing -> initStmt
    Just inner -> subsequentStmt inner

  where initStmt =
          case stmt of
            Qualifier _ exp -> return (Just exp)
            LetStmt{}     -> throwError UnsupportedLet
            _             -> throwError InvalidDoBlock

        subsequentStmt inner =
          case stmt of
            Generator loc pat exp -> compileGenerator loc pat inner exp
            Qualifier _ exp -> return (Just (InfixApp noI exp
                                                    (QVarOp noI (UnQual noI (Symbol noI ">>")))
                                                    inner))
            LetStmt _ (BDecls _ binds) -> return (Just (Let noI (BDecls noI binds) inner))
            LetStmt _ _ -> throwError UnsupportedLet
            RecStmt{} -> throwError UnsupportedRecursiveDo

        compileGenerator srcloc pat inner exp = do
          let body = Lambda srcloc [pat] inner
          return (Just (InfixApp noI
                                 exp
                                 (QVarOp noI (UnQual noI (Symbol noI ">>=")))
                                 body))

-- | Optimize short literal [e1..e3] arithmetic sequences.
optEnumFromTo :: CompileConfig -> JsExp -> JsExp -> Maybe JsExp
optEnumFromTo cfg (JsLit f) (JsLit t) =
  if configOptimize cfg
  then case (f,t) of
    (JsInt fl, JsInt tl) -> strict JsInt fl tl
    (JsFloating fl, JsFloating tl) -> strict JsFloating fl tl
    _ -> Nothing
  else Nothing
    where strict :: (Enum a, Ord a, Num a) => (a -> JsLit) -> a -> a -> Maybe JsExp
          strict litfn f t =
            if fromEnum t - fromEnum f < maxStrictASLen
            then Just . makeList . map (JsLit . litfn) $ enumFromTo f t
            else Nothing
optEnumFromTo _ _ _ = Nothing

-- | Optimize short literal [e1,e2..e3] arithmetic sequences.
optEnumFromThenTo :: CompileConfig -> JsExp -> JsExp -> JsExp -> Maybe JsExp
optEnumFromThenTo cfg (JsLit fr) (JsLit th) (JsLit to) =
  if configOptimize cfg
  then case (fr,th,to) of
    (JsInt frl, JsInt thl, JsInt tol) -> strict JsInt frl thl tol
    (JsFloating frl, JsFloating thl, JsFloating tol) -> strict JsFloating frl thl tol
    _ -> Nothing
  else Nothing
    where strict :: (Enum a, Ord a, Num a) => (a -> JsLit) -> a -> a -> a -> Maybe JsExp
          strict litfn fr th to =
            if (fromEnum to - fromEnum fr) `div`
               (fromEnum th - fromEnum fr) + 1 < maxStrictASLen
            then Just . makeList . map (JsLit . litfn) $ enumFromThenTo fr th to
            else Nothing
optEnumFromThenTo _ _ _ _ = Nothing

-- | Maximum number of elements to allow in strict list representation
-- of arithmetic sequences.
maxStrictASLen :: Int
maxStrictASLen = 10
