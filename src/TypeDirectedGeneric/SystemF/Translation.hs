{-# LANGUAGE OverloadedStrings #-}

module TypeDirectedGeneric.SystemF.Translation where

import Control.Monad
--import Control.Monad.Extra
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

import qualified Common.FGGAST as G
import Common.PrettyUtils
import Common.Types
import TypeDirectedGeneric.TransCommon

import qualified TypeDirectedGeneric.SystemF as TL

structPrefix :: T.Text
structPrefix = T.pack "Struct"
interfacePrefix :: T.Text
interfacePrefix = T.pack "Interface"
typePrefix :: G.TyLit -> T.Text
typePrefix (G.Struct _) = structPrefix
typePrefix (G.TySyn _) = T.pack "TypeSynonym"
typePrefix (G.Iface _) = interfacePrefix

isInterface :: T.Text -> Bool
isInterface typeName = T.isPrefixOf interfacePrefix typeName
isStruct :: T.Text -> Bool
isStruct typeName = T.isPrefixOf structPrefix typeName

stripPrefixOrIgnore :: T.Text -> T.Text -> T.Text
stripPrefixOrIgnore prefix name = case T.stripPrefix prefix name of
                                    Just stripped -> stripped
                                    Nothing -> name

voidReceiver :: (G.VarName, G.TyName, G.TyFormals)
voidReceiver = (G.VarName "void", G.TyName "void", G.TyFormals [])

tupleName :: Int -> TL.ConstrName
tupleName i = TL.ConstrName $ T.pack $ "Tuple" ++ (show i)
tupleTyVarName :: Int -> TL.TyVarName
tupleTyVarName i = TL.TyVarName $ T.pack $ "T" ++ (show i)
generateGenericTuples :: Int -> [TL.Decl]
generateGenericTuples max = map (\i -> TL.DeclData (tupleName i) (map tupleTyVarName [1..i]) (map (\j -> TL.TyVar (tupleTyVarName j)) [1..i])) [0..max]

fst3 :: (a, b, c) -> a
fst3 (a, _, _) = a
snd3 :: (a, b, c) -> b
snd3 (_, a, _) = a
thrd3 :: (a, b, c) -> c
thrd3 (_, _, a) = a

translateDeclaration :: G.Decl -> T [TL.Decl]
translateDeclaration (G.TypeDecl (G.TyName name) formals typeLiteral) = withCtx ("translation of type declaration " ++ (prettyS name)) $ do
    tyEnv <- pure $ tyFormalsToTyEnv formals
    translatedFormals <- pure $ translateTyVarNames formals
    (translatedTypes, additionalDeclarations) <- translateTypeLiteral tyEnv formals typeLiteral name
    declarations <- pure $ (TL.DeclData (TL.ConstrName $ (typePrefix typeLiteral) <> name) translatedFormals translatedTypes) : additionalDeclarations
    pure declarations
translateDeclaration (G.FunDecl methodSpec methodBody) = 
    withCtx ("translation of function declaration " ++ (prettyS $ G.ms_name methodSpec)) $ translateMethodDeclaration Nothing methodSpec methodBody
translateDeclaration (G.MeDecl receiver methodSpec methodBody) =
    withCtx ("translation of method declaration " ++ (prettyS $ G.ms_name methodSpec) ++ " for receiver " ++ (prettyS $ snd3 receiver)) $ translateMethodDeclaration (Just receiver) methodSpec methodBody

translateMethodDeclaration :: Maybe (G.VarName, G.TyName, G.TyFormals) -> G.MeSpec -> G.MeBody -> T [TL.Decl]
translateMethodDeclaration receiver methodSpec methodBody = do
    tyEnv <- pure $ case receiver of
        Just (_, _, receiverFormals) -> tyFormalsToTyEnv receiverFormals
        Nothing -> emptyTyEnv
    tyEnv <- pure $ joinTyEnvs tyEnv $ tyFormalsToTyEnv $ G.msig_tyArgs $ G.ms_sig $ methodSpec
    varEnv <- mkVarEnv $ G.msig_args $ G.ms_sig methodSpec
    varEnv <- case receiver of
        Just (receiverName, receiverTypeName, receiverFormals) -> do
            receiverTypeArgs <- pure $ map (\(tyVar, _) -> G.TyVar tyVar) (G.unTyFormals receiverFormals)
            extendVarEnv varEnv [(receiverName, G.TyNamed receiverTypeName receiverTypeArgs)]
        Nothing -> pure varEnv
    translatedBody <- translateMethodBody varEnv tyEnv methodBody
    translatedAbstractionExpression <- buildAbstractionExpression tyEnv translatedBody receiver methodSpec
    translatedTypeInfo <- translateMethodSpec tyEnv receiver methodSpec
    name <- pure $ G.unMeName $ G.ms_name methodSpec
    name <- pure $ case receiver of
        Just r -> name <> "_" <> (G.unTyName $ snd3 r)
        Nothing -> name
    pure $ [(TL.DeclFun (TL.VarName name) translatedTypeInfo translatedAbstractionExpression)]

translateTyVarNames :: G.TyFormals -> [TL.TyVarName]
translateTyVarNames formals = map (\formal -> TL.TyVarName $ G.unTyVarName (fst formal)) (G.unTyFormals formals)

translateFormals :: G.TyFormals -> [TL.Ty]
translateFormals formals = map (\x -> TL.TyVar x) (translateTyVarNames formals)

translateTypeLiteral :: TyEnv -> G.TyFormals -> G.TyLit -> T.Text -> T ([TL.Ty], [TL.Decl])
translateTypeLiteral tyEnv _ (G.Struct fields) _ = do
    translatedTypes <- mapM (\field -> translateType tyEnv (snd field)) fields
    pure (translatedTypes, [])
translateTypeLiteral _ _ (G.TySyn _) _ = do
    failT "Type synonyms are not supported as of now"
translateTypeLiteral tyEnv _formals (G.Iface methods) _name = do
    translatedMethods <- mapM (translateMethodSpec tyEnv Nothing) methods
    pure (translatedMethods, [])

translateType :: TyEnv -> G.Type -> T TL.Ty
translateType tyEnv goType = do
    assertTypeOk tyEnv goType
    classified <- classifyTy goType
    case classified of
        TyKindBuiltin TyInt -> pure $ TL.TyPrim TL.PrimInt
        TyKindBuiltin TyRune -> pure $ TL.TyPrim TL.PrimInt
        TyKindBuiltin TyString -> pure $ TL.TyPrim TL.PrimString
        TyKindBuiltin TyBool -> pure $ TL.TyPrim TL.PrimBool
        TyKindBuiltin TyVoid -> pure $ TL.TyPrim TL.PrimVoid
        TyKindTyVar (G.TyVarName name) -> pure $ TL.TyVar $ TL.TyVarName name
        TyKindStruct tyName tyArgs -> do
            translatedTyArgs <- mapM (translateType tyEnv) tyArgs
            name <- pure $ G.unTyName tyName
            pure $ TL.TyConstr (TL.ConstrName $ structPrefix <> name) translatedTyArgs
        TyKindIface tyName tyArgs -> do
            translatedTyArgs <- mapM (translateType tyEnv) tyArgs
            name <- pure $ G.unTyName tyName
            pure $ TL.TyConstr (TL.ConstrName $ interfacePrefix <> name) translatedTyArgs

translateMethodSpec :: TyEnv -> Maybe (G.VarName, G.TyName, G.TyFormals) -> G.MeSpec -> T TL.Ty
translateMethodSpec oldTyEnv receiver (G.MeSpec _meName (G.MeSig formals args resultType)) = do
    tyEnv <- pure $ joinTyEnvs oldTyEnv $ tyFormalsToTyEnv formals
    translatedResultType <- translateType tyEnv resultType
    translatedFunArgs <- translateFunctionArguments tyEnv args
    translatedTypeWithArgs <- pure $ TL.TyArrow translatedFunArgs translatedResultType
    translatedCoercionArgs <- translateCoercionArguments tyEnv formals
    translatedTypeWithCoercions <- pure $ TL.TyArrow translatedCoercionArgs translatedTypeWithArgs
    translatedTypeWithTypeAbstractions <- pure $ translateTypeAbstractions formals translatedTypeWithCoercions
    case receiver of
        Nothing -> pure translatedTypeWithTypeAbstractions
        Just (_, receiverType, receiverTypeArgs) -> do
            tyVars <- pure $ map (\(tyVar, _) -> G.TyVar tyVar) (G.unTyFormals receiverTypeArgs)
            translatedReceiverType <- translateType tyEnv (G.TyNamed receiverType tyVars)
            translatedTypeWithReceiver <- pure $ TL.TyArrow translatedReceiverType translatedTypeWithTypeAbstractions
            translatedReceiverCoercionArgs <- translateCoercionArguments tyEnv receiverTypeArgs
            translatedTypeWithRecvCoercions <- pure $ TL.TyArrow translatedReceiverCoercionArgs translatedTypeWithReceiver
            translatedTypeWithRecvTypeAbstractions <- pure $ translateTypeAbstractions receiverTypeArgs translatedTypeWithRecvCoercions
            pure translatedTypeWithRecvTypeAbstractions

generateMethodSuffix :: Maybe (G.VarName, G.TyName, G.TyFormals) -> T.Text
generateMethodSuffix Nothing = ""
generateMethodSuffix (Just ("void", _, _)) = ""
generateMethodSuffix (Just (name, _, _)) = "_" <> (G.unVarName name)

translateFunctionArguments :: TyEnv -> [(G.VarName, G.Type)] -> T TL.Ty
translateFunctionArguments tyEnv args = do
    translatedTypes <- mapM (translateType tyEnv) (map snd args)
    argConstrName <- pure $ tupleName $ length args
    pure $ TL.TyConstr argConstrName translatedTypes

translateCoercionArguments :: TyEnv -> G.TyFormals -> T TL.Ty
translateCoercionArguments tyEnv formals = do
    constrName <- pure $ tupleName $ length (G.unTyFormals formals)
    translatedCoercionTypes <- mapM (\(name, bound) -> do
            tyvar <- pure $ TL.TyVar $ TL.TyVarName $ G.unTyVarName name
            target <- translateType tyEnv (maybeType bound)
            pure $ TL.TyArrow tyvar target
        ) (G.unTyFormals formals)
    pure $ TL.TyConstr constrName translatedCoercionTypes

translateTypeAbstractions :: G.TyFormals -> TL.Ty -> TL.Ty
translateTypeAbstractions formals inner = do
    translateTypeAbstractions' (reverse (G.unTyFormals formals)) inner
translateTypeAbstractions' :: [(G.TyVarName, Maybe G.Type)] -> TL.Ty -> TL.Ty
translateTypeAbstractions' [] inner = inner
translateTypeAbstractions' ((tyVarName, _):other) inner =
    translateTypeAbstractions' other (TL.TyForall (TL.TyVarName $ G.unTyVarName tyVarName) inner)

translateTypeAbstractionExpressions :: G.TyFormals -> TL.Exp -> TL.Exp
translateTypeAbstractionExpressions formals inner = do
    translateTypeAbstractionExpressions' (reverse (G.unTyFormals formals)) inner
translateTypeAbstractionExpressions' :: [(G.TyVarName, Maybe G.Type)] -> TL.Exp -> TL.Exp
translateTypeAbstractionExpressions' [] inner = inner
translateTypeAbstractionExpressions' ((tyVarName, _):other) inner =
    translateTypeAbstractionExpressions' other (TL.ExpTyAbs (TL.TyVarName $ G.unTyVarName tyVarName) inner)

funArgs :: T.Text
funArgs = T.pack "$funArgs"
coercionArgs :: T.Text
coercionArgs = T.pack "$coercionArgs"
receiverCoercionArgs :: T.Text
receiverCoercionArgs = T.pack "$receiverCoercionArgs"
buildAbstractionExpression :: TyEnv -> TL.Exp -> Maybe (G.VarName, G.TyName, G.TyFormals) -> G.MeSpec -> T TL.Exp
buildAbstractionExpression oldTyEnv innerExpression receiver (G.MeSpec _meName (G.MeSig formals args _)) = do
    tyEnv <- pure $ joinTyEnvs oldTyEnv $ tyFormalsToTyEnv formals
    funArgsVar <- pure $ (TL.VarName funArgs)
    coercionArgsVar <- pure $ (TL.VarName coercionArgs)
    receiverCoercionArgsVar <- pure $ (TL.VarName receiverCoercionArgs)
    -- surround with case expression to be able to access the coercion args
    translatedCoercionArgs <- translateCoercionArguments tyEnv formals
    caseExpr <- case translatedCoercionArgs of
        TL.TyConstr name types -> do
            varPatterns <- mapM (\(name, constraint) -> do
                    tyvar <- pure $ TL.TyVar $ TL.TyVarName $ G.unTyVarName name
                    constraintName <- case (maybeType constraint) of
                        G.TyNamed name _ -> pure name
                        _ -> failT ("Constraint " ++ (prettyS constraint) ++ " is not a named type")
                    target <- translateType tyEnv (maybeType constraint)
                    coercionType <- pure $ TL.TyArrow tyvar target
                    translatedName <- pure $ getCoercionAbsName name constraintName
                    pure $ TL.PatVar translatedName coercionType
                ) (G.unTyFormals formals)
            pure $ TL.ExpCase (TL.ExpVar coercionArgsVar) [TL.PatClause (TL.PatConstr name types varPatterns) innerExpression]
        _ -> failT "Internal error: coercion arguments are not a tuple"
    caseExpr <- case receiver of
        Just (_receiverName, _receiverType, receiverTypeArgs) -> do
            translatedReceiverCoercionArgs <- translateCoercionArguments tyEnv receiverTypeArgs
            case translatedReceiverCoercionArgs of
                TL.TyConstr name types -> do
                    varPatterns <- mapM (\(name, constraint) -> do
                            tyvar <- pure $ TL.TyVar $ TL.TyVarName $ G.unTyVarName name
                            constraintName <- case (maybeType constraint) of
                                G.TyNamed name _ -> pure name
                                _ -> failT ("Constraint " ++ (prettyS constraint) ++ " is not a named type")
                            target <- translateType tyEnv (maybeType constraint)
                            coercionType <- pure $ TL.TyArrow tyvar target
                            translatedName <- pure $ getCoercionAbsName name constraintName
                            pure $ TL.PatVar translatedName coercionType
                        ) (G.unTyFormals receiverTypeArgs)
                    pure $ TL.ExpCase (TL.ExpVar receiverCoercionArgsVar) [TL.PatClause (TL.PatConstr name types varPatterns) caseExpr]
                _ -> failT "Internal error: function arguments are not a tuple"
        Nothing -> pure caseExpr
    -- surround with case expression to be able to access the args
    translatedArgs <- translateFunctionArguments tyEnv args
    caseExpr <- case translatedArgs of
        TL.TyConstr name types -> do
            varPatterns <- mapM (\(name, goType) -> do
                    translatedType <- translateType tyEnv goType
                    translatedName <- pure $ TL.VarName $ G.unVarName name
                    pure $ TL.PatVar translatedName translatedType
                ) args
            pure $ TL.ExpCase (TL.ExpVar funArgsVar) [TL.PatClause (TL.PatConstr name types varPatterns) caseExpr]
        _ -> failT "Internal error: function arguments are not a tuple"
    abstracted <- pure $ TL.ExpAbs funArgsVar translatedArgs caseExpr
    abstracted <- pure $ TL.ExpAbs (TL.VarName coercionArgs) translatedCoercionArgs abstracted
    abstracted <- pure $ translateTypeAbstractionExpressions formals abstracted
    abstracted <- case receiver of
        Just (receiverName, receiverType, receiverTypeArgs) -> do
            tyVars <- pure $ map (\(tyVar, _) -> G.TyVar tyVar) (G.unTyFormals receiverTypeArgs)
            translatedReceiverType <- translateType tyEnv (G.TyNamed receiverType tyVars)
            abstracted <- pure $ TL.ExpAbs (TL.VarName $ G.unVarName receiverName) translatedReceiverType abstracted
            translatedReceiverCoercionArgs <- translateCoercionArguments tyEnv receiverTypeArgs
            abstracted <- pure $ TL.ExpAbs (TL.VarName receiverCoercionArgs) translatedReceiverCoercionArgs abstracted
            pure $ translateTypeAbstractionExpressions receiverTypeArgs abstracted
        Nothing -> pure abstracted
    pure abstracted

translateFunctionArgumentsForExp :: TyEnv -> [(G.VarName, G.Type)] -> TL.Exp -> T TL.Exp
translateFunctionArgumentsForExp _ [] innerExpression = pure innerExpression
translateFunctionArgumentsForExp tyEnv ((varName, goType):xs) innerExpression = do
    translatedType <- translateType tyEnv goType
    translateFunctionArgumentsForExp tyEnv xs (TL.ExpAbs (translateVarName varName) translatedType innerExpression)

translateFormalsForExp :: TyEnv -> [(G.TyVarName, Maybe G.Type)] -> TL.Exp -> T TL.Exp
translateFormalsForExp _ [] innerExpression = pure innerExpression
translateFormalsForExp tyEnv (x:xs) innerExpression = do
    typeVariableName <- pure $ G.unTyVarName (fst x)
    translateFormalsForExp tyEnv xs (TL.ExpTyAbs (TL.TyVarName typeVariableName) innerExpression)

meSpecArgs :: G.MeSpec -> [TL.Exp]
meSpecArgs methodSpec =
    let args = G.msig_args $ G.ms_sig methodSpec
        argNames = map fst args
    in  map (\x -> TL.ExpVar (translateVarName x)) argNames

methods :: TyEnv -> G.Type -> T [G.MeSpec]
methods tyEnv ty = withCtx ("computing methods for " ++ prettyS ty) $ do
    classified <- classifyTy ty
    case classified of
        TyKindTyVar a -> do
            sigma <- getBound tyEnv a
            methods tyEnv sigma
        TyKindBuiltin _ ->
            pure []
        TyKindStruct tyName _ -> do
            decls <- allMethodsForStructOrBuiltin tyName
            pure $ map (\x -> me_spec x) decls
        TyKindIface t args -> do
            iface <- lookupIface t
            subst <- inst (if_formals iface) args
            pure $ G.applyTySubst subst (if_methods iface)

--methodsStructOrBuiltin :: TyEnv -> G.Type -> T (Map.Map G.MeName (G.MeSpec, TL.Exp))
--methodsStructOrBuiltin tenv tau = do
--  k <- classifyTy tau
--  case k of
--    TyKindTyVar _ ->
--      failT ("Type " ++ prettyS tau ++ " is not a struct type")
--    TyKindIface _ _ ->
--      failT ("Type " ++ prettyS tau ++ " is not a struct type")
--    TyKindBuiltin t -> getMethods (tyBuiltinToTyName t) []
--    TyKindStruct t args -> getMethods t args
--  where
--    getMethods t args = do
--      ms <- allMethodsForStructOrBuiltin t
--      l <- flip mapMaybeM ms $ \m -> do
--             mSubst <- tryInst tenv (me_formals m) args
--             case mSubst of
--               Left err -> do
--                 trace
--                   ("Cannot instantiate declaration of " <> prettyT (me_spec m) <> " for " <>
--                    prettyT t <> " for arguments " <> prettyT args <> ": " <> T.pack err)
--                 pure Nothing
--               Right (subst, e) ->
--                 let spec = G.applyTySubst subst (me_spec m)
--                 in pure $ Just (G.ms_name spec, (spec, e))
--      pure (Map.fromList l)

-- taken from existing type directed translation
inst :: G.TyFormals -> [G.Type] -> T G.TySubst
inst (G.TyFormals formals) types = do
    when (length formals /= length types) $ failT ("Cannot instantiate " ++ prettyS formals ++ " with " ++ prettyS types ++ ": mismatch in number of arguments")
    pure $ Map.fromList (zipWith (\(a, _) replacement -> (a, replacement)) formals types)

--tryInst :: TyEnv -> G.TyFormals -> [G.Type] -> T (Either String (G.TySubst, TL.Exp))
--tryInst tyEnv (G.TyFormals formals) sigmas
--    | length formals /= length sigmas = pure (Left "arity mismatch")
--    | otherwise = do
--        let subst = Map.fromList (zipWith (\(a, _) sigma -> (a, sigma)) formals sigmas)
--            taus = map (maybeType . snd) formals
--        
--        eisM <-
--            catchT
--                (flip mapM (zip sigmas taus) $ \(sigma, tau) ->
--                 dictCons tyEnv sigma (G.applyTySubst subst tau))
--        case eisM of
--          Left e -> pure (Left ("bound mismatch: " ++ e))
--          Right eis'' -> do
--            eis <- mapM (translateType tyEnv) sigmas
--            eis' <- mapM (transTypeStar tyEnv) sigmas
--            let triples = map (\(e, e', e'') -> TL.mkTriple e e' e'') (zip3 eis eis' eis'')
--            pure (Right (subst, TL.mkTuple triples))

isSubtype :: TyEnv -> G.Type -> G.Type -> T Bool
isSubtype tyEnv supertype possibleSubtype = do
    classifiedSupertype <- classifyTy supertype
    classifiedSubtype <- classifyTy possibleSubtype
    case (classifiedSupertype, classifiedSubtype) of
        (TyKindTyVar _, TyKindTyVar _) -> pure $ possibleSubtype == supertype
        (TyKindStruct _ _, TyKindStruct _ _) -> pure $ possibleSubtype == supertype
        (TyKindBuiltin _, TyKindBuiltin _) -> pure $ possibleSubtype == supertype
        (TyKindIface _ _, _) -> do
            methodsSuper <- methods tyEnv supertype
            methodsSub <- methods tyEnv possibleSubtype
            trace $ T.pack $ show methodsSuper
            trace $ T.pack $ show methodsSub
            pure $ (Set.fromList $ methodsSuper) `Set.isSubsetOf` (Set.fromList $ methodsSub)
        _ -> pure False

generateCoercion :: TyEnv -> (G.Type, TL.Exp) -> G.Type -> T TL.Exp
generateCoercion tyEnv (originalType, originalExp) targetType = do
    (_, coercionAbs) <- generateCoercionAbs tyEnv originalType targetType
    pure $ TL.ExpApp coercionAbs originalExp

generateCoercionAbs :: TyEnv -> G.Type -> G.Type -> T (TL.Ty, TL.Exp)
generateCoercionAbs tyEnv originalType targetType = if originalType == targetType
    then do
        originalVarName <- pure $ TL.VarName "original"
        originalExp <- pure $ TL.ExpVar originalVarName
        translatedOrigType <- translateType tyEnv originalType
        translatedTargetType <- translateType tyEnv targetType
        coercionType <- pure $ TL.TyArrow translatedOrigType translatedTargetType
        pure $ (coercionType, TL.ExpAbs originalVarName translatedOrigType originalExp)
    else generateCoercionAbs' tyEnv originalType targetType
generateCoercionAbs' :: TyEnv -> G.Type -> G.Type -> T (TL.Ty, TL.Exp)
generateCoercionAbs' tyEnv (G.TyVar var) targetType = do
    ty <- lookupTyVar var tyEnv
    generateCoercionAbs' tyEnv ty targetType
generateCoercionAbs' tyEnv originalType (G.TyVar targetTyVar) = do
    ty <- lookupTyVar targetTyVar tyEnv
    generateCoercionAbs' tyEnv originalType ty
generateCoercionAbs' tyEnv originalType targetType = do
    originalVarName <- pure $ TL.VarName "original"
    originalExp <- pure $ TL.ExpVar originalVarName
    translatedOrigType <- translateType tyEnv originalType
    translatedTargetType <- translateType tyEnv targetType
    coercionType <- pure $ TL.TyArrow translatedOrigType translatedTargetType
    -- todo need coercion
    --targetIsSupertype <- isSubtype tyEnv targetType originalType
    --when (not targetIsSupertype) (failT $ "Coercion from " ++ (prettyS originalType) ++ " to " ++ (prettyS targetType) ++ " not possible (not a subtype)")
    classifiedTargetType <- classifyTy targetType
    case classifiedTargetType of
        TyKindIface ifaceName typeArgs -> do
            iface <- lookupIface ifaceName
            translatedTypeArgs <- mapM (translateType tyEnv) typeArgs
            methodSpecs <- pure $ if_methods iface
            coercions <- mapM (\(G.MeSpec meName _signature) -> do
                    emptyVarEnv <- mkVarEnv []
                    (_, coerced) <- methodCallOnType emptyVarEnv tyEnv meName originalExp Nothing originalType Nothing
                    pure coerced
                ) methodSpecs
            constr <- pure $ TL.ExpConstr (TL.ConstrName $ interfacePrefix <> (G.unTyName ifaceName)) translatedTypeArgs coercions
            pure $ (coercionType, TL.ExpAbs originalVarName translatedOrigType constr)
        _ -> failT ("Can only coerce to an interface, not to " ++ (prettyS targetType))

translateMethodBody :: VarEnv -> TyEnv -> G.MeBody -> T TL.Exp
translateMethodBody varEnv tyEnv methodBody =
    translateBindings varEnv tyEnv (G.mb_bindings methodBody) (G.mb_return methodBody)

translateVarName :: G.VarName -> TL.VarName
translateVarName (G.VarName name) = TL.VarName name

-- Maybe I'll find a better function name in the future
translateBindings :: VarEnv -> TyEnv -> [(G.VarName, Maybe G.Type, G.Exp)] -> Maybe G.Exp -> T TL.Exp
translateBindings varEnv tyEnv [] mainExp = translateMethodBodyReturn varEnv tyEnv mainExp
translateBindings varEnv tyEnv ((name, ty, exp):otherBindings) mainExp = withCtx ("translation of binding " ++ (prettyS name)) $ do
    translatedName <- pure $ translateVarName name
    (expressionType, translatedExpression) <- withCtx "translation of expression to bind" $ translateExpression varEnv tyEnv exp
    bindingType <- case ty of
        --Just x -> case x of
        --    G.TyVar tyVarName -> lookupTyVar tyVarName tyEnv
        --    G.TyNamed _ _ -> pure x
        Just x -> pure x
        Nothing -> pure expressionType
    coercedExpression <- if bindingType /= expressionType
        then withCtx "coercion to binding type" $ generateCoercion tyEnv (expressionType, translatedExpression) bindingType
        else pure translatedExpression
    translatedType <- translateType tyEnv bindingType
    updatedVarEnv <- extendVarEnv varEnv [(name, bindingType)]
    innerExpression <- translateBindings updatedVarEnv tyEnv otherBindings mainExp
    pure $ TL.ExpApp (TL.ExpAbs translatedName translatedType innerExpression) coercedExpression

translateMethodBodyReturn :: VarEnv -> TyEnv -> Maybe G.Exp -> T TL.Exp
translateMethodBodyReturn _ _ (Nothing) = pure $ TL.ExpVoid
translateMethodBodyReturn varEnv tyEnv (Just mainExp) = do
    res <- translateExpression varEnv tyEnv mainExp
    pure $ snd res

extractExpectedReceiverType :: MeDecl -> G.Type
extractExpectedReceiverType (MeDecl _ tyName formals _ _) = G.TyNamed tyName (map (\x -> maybeType (snd x)) $ G.unTyFormals formals)

coerceArguments :: TyEnv -> [(G.Type, TL.Exp)] -> [G.Type] -> T [(G.Type, TL.Exp)]
coerceArguments tyEnv sources targets = do
    combined <- pure $ zip sources targets
    coercedExpressionsAndTypes <- mapM (\(source, targetType) -> coerceArgument tyEnv source targetType) combined
    pure $ coercedExpressionsAndTypes

coerceArgument :: TyEnv -> (G.Type, TL.Exp) -> G.Type -> T (G.Type, TL.Exp)
coerceArgument tyEnv source targetType = do
    classifiedSource <- classifyTy (fst source)
    classifiedTarget <- classifyTy targetType
    case (classifiedTarget, classifiedSource) of
        (TyKindStruct targetName _constraints, TyKindStruct sourceName _tyArgs) -> do
            sameStruct <- pure $ targetName == sourceName
            when (not sameStruct) $ failT $ "Cannot supply " ++ prettyS sourceName ++ " when " ++ prettyS sourceName ++ " is expected"
            pure source
        (TyKindTyVar _, _) -> pure source -- If this dosn't work, the translation should already fail on the coercion arguments
        (TyKindIface _ _, TyKindTyVar tyVarName) -> do
            resolved <- lookupTyVar tyVarName tyEnv
            tyName <- case resolved of
                G.TyNamed name _ -> pure name
                _ -> failT ("Type variable " ++ (prettyS tyVarName) ++ " did not resolve to a named type")
            coercionAbs <- pure $ getCoercionAbs tyVarName tyName
            substitudedSource <- pure $ (resolved, (TL.ExpApp coercionAbs (snd source)))
            coercedExp <- generateCoercion tyEnv substitudedSource targetType
            pure (targetType, coercedExp)
        _ -> do
            coercedExp <- generateCoercion tyEnv source targetType
            pure (targetType, coercedExp)

methodCall :: VarEnv -> TyEnv -> TL.Exp -> Maybe (TL.Exp, G.Type, [G.Type], G.Type) -> Maybe [G.Exp] -> [G.Type] -> Maybe [G.Type] -> [G.Type] -> [G.Type] -> T TL.Exp
methodCall varEnv tyEnv methodVar receiver args expectedArgTypes methodTypeArgs receiverConstraints methodConstraints = withCtx "methodCall" $ do
    receiverApplied <- case receiver of
                        Just (translatedReceiverExpression, receiverType, receiverTypeArgs, expectedReceiverType) -> withCtx "receiverArgs" $ do
                            -- apply type arguments from receiver
                            translatedReceiverTypeArgs <- mapM (translateType tyEnv) receiverTypeArgs
                            typesApplied <- pure $ generateTypeApplication methodVar translatedReceiverTypeArgs
                            -- apply receiver coercion parameters
                            generatedRecvCoercions <- mapM (\(originalType, targetType) -> generateCoercionAbs tyEnv originalType targetType) (zip receiverTypeArgs receiverConstraints)
                            (recvCoercionTypes, generatedRecvCoercions) <- pure $ unzip generatedRecvCoercions
                            receiverCoercions <- pure $ TL.ExpConstr (tupleName $ length receiverTypeArgs) recvCoercionTypes generatedRecvCoercions
                            recvCoercionsApplied <- pure $ TL.ExpApp typesApplied receiverCoercions
                            -- apply receiver
                            (_, coercedReceiver) <- coerceArgument tyEnv (receiverType, translatedReceiverExpression) expectedReceiverType
                            pure $ TL.ExpApp recvCoercionsApplied coercedReceiver
                        Nothing -> pure $ methodVar
    methodCoercionsApplied <- case methodTypeArgs of
        Just methodTypeArgs -> withCtx "methodCoercionArgs" $ do
            translatedMethodTypeArgs <- mapM (translateType tyEnv) methodTypeArgs
            methodTypesApplied <- pure $ generateTypeApplication receiverApplied translatedMethodTypeArgs
            generatedCoercions <- mapM (\(originalType, targetType) -> generateCoercionAbs tyEnv originalType targetType) (zip methodTypeArgs methodConstraints)
            (coercionTypes, generatedCoercions) <- pure $ unzip generatedCoercions
            methodCoercions <- pure $ TL.ExpConstr (tupleName $ length generatedCoercions) coercionTypes generatedCoercions
            pure $ TL.ExpApp methodTypesApplied methodCoercions
        Nothing -> pure receiverApplied
    argsApplied <- case args of
        Just args -> withCtx "funArgs" $ do
            translatedArgs <- mapM (translateExpression varEnv tyEnv) args
            translatedArgs <- coerceArguments tyEnv translatedArgs expectedArgTypes
            argTypes <- mapM (translateType tyEnv) (map fst translatedArgs)
            pure $ TL.ExpApp methodCoercionsApplied (TL.ExpConstr (tupleName $ length translatedArgs) argTypes (map snd translatedArgs))
        Nothing -> pure methodCoercionsApplied
    pure $ argsApplied

methodCallOnType :: VarEnv -> TyEnv -> G.MeName -> TL.Exp -> Maybe [G.Exp] -> G.Type -> Maybe [G.Type] -> T (G.Type, TL.Exp)
methodCallOnType varEnv tyEnv meName translatedReceiverExpression args receiverType methodTypeArgs = withCtx ("methodCallOnType for " ++ (T.unpack $ G.unMeName meName)) $ do
    classified <- classifyTy receiverType
    case classified of
        TyKindStruct typeName typeArgs -> do
            methodDecls <- allMethodsForStructOrBuiltin typeName
            maybeDecl <- pure $ List.find (\x -> (G.ms_name $ me_spec x) == meName) methodDecls
            decl <- case maybeDecl of
                Just x -> pure x
                Nothing -> failT ("Method declaration for struct not found: " ++ (prettyS meName))
            spec <- pure $ me_spec decl
            resultType <- pure $ G.msig_res $ G.ms_sig spec
            expectedArgTypes <- pure $ map snd $ G.msig_args $ G.ms_sig spec
            expectedArgTypes <- case methodTypeArgs of
                Just meTyArgs -> do
                    subst <- inst (G.msig_tyArgs $ G.ms_sig spec) meTyArgs
                    pure $ G.applyTySubst subst expectedArgTypes
                Nothing -> pure expectedArgTypes
            methodVar <- pure $ TL.ExpVar $ TL.VarName $ (G.unMeName meName) <> "_" <> (G.unTyName typeName)
            substRecv <- inst (me_formals decl) typeArgs
            receiverConstraints <- pure $ map (\x -> maybeType (snd x)) (G.unTyFormals $ me_formals decl)
            receiverConstraints <- pure $ G.applyTySubst substRecv receiverConstraints
            expectedReceiverType <- pure $ extractExpectedReceiverType decl
            expectedReceiverType <- pure $ G.applyTySubst substRecv expectedReceiverType
            constraints <- pure $ map (\x -> maybeType (snd x)) (G.unTyFormals $ G.msig_tyArgs $ G.ms_sig spec)
            constraints <- case methodTypeArgs of
                Just meTyArgs -> do
                    subst <- inst (G.msig_tyArgs $ G.ms_sig spec) meTyArgs
                    pure $ G.applyTySubst subst constraints
                Nothing -> pure constraints
            argsApplied <- methodCall varEnv tyEnv methodVar (Just (translatedReceiverExpression, receiverType, typeArgs, expectedReceiverType)) args expectedArgTypes methodTypeArgs receiverConstraints constraints
            pure $ (resultType, argsApplied)
        TyKindIface typeName _ -> do
            iface <- lookupIface typeName
            formals <- pure $ if_formals iface
            translatedFormals <- pure $ translateFormals formals
            methodSpecs <- pure $ if_methods iface
            methodSpecs <- case methodTypeArgs of -- todo mabye only on spec?
                Just meTyArgs -> do
                    substs <- mapM ((flip inst) meTyArgs) (map (\x -> G.msig_tyArgs $ G.ms_sig x) methodSpecs)
                    pure $ map (\(subst, spec) -> G.applyTySubst subst spec) (zip substs methodSpecs)
                Nothing -> pure methodSpecs
            maybeSpec <- pure $ List.find (\x -> (G.ms_name x) == meName) methodSpecs
            spec <- case maybeSpec of
                Just x -> pure x
                Nothing -> failT ("Method for interface not found: " ++ (show meName))
            resultType <- pure $ G.msig_res $ G.ms_sig spec
            expectedArgTypes <- pure $ map snd $ G.msig_args $ G.ms_sig spec
            --expectedArgTypes <- case methodTypeArgs of
            --    Just meTyArgs -> do
            --        subst <- inst (G.msig_tyArgs $ G.ms_sig spec) meTyArgs
            --        pure $ G.applyTySubst subst expectedArgTypes
            --    Nothing -> pure expectedArgTypes
            translatedMethodSpecs <- mapM (translateMethodSpec tyEnv Nothing) methodSpecs
            ifaceMethodNames <- pure $ map (\(G.MeSpec name _) -> name) methodSpecs
            ifaceTypesWithName <- pure $ zip ifaceMethodNames translatedMethodSpecs
            patterns <- pure $ map (generateSelectPattern2 $ meName) ifaceTypesWithName
            methodVar <- pure $ TL.ExpVar selectVarName
            receiverConstraints <- pure $ [] -- these contraints are not of any use
            constraints <- pure $ map (\x -> maybeType (snd x)) (G.unTyFormals $ G.msig_tyArgs $ G.ms_sig spec)
            --constraints <- case methodTypeArgs of
            --    Just meTyArgs -> do
            --        subst <- inst (G.msig_tyArgs $ G.ms_sig spec) meTyArgs
            --        pure $ G.applyTySubst subst constraints
            --    Nothing -> pure constraints
            argsApplied <- methodCall varEnv tyEnv methodVar Nothing args expectedArgTypes methodTypeArgs receiverConstraints constraints
            outerCase <- pure $ TL.ExpCase translatedReceiverExpression [TL.PatClause (TL.PatConstr (TL.ConstrName $ interfacePrefix <> (G.unTyName typeName)) translatedFormals patterns) argsApplied]
            pure $ (resultType, outerCase)
        TyKindTyVar t -> do
            resolved <- lookupTyVar t tyEnv
            methodCallOnType varEnv tyEnv meName translatedReceiverExpression args resolved methodTypeArgs
        _ -> failT ("Cannot call method on " ++ (prettyS receiverType))

methodCallFun :: VarEnv -> TyEnv -> G.MeName -> [G.Exp] -> [G.Type] -> T (G.Type, TL.Exp)
methodCallFun varEnv tyEnv meName args methodTypeArgs = do
    signature <- lookupFun meName
    expectedArgTypes <- pure $ map snd (G.msig_args signature)
    subst <- inst (G.msig_tyArgs signature) methodTypeArgs
    expectedArgTypes <- pure $ G.applyTySubst subst expectedArgTypes
    methodVar <- pure $ TL.ExpVar $ TL.VarName $ G.unMeName meName
    constraints <- pure $ map (\x -> maybeType (snd x)) $ G.unTyFormals $ G.msig_tyArgs signature
    translatedExp <- methodCall varEnv tyEnv methodVar Nothing (Just args) expectedArgTypes (Just methodTypeArgs) [] constraints
    pure (G.msig_res signature, translatedExp)

typeOfField :: Struct -> G.FieldName -> G.Type
typeOfField struct fieldName = case List.find (\x -> fieldName == (fst x)) (st_fields struct) of
    Just (_, t) -> t
    Nothing -> G.tyVoid -- Should not happen...?

substituteTypeVariables :: [(G.TyVarName, G.Type)] -> G.Type -> G.Type
substituteTypeVariables substitutions (G.TyVar var) =
    let maybeSubst = List.find (\(tyVarName, _) -> tyVarName == var) substitutions
    in  case maybeSubst of
            Just (_, ty) -> ty
            Nothing -> (G.TyVar var)
substituteTypeVariables substitutions (G.TyNamed name typeArgs) = (G.TyNamed name (map (substituteTypeVariables substitutions) typeArgs))

selectVarName :: TL.VarName
selectVarName = TL.VarName $ T.pack "latestSelection"
generateSelectPattern :: G.FieldName -> (TL.Ty, (G.FieldName, G.Type)) -> TL.Pat
generateSelectPattern selectedFieldName (translatedType, (name, _)) =
    if name == selectedFieldName
        then TL.PatVar selectVarName translatedType
        else TL.PatWild translatedType
generateSelectPattern2 :: G.MeName -> (G.MeName, TL.Ty) -> TL.Pat
generateSelectPattern2 selectedName (currentName, currentType) = do
    if selectedName == currentName
        then TL.PatVar selectVarName currentType
        else TL.PatWild currentType

generateTypeApplication :: TL.Exp -> [TL.Ty] -> TL.Exp
generateTypeApplication left [] = left
generateTypeApplication tyAbs (arg:otherArgs) = generateTypeApplication (TL.ExpTyApp tyAbs arg) otherArgs

substituteTypeArgs :: G.Type -> [G.Type] -> T G.Type
substituteTypeArgs (G.TyNamed name _) newTypeArgs = pure $ G.TyNamed name newTypeArgs
substituteTypeArgs (G.TyVar name) _ = failT $ "Cannot substitute types for type variable " ++ prettyS name

getCoercionAbsName :: G.TyVarName -> G.TyName -> TL.VarName
getCoercionAbsName tyVarName namedTargetType = TL.VarName $ (G.unTyVarName tyVarName) <> "To" <> (G.unTyName namedTargetType)

getCoercionAbs :: G.TyVarName -> G.TyName -> TL.Exp
getCoercionAbs tyVarName namedTargetType = TL.ExpVar $ getCoercionAbsName tyVarName namedTargetType

translateExpressionAndSub :: VarEnv -> TyEnv -> G.Exp -> T (G.Type, TL.Exp) -- todo remove this and move logic to correct place
translateExpressionAndSub varEnv tyEnv exp = do
    (resultType, translatedExpression) <- translateExpression varEnv tyEnv exp
    case resultType of
        G.TyVar name -> withCtx ("insertion of coercion application for " ++ prettyS exp) $ do
            resolved <- lookupTyVar name tyEnv
            tyName <- case resolved of
                G.TyNamed name _ -> pure name
                _ -> failT ("Type variable " ++ (prettyS name) ++ " did not resolve to a named type")
            coercionAbs <- pure $ getCoercionAbs name tyName
            pure $ (resolved, (TL.ExpApp coercionAbs translatedExpression))
        _ -> pure (resultType, translatedExpression)

translateExpression :: VarEnv -> TyEnv -> G.Exp -> T (G.Type, TL.Exp)
translateExpression _ _ (G.BoolLit value) = pure $ (tyBuiltinToType TyBool, TL.ExpBool value)
translateExpression _ _ (G.IntLit value) = pure $ (tyBuiltinToType TyInt, TL.ExpInt value)
translateExpression _ _ (G.StrLit value) = pure $ (tyBuiltinToType TyString, TL.ExpStr value)
translateExpression varEnv _ (G.Var varName) = do
    goType <- lookupVar varName varEnv
    pure $ (goType, TL.ExpVar (translateVarName varName))
translateExpression varEnv tyEnv (G.StructLit structType fieldValues) = do
    assertTypeOk tyEnv structType
    actualType <- classifyTy structType
    case actualType of
        TyKindStruct typeName _ -> do
            goStruct <- lookupStruct typeName
            typeArgs <- case structType of
                G.TyNamed _ tys -> pure tys
                _ -> failT ("Struct literal requires a named type, not " ++ prettyS structType)
            translatedTypeArgs <- mapM (translateType tyEnv) typeArgs
            substitutedStructType <- substituteTypeArgs structType typeArgs
            fields <- pure $ st_fields goStruct
            when (length fieldValues /= length fields) $ failT ("Invalid number of arguments for construction of struct " ++ (prettyS substitutedStructType))
            translatedFieldValues <- mapM (translateExpressionAndSub varEnv tyEnv) fieldValues
            pure $ (substitutedStructType, TL.ExpConstr (TL.ConstrName $ structPrefix <> (G.unTyName typeName)) translatedTypeArgs (map snd translatedFieldValues))
        _ -> failT ("Invalid type for constructing a struct: " ++ (prettyS structType))
translateExpression varEnv tyEnv (G.Select exp fieldName) = do
    (expType, translatedExpression) <- withCtx "translation of expression to select on" $ translateExpression varEnv tyEnv exp
    classified <- classifyTy expType
    case classified of
        TyKindStruct name tyArgs -> do
            goStruct <- lookupStruct name
            substitutions <- pure $ zip (map fst (G.unTyFormals $ st_formals goStruct)) tyArgs
            fields <- pure $ map snd $ st_fields goStruct
            substitutedFields <- pure $ map (substituteTypeVariables substitutions) fields 
            translatedFieldTypes <- mapM (translateType tyEnv) substitutedFields
            patterns <- pure $ map (generateSelectPattern fieldName) (zip translatedFieldTypes (st_fields goStruct))
            translatedTyArgs <- mapM (translateType tyEnv) tyArgs
            pure $ (typeOfField goStruct fieldName, TL.ExpCase translatedExpression [TL.PatClause (TL.PatConstr (TL.ConstrName $ structPrefix <> (G.unTyName name)) translatedTyArgs patterns) (TL.ExpVar selectVarName)])
        _ -> failT ("Field selection requires a struct, but " ++ (show exp) ++ " is not a struct")
translateExpression varEnv tyEnv (G.BinOp binOp left right) = do
    (tl, translatedLeft) <- translateExpression varEnv tyEnv left
    (tr, translatedRight) <- translateExpression varEnv tyEnv right
    ty <- case Map.lookup binOp binOpTypes of
            Just m -> case Map.lookup (tl, tr) m of
                Just ty -> pure ty
                Nothing -> failT ("Binary operator " ++ (show binOp) ++ " does not support the types " ++ (show tl) ++ " and " ++ (show tr))
            Nothing -> failT ("Unknown binary operator: " ++ show binOp)
    pure $ (ty, TL.ExpBinOp translatedLeft binOp translatedRight)
translateExpression varEnv tyEnv (G.UnOp op expression) = do
    (resultType, translatedExpression) <- translateExpression varEnv tyEnv expression
    case op of
        Not -> when (resultType /= tyBuiltinToType TyBool) $ failT ("Invalid type for not: " ++ (prettyS resultType))
        Inv -> when (resultType /= tyBuiltinToType TyInt) $ failT ("Invalid type for -: " ++ (prettyS resultType))
    pure $ (resultType, TL.ExpUnOp op translatedExpression)
translateExpression varEnv tyEnv (G.MeCall (G.Var (G.VarName "fmt")) meName _ args) = do
    translatedArgsWithTypes <- mapM (translateExpressionAndSub varEnv tyEnv) args
    translatedArgs <- pure $ map snd translatedArgsWithTypes
    rawMeName <- pure $ (T.unpack $ G.unMeName meName)
    _ <- pure $ when (not $ elem rawMeName ["Printf", "Sprintf"]) (failT $ "Method is not part of fmt: " ++ (show meName))
    (formatStringType, formatString) <- pure $ head translatedArgsWithTypes
    when (formatStringType /= tyBuiltinToType TyString) $ failT ("Printf/Sprintf requires a string literal as the first argument, not " ++ (show formatStringType))
    formatStringLit <- pure $ case formatString of
        TL.ExpStr fmtStr -> fmtStr
        _ -> "(s)printf only supports string literals as format strings"
    valueArgs <- pure $ tail translatedArgs
    if rawMeName == "Printf"
        then pure $ (G.tyVoid, TL.ExpPrintf formatStringLit valueArgs)
        else pure $ (tyBuiltinToType TyString, TL.ExpSprintf formatStringLit valueArgs)
translateExpression varEnv tyEnv (G.MeCall exp meName typeArgs args) = do
    (receiverType, translatedReceiverExpression) <- translateExpressionAndSub varEnv tyEnv exp
    methodCallOnType varEnv tyEnv meName translatedReceiverExpression (Just args) receiverType (Just typeArgs)
translateExpression varEnv tyEnv (G.FunCall meName typeArgs args) = do
    methodCallFun varEnv tyEnv meName args typeArgs
translateExpression varEnv tyEnv (G.Cond a b c) = do
    (typeA, translatedA) <- translateExpression varEnv tyEnv a
    (typeB, translatedB) <- translateExpression varEnv tyEnv b
    (typeC, translatedC) <- translateExpression varEnv tyEnv c
    when (typeA /= tyBuiltinToType TyBool) $ failT ("Condition is not of type bool: " ++ (show a))
    bSubtypeOfC <- isSubtype tyEnv typeC typeB
    cSubtypeOfB <- isSubtype tyEnv typeB typeC
    if typeB == typeC
        then pure $ (typeB, TL.ExpCond translatedA translatedB translatedC)
        else if cSubtypeOfB
            then do
                coercedC <- generateCoercion tyEnv (typeC, translatedC) typeB
                pure $ (typeB, TL.ExpCond translatedA translatedB coercedC)
            else if bSubtypeOfC
                then do
                    coercedB <- generateCoercion tyEnv (typeB, translatedB) typeC
                    pure $ (typeC, TL.ExpCond translatedA coercedB translatedC)
                else failT ("Incompatible types in branches: " ++ (show b) ++ " and " ++ (show c))
translateExpression _ _ e = failT ("I don't know how to translate this expression yet: " ++ (show e))

generateMainDecls :: [G.MeBody] -> Int -> [G.Decl]
generateMainDecls [] _ = []
generateMainDecls (body:other) idx = 
    let suffix = if idx == 1
                then ""
                else show idx
        spec = G.MeSpec (G.MeName $ T.pack $ "main" ++ suffix) (G.MeSig (G.TyFormals []) [] G.tyVoid)
    in  (G.FunDecl spec body) : (generateMainDecls other (idx + 1))
pseudoMain :: Int -> TL.Exp
pseudoMain idx =
    let suffix = if idx == 1
                then ""
                else show idx
        emptyArgs = TL.ExpConstr (tupleName 0) [] []
        inner = TL.ExpApp (TL.ExpVar $ TL.VarName $ T.pack $ "main" ++ suffix) emptyArgs
    in  TL.ExpApp inner emptyArgs

translateProgram :: G.Program -> T TL.Prog
translateProgram (G.Program _ []) = failT "No main method found"
translateProgram program = do
    translatedDeclarationsNested <- mapM translateDeclaration ((G.p_decls program) ++ (generateMainDecls (G.p_mains program) 1))
    translatedDeclarations <- pure $ concat translatedDeclarationsNested
    translatedDeclarations <- pure $ stdLib ++ translatedDeclarations
    translatedMain <- pure $ pseudoMain $ length $ G.p_mains program
    trace $ T.pack $ prettyS (TL.Prog translatedDeclarations translatedMain)
    pure $ TL.Prog translatedDeclarations translatedMain

stdLib :: [TL.Decl]
stdLib = generateGenericTuples 20
