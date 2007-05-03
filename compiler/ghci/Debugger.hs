-----------------------------------------------------------------------------
--
-- GHCi Interactive debugging commands 
--
-- Pepe Iborra (supported by Google SoC) 2006
--
-- ToDo: lots of violation of layering here.  This module should
-- decide whether it is above the GHC API (import GHC and nothing
-- else) or below it.
-- 
-----------------------------------------------------------------------------

module Debugger (pprintClosureCommand) where

import Linker
import RtClosureInspect

import HscTypes
import IdInfo
--import Id
import Name
import Var hiding ( varName )
import VarSet
import VarEnv
import Name 
import UniqSupply
import Type
import TcType
import TcGadt
import GHC

import Outputable
import Pretty                    ( Mode(..), showDocWith )
import FastString
import SrcLoc

import Control.Exception
import Control.Monad
import Data.List
import Data.Maybe
import Data.IORef

import System.IO
import GHC.Exts

#include "HsVersions.h"

-------------------------------------
-- | The :print & friends commands
-------------------------------------
pprintClosureCommand :: Session -> Bool -> Bool -> String -> IO ()
pprintClosureCommand session bindThings force str = do 
  tythings <- (catMaybes . concat) `liftM`
                 mapM (\w -> GHC.parseName session w >>= 
                                mapM (GHC.lookupName session))
                      (words str)
  substs <- catMaybes `liftM` mapM (go session) 
                                   [id | AnId id <- tythings]
  mapM (applySubstToEnv session . skolemSubst) substs
  return ()
 where 

   -- Do the obtainTerm--bindSuspensions-computeSubstitution dance
   go :: Session -> Id -> IO (Maybe TvSubst)
   go cms id = do 
     mb_term <- obtainTerm cms force id 
     maybe (return Nothing) `flip` mb_term $ \term_ -> do
       term      <- tidyTermTyVars cms term_
       term'     <- if not bindThings then return term 
                     else bindSuspensions cms term                         
       showterm  <- printTerm cms term'
       unqual    <- GHC.getPrintUnqual cms
       let showSDocForUserOneLine unqual doc = 
               showDocWith LeftMode (doc (mkErrStyle unqual))
       (putStrLn . showSDocForUserOneLine unqual) (ppr id <+> char '=' <+> showterm)
     -- Before leaving, we compare the type obtained to see if it's more specific
     --  Then, we extract a substitution, 
     --  mapping the old tyvars to the reconstructed types.
       let Just reconstructed_type = termType term

     -- tcUnifyTys doesn't look through forall's, so we drop them from 
     -- the original type, instead of sigma-typing the reconstructed type
     -- In addition, we strip newtypes too, since the reconstructed type might
     --   not have recovered them all
           mb_subst = tcUnifyTys (const BindMe) 
                                 [repType' $ dropForAlls$ idType id] 
                                 [repType' $ reconstructed_type]  

       ASSERT2 (isJust mb_subst, ppr reconstructed_type $$ (ppr$ idType id)) 
        return mb_subst

   applySubstToEnv :: Session -> TvSubst -> IO ()
   applySubstToEnv cms subst | isEmptyTvSubst subst = return ()
   applySubstToEnv cms@(Session ref) subst = do
      hsc_env <- readIORef ref
      inScope <- GHC.getBindings cms
      let ictxt    = hsc_IC hsc_env
          ids      = ic_tmp_ids ictxt
          ids'     = map (\id -> id `setIdType` substTy subst (idType id)) ids
          subst_dom= varEnvKeys$ getTvSubstEnv subst
          subst_ran= varEnvElts$ getTvSubstEnv subst
          new_tvs  = [ tv | t <- subst_ran, let Just tv = getTyVar_maybe t]  
          ic_tyvars'= (`delVarSetListByKey` subst_dom) 
                    . (`extendVarSetList`   new_tvs)
                        $ ic_tyvars ictxt
          ictxt'   = ictxt { ic_tmp_ids = ids'
                           , ic_tyvars   = ic_tyvars' }
      writeIORef ref (hsc_env {hsc_IC = ictxt'})

          where delVarSetListByKey = foldl' delVarSetByKey

   tidyTermTyVars :: Session -> Term -> IO Term
   tidyTermTyVars (Session ref) t = do
     hsc_env <- readIORef ref
     let env_tvs      = ic_tyvars (hsc_IC hsc_env)
         my_tvs       = termTyVars t
         tvs          = env_tvs `minusVarSet` my_tvs
         tyvarOccName = nameOccName . tyVarName 
         tidyEnv      = (initTidyOccEnv (map tyvarOccName (varSetElems tvs))
                        , env_tvs `intersectVarSet` my_tvs)
     return$ mapTermType (snd . tidyOpenType tidyEnv) t

-- | Give names, and bind in the interactive environment, to all the suspensions
--   included (inductively) in a term
bindSuspensions :: Session -> Term -> IO Term
bindSuspensions cms@(Session ref) t = do 
      hsc_env <- readIORef ref
      inScope <- GHC.getBindings cms
      let ictxt        = hsc_IC hsc_env
          prefix       = "_t"
          alreadyUsedNames = map (occNameString . nameOccName . getName) inScope
          availNames   = map ((prefix++) . show) [1..] \\ alreadyUsedNames 
      availNames_var  <- newIORef availNames
      (t', stuff)     <- foldTerm (nameSuspensionsAndGetInfos availNames_var) t
      let (names, tys, hvals) = unzip3 stuff
      let tys' = map mk_skol_ty tys
      let ids = [ mkGlobalId VanillaGlobal name ty vanillaIdInfo
                | (name,ty) <- zip names tys']
          new_tyvars   = tyVarsOfTypes tys'
          new_ic       = extendInteractiveContext ictxt ids new_tyvars
      extendLinkEnv (zip names hvals)
      writeIORef ref (hsc_env {hsc_IC = new_ic })
      return t'
     where

--    Processing suspensions. Give names and recopilate info
        nameSuspensionsAndGetInfos :: IORef [String] -> TermFold (IO (Term, [(Name,Type,HValue)]))
        nameSuspensionsAndGetInfos freeNames = TermFold 
                      {
                        fSuspension = doSuspension freeNames
                      , fTerm = \ty dc v tt -> do 
                                    tt' <- sequence tt 
                                    let (terms,names) = unzip tt' 
                                    return (Term ty dc v terms, concat names)
                      , fPrim    = \ty n ->return (Prim ty n,[])
                      }
        doSuspension freeNames ct mb_ty hval Nothing = do
          name <- atomicModifyIORef freeNames (\x->(tail x, head x))
          n <- newGrimName cms name
          let ty' = fromMaybe (error "unexpected") mb_ty
          return (Suspension ct mb_ty hval (Just n), [(n,ty',hval)])


--  A custom Term printer to enable the use of Show instances
printTerm cms@(Session ref) = cPprTerm cPpr
 where
  cPpr = \p-> cPprShowable : cPprTermBase p 
  cPprShowable prec t@Term{ty=ty, dc=dc, val=val} = do
    let hasType = isEmptyVarSet (tyVarsOfType ty)  -- redundant
        isEvaled = isFullyEvaluatedTerm t
    if not isEvaled -- || not hasType
     then return Nothing
     else do 
        hsc_env <- readIORef ref
        dflags  <- GHC.getSessionDynFlags cms
        do
           (new_env, bname) <- bindToFreshName hsc_env ty "showme"
           writeIORef ref (new_env)
           let noop_log _ _ _ _ = return () 
               expr = "show " ++ showSDoc (ppr bname)
           GHC.setSessionDynFlags cms dflags{log_action=noop_log}
           mb_txt <- withExtendedLinkEnv [(bname, val)] 
                                         (GHC.compileExpr cms expr)
           let myprec = 9 -- TODO Infix constructors
           case mb_txt of 
             Just txt -> return . Just . text . unsafeCoerce# 
                           $ txt
             Nothing  -> return Nothing
         `finally` do 
           writeIORef ref hsc_env
           GHC.setSessionDynFlags cms dflags
     
  bindToFreshName hsc_env ty userName = do
    name <- newGrimName cms userName 
    let ictxt    = hsc_IC hsc_env
        tmp_ids  = ic_tmp_ids ictxt
        id       = mkGlobalId VanillaGlobal name ty vanillaIdInfo
        new_ic   = ictxt { ic_tmp_ids = id : tmp_ids }
    return (hsc_env {hsc_IC = new_ic }, name)

--    Create new uniques and give them sequentially numbered names
--    newGrimName :: Session -> String -> IO Name
newGrimName cms userName  = do
    us <- mkSplitUniqSupply 'b'
    let unique  = uniqFromSupply us
        occname = mkOccName varName userName
        name    = mkInternalName unique occname noSrcLoc
    return name

skolemSubst subst = subst `setTvSubstEnv` 
                      mapVarEnv mk_skol_ty (getTvSubstEnv subst)
mk_skol_ty ty | tyvars  <- varSetElems (tyVarsOfType ty)
              , tyvars' <- map (mkTyVarTy . mk_skol_tv) tyvars
              = substTyWith tyvars tyvars' ty
mk_skol_tv tv = mkTcTyVar (tyVarName tv) (tyVarKind tv) 
                      (SkolemTv RuntimeUnkSkol)
