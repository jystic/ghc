%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section{Tidying up Core}

\begin{code}
module CoreTidy (
	tidyCorePgm, tidyExpr, tidyCoreExpr,
	tidyBndr, tidyBndrs
    ) where

#include "HsVersions.h"

import CmdLineOpts	( DynFlags, DynFlag(..), opt_OmitInterfacePragmas )
import CoreSyn
import CoreUnfold	( noUnfolding, mkTopUnfolding, okToUnfoldInHiFile )
import CoreFVs		( ruleSomeFreeVars, exprSomeFreeVars )
import CoreLint		( showPass, endPass )
import VarEnv
import VarSet
import Var		( Id, Var )
import Id		( idType, idInfo, idName, isExportedId, 
			  idSpecialisation, idUnique, isDataConWrapId,
			  mkVanillaGlobal, isLocalId, 
			  hasNoBinding, mkUserLocal
			) 
import IdInfo		{- loads of stuff -}
import Name		( getOccName, nameOccName, globaliseName, setNameOcc, 
		  	  localiseName, isGlobalName
			)
import NameEnv		( filterNameEnv )
import OccName		( TidyOccEnv, initTidyOccEnv, tidyOccName )
import Type		( tidyTopType, tidyType, tidyTyVar )
import Module		( Module, moduleName )
import HscTypes		( PersistentCompilerState( pcs_PRS ), 
			  PersistentRenamerState( prsOrig ),
			  NameSupply( nsNames ), OrigNameCache,
			  TypeEnv, extendTypeEnvList, 
			  ModDetails(..), TyThing(..)
			)
import FiniteMap	( lookupFM, addToFM )
import Maybes		( maybeToBool, orElse )
import ErrUtils		( showPass )
import SrcLoc		( noSrcLoc )
import UniqFM		( mapUFM )
import List		( partition )
import Util		( mapAccumL )
import Outputable
\end{code}



%************************************************************************
%*				 					*
\subsection{What goes on}
%*				 					* 
%************************************************************************

[SLPJ: 19 Nov 00]

The plan is this.  

Step 1: Figure out external Ids
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
First we figure out which Ids are "external" Ids.  An
"external" Id is one that is visible from outside the compilation
unit.  These are
	a) the user exported ones
	b) ones mentioned in the unfoldings, workers, 
	   or rules of externally-visible ones 
This exercise takes a sweep of the bindings bottom to top.  Actually,
in Step 2 we're also going to need to know which Ids should be
exported with their unfoldings, so we produce not an IdSet but an
IdEnv Bool


Step 2: Tidy the program
~~~~~~~~~~~~~~~~~~~~~~~~
Next we traverse the bindings top to bottom.  For each top-level
binder

  - Make all external Ids have Global names and vice versa
    This is used by the code generator to decide whether
    to make the label externally visible

  - Give external ids a "tidy" occurrence name.  This means
    we can print them in interface files without confusing 
    "x" (unique 5) with "x" (unique 10).
  
  - Give external Ids the same Unique as they had before
    if the name is in the renamer's name cache
  
  - Give the Id its UTTERLY FINAL IdInfo; in ptic, 
	* Its IdDetails becomes VanillaGlobal, reflecting the fact that
	  from now on we regard it as a global, not local, Id

  	* its unfolding, if it should have one
	
	* its arity, computed from the number of visible lambdas

	* its CAF info, computed from what is free in its RHS

		
Finally, substitute these new top-level binders consistently
throughout, including in unfoldings.  We also tidy binders in
RHSs, so that they print nicely in interfaces.

\begin{code}
tidyCorePgm :: DynFlags -> Module
	    -> PersistentCompilerState
	    -> CgInfoEnv		-- Information from the back end,
					-- to be splatted into the IdInfo
	    -> ModDetails
	    -> IO (PersistentCompilerState, ModDetails)

tidyCorePgm dflags mod pcs cg_info_env
	    (ModDetails { md_types = env_tc, md_insts = insts_tc, 
			  md_binds = binds_in, md_rules = orphans_in })
  = do	{ showPass dflags "Tidy Core"

	; let ext_ids   = findExternalSet   binds_in orphans_in
	; let ext_rules = findExternalRules binds_in orphans_in ext_ids

	; let ((orig_env', occ_env, subst_env), tidy_binds) 
	       		= mapAccumL (tidyTopBind mod ext_ids cg_info_env) 
				    init_tidy_env binds_in

	; let tidy_rules = tidyIdRules (occ_env,subst_env) ext_rules

	; let prs' = prs { prsOrig = orig { nsNames = orig_env' } }
	      pcs' = pcs { pcs_PRS = prs' }

	; let final_ids  = [ id | bind <- tidy_binds
			   , id <- bindersOf bind
			   , isGlobalName (idName id)]

		-- Dfuns are local Ids that might have
		-- changed their unique during tidying
	; let lookup_dfun_id id = lookupVarEnv subst_env id `orElse` 
				  pprPanic "lookup_dfun_id" (ppr id)


	; let tidy_type_env = mkFinalTypeEnv env_tc final_ids
	      tidy_dfun_ids = map lookup_dfun_id insts_tc

	; let tidy_details = ModDetails { md_types = tidy_type_env,
					  md_rules = tidy_rules,
					  md_insts = tidy_dfun_ids,
					  md_binds = tidy_binds }

   	; endPass dflags "Tidy Core" Opt_D_dump_simpl tidy_binds

	; return (pcs', tidy_details)
	}
  where
	-- We also make sure to avoid any exported binders.  Consider
	--	f{-u1-} = 1	-- Local decl
	--	...
	--	f{-u2-} = 2	-- Exported decl
	--
	-- The second exported decl must 'get' the name 'f', so we
	-- have to put 'f' in the avoids list before we get to the first
	-- decl.  tidyTopId then does a no-op on exported binders.
    prs	 	     = pcs_PRS pcs
    orig	     = prsOrig prs
    orig_env 	     = nsNames orig

    init_tidy_env    = (orig_env, initTidyOccEnv avoids, emptyVarEnv)
    avoids	     = [getOccName bndr | bndr <- bindersOfBinds binds_in,
				          isGlobalName (idName bndr)]

tidyCoreExpr :: CoreExpr -> IO CoreExpr
tidyCoreExpr expr = return (tidyExpr emptyTidyEnv expr)
\end{code}


%************************************************************************
%*				 					*
\subsection{Write a new interface file}
%*				 					*
%************************************************************************

\begin{code}
mkFinalTypeEnv :: TypeEnv	-- From typechecker
	       -> [Id]		-- Final Ids
	       -> TypeEnv

mkFinalTypeEnv type_env final_ids
  = extendTypeEnvList (filterNameEnv keep_it type_env)
		      (map AnId final_ids)
  where
	-- The competed type environment is gotten from
	-- 	a) keeping the types and classes
	--	b) removing all Ids, 
	--	c) adding Ids with correct IdInfo, including unfoldings,
	--		gotten from the bindings
	-- From (c) we keep only those Ids with Global names;
	--	    the CoreTidy pass makes sure these are all and only
	--	    the externally-accessible ones
	-- This truncates the type environment to include only the 
	-- exported Ids and things needed from them, which saves space
	--
	-- However, we do keep things like constructors, which should not appear 
	-- in interface files, because they are needed by importing modules when
	-- using the compilation manager

	-- We keep "hasNoBinding" Ids, notably constructor workers, 
	-- because they won't appear in the bindings from which final_ids are derived!
    keep_it (AnId id) = hasNoBinding id	-- Remove all Ids except constructor workers
    keep_it other     = True		-- Keep all TyCons and Classes
\end{code}

\begin{code}
findExternalRules :: [CoreBind]
		  -> [IdCoreRule] -- Orphan rules
	          -> IdEnv a	  -- Ids that are exported, so we need their rules
	          -> [IdCoreRule]
  -- The complete rules are gotten by combining
  --	a) the orphan rules
  --	b) rules embedded in the top-level Ids
findExternalRules binds orphan_rules ext_ids
  | opt_OmitInterfacePragmas = []
  | otherwise
  = orphan_rules ++ local_rules
  where
    local_rules  = [ (id, rule)
 		   | id <- bindersOfBinds binds,
		     id `elemVarEnv` ext_ids,
		     rule <- rulesRules (idSpecialisation id),
		     not (isBuiltinRule rule)
			-- We can't print builtin rules in interface files
			-- Since they are built in, an importing module
			-- will have access to them anyway
		 ]
\end{code}

%************************************************************************
%*				 					*
\subsection{Step 1: finding externals}
%*				 					* 
%************************************************************************

\begin{code}
findExternalSet :: [CoreBind] -> [IdCoreRule]
		-> IdEnv Bool	-- In domain => external
				-- Range = True <=> show unfolding
	-- Step 1 from the notes above
findExternalSet binds orphan_rules
  = foldr find init_needed binds
  where
    orphan_rule_ids :: IdSet
    orphan_rule_ids = unionVarSets [ ruleSomeFreeVars isLocalId rule 
				   | (_, rule) <- orphan_rules]
    init_needed :: IdEnv Bool
    init_needed = mapUFM (\_ -> False) orphan_rule_ids
	-- The mapUFM is a bit cheesy.  It is a cheap way
	-- to turn the set of orphan_rule_ids, which we use to initialise
	-- the sweep, into a mapping saying 'don't expose unfolding'	
	-- (When we come to the binding site we may change our mind, of course.)

    find (NonRec id rhs) needed
	| need_id needed id = addExternal (id,rhs) needed
	| otherwise 	    = needed
    find (Rec prs) needed   = find_prs prs needed

	-- For a recursive group we have to look for a fixed point
    find_prs prs needed	
	| null needed_prs = needed
	| otherwise	  = find_prs other_prs new_needed
	where
	  (needed_prs, other_prs) = partition (need_pr needed) prs
	  new_needed = foldr addExternal needed needed_prs

	-- The 'needed' set contains the Ids that are needed by earlier
	-- interface file emissions.  If the Id isn't in this set, and isn't
	-- exported, there's no need to emit anything
    need_id needed_set id       = id `elemVarEnv` needed_set || isExportedId id 
    need_pr needed_set (id,rhs)	= need_id needed_set id

addExternal :: (Id,CoreExpr) -> IdEnv Bool -> IdEnv Bool
-- The Id is needed; extend the needed set
-- with it and its dependents (free vars etc)
addExternal (id,rhs) needed
  = extendVarEnv (foldVarSet add_occ needed new_needed_ids)
		 id show_unfold
  where
    add_occ id needed = extendVarEnv needed id False
	-- "False" because we don't know we need the Id's unfolding
	-- We'll override it later when we find the binding site

    new_needed_ids | opt_OmitInterfacePragmas = emptyVarSet
	           | otherwise		      = worker_ids	`unionVarSet`
						unfold_ids	`unionVarSet`
						spec_ids

    idinfo	   = idInfo id
    dont_inline	   = isNeverInlinePrag (inlinePragInfo idinfo)
    loop_breaker   = isLoopBreaker (occInfo idinfo)
    bottoming_fn   = isBottomingStrictness (strictnessInfo idinfo)
    spec_ids	   = rulesRhsFreeVars (specInfo idinfo)
    worker_info	   = workerInfo idinfo

	-- Stuff to do with the Id's unfolding
	-- The simplifier has put an up-to-date unfolding
	-- in the IdInfo, but the RHS will do just as well
    unfolding	 = unfoldingInfo idinfo
    rhs_is_small = not (neverUnfold unfolding)

	-- We leave the unfolding there even if there is a worker
	-- In GHCI the unfolding is used by importers
	-- When writing an interface file, we omit the unfolding 
	-- if there is a worker
    show_unfold = not bottoming_fn	 &&	-- Not necessary
		  not dont_inline	 &&
		  not loop_breaker	 &&
		  rhs_is_small		 &&	-- Small enough
		  okToUnfoldInHiFile rhs 	-- No casms etc

    unfold_ids | show_unfold = exprSomeFreeVars isLocalId rhs
	       | otherwise   = emptyVarSet

    worker_ids = case worker_info of
		   HasWorker work_id _ -> unitVarSet work_id
		   otherwise	       -> emptyVarSet
\end{code}


%************************************************************************
%*									*
\subsection{Step 2: top-level tidying}
%*									*
%************************************************************************


\begin{code}
type TopTidyEnv = (OrigNameCache, TidyOccEnv, VarEnv Var)

-- TopTidyEnv: when tidying we need to know
--   * orig_env: Any pre-ordained Names.  These may have arisen because the
--	  renamer read in an interface file mentioning M.$wf, say,
--	  and assigned it unique r77.  If, on this compilation, we've
--	  invented an Id whose name is $wf (but with a different unique)
--	  we want to rename it to have unique r77, so that we can do easy
--	  comparisons with stuff from the interface file
--
--   * occ_env: The TidyOccEnv, which tells us which local occurrences 
--     are 'used'
--
--   * subst_env: A Var->Var mapping that substitutes the new Var for the old
\end{code}


\begin{code}
tidyTopBind :: Module
	    -> IdEnv Bool	-- Domain = Ids that should be external
				-- True <=> their unfolding is external too
	    -> CgInfoEnv
	    -> TopTidyEnv -> CoreBind
	    -> (TopTidyEnv, CoreBind)

tidyTopBind mod ext_ids cg_info_env top_tidy_env (NonRec bndr rhs)
  = ((orig,occ,subst) , NonRec bndr' rhs')
  where
    ((orig,occ,subst), bndr')
	 = tidyTopBinder mod ext_ids cg_info_env rec_tidy_env rhs' top_tidy_env bndr
    rec_tidy_env = (occ,subst)
    rhs' = tidyExpr rec_tidy_env rhs

tidyTopBind mod ext_ids cg_info_env top_tidy_env (Rec prs)
  = (final_env, Rec prs')
  where
    (final_env@(_,occ,subst), prs') = mapAccumL do_one top_tidy_env prs
    rec_tidy_env = (occ,subst)

    do_one top_tidy_env (bndr,rhs) 
	= ((orig,occ,subst), (bndr',rhs'))
	where
	((orig,occ,subst), bndr')
	   = tidyTopBinder mod ext_ids cg_info_env 
		rec_tidy_env rhs' top_tidy_env bndr

        rhs' = tidyExpr rec_tidy_env rhs

tidyTopBinder :: Module -> IdEnv Bool
	      -> CgInfoEnv
	      -> TidyEnv -> CoreExpr
			-- The TidyEnv is used to tidy the IdInfo
			-- The expr is the already-tided RHS
			-- Both are knot-tied: don't look at them!
	      -> TopTidyEnv -> Id -> (TopTidyEnv, Id)
  -- NB: tidyTopBinder doesn't affect the unique supply

tidyTopBinder mod ext_ids cg_info_env tidy_env rhs
	      env@(orig_env2, occ_env2, subst_env2) id

  | isDataConWrapId id	-- Don't tidy constructor wrappers
  = (env, id)		-- The Id is stored in the TyCon, so it would be bad
			-- if anything changed

-- HACK ALERT: we *do* tidy record selectors.  Reason: they mention error
-- messages, which may be floated out:
--	x_field pt = case pt of
--			Rect x y -> y
--			Pol _ _  -> error "buggle wuggle"
-- The error message will be floated out so we'll get
--	lvl5 = error "buggle wuggle"
--	x_field pt = case pt of
--			Rect x y -> y
--			Pol _ _  -> lvl5
--
-- When this happens, it's vital that the Id exposed to importing modules
-- (by ghci) mentions lvl5 in its unfolding, not the un-tidied version.
-- 
-- What about the Id in the TyCon?  It probably shouldn't be in the TyCon at
-- all, but in any case it will have the error message inline so it won't matter.

  | otherwise
	-- This function is the heart of Step 2
	-- The second env is the one to use for the IdInfo
	-- It's necessary because when we are dealing with a recursive
	-- group, a variable late in the group might be mentioned
	-- in the IdInfo of one early in the group

	-- The rhs is already tidied
	
  = ((orig_env', occ_env', subst_env'), id')
  where
    (orig_env', occ_env', name') = tidyTopName mod orig_env2 occ_env2
					       is_external
					       (idName id)
    ty'	    = tidyTopType (idType id)
    cg_info = lookupCgInfo cg_info_env name'
    idinfo' = tidyIdInfo tidy_env is_external unfold_info cg_info id

    id'	       = mkVanillaGlobal name' ty' idinfo'
    subst_env' = extendVarEnv subst_env2 id id'

    maybe_external = lookupVarEnv ext_ids id
    is_external    = maybeToBool maybe_external

    -- Expose an unfolding if ext_ids tells us to
    show_unfold = maybe_external `orElse` False
    unfold_info | show_unfold = mkTopUnfolding rhs
		| otherwise   = noUnfolding


tidyIdInfo tidy_env is_external unfold_info cg_info id
  | opt_OmitInterfacePragmas || not is_external
	-- No IdInfo if the Id isn't external, or if we don't have -O
  = vanillaIdInfo 
	`setCgInfo` 	    cg_info
	`setStrictnessInfo` strictnessInfo core_idinfo
	-- Keep strictness; it's used by CorePrep

  | otherwise
  =  vanillaIdInfo 
	`setCgInfo` 	    cg_info
	`setCprInfo`	    cprInfo core_idinfo
	`setStrictnessInfo` strictnessInfo core_idinfo
	`setInlinePragInfo` inlinePragInfo core_idinfo
	`setUnfoldingInfo`  unfold_info
	`setWorkerInfo`	    tidyWorker tidy_env (workerInfo core_idinfo)
	-- NB: we throw away the Rules
	-- They have already been extracted by findExternalRules
  where
    core_idinfo = idInfo id


-- This is where we set names to local/global based on whether they really are 
-- externally visible (see comment at the top of this module).  If the name
-- was previously local, we have to give it a unique occurrence name if
-- we intend to globalise it.
tidyTopName mod orig_env occ_env external name
  | global && internal = (orig_env, occ_env, localiseName name)

  | local  && internal = (orig_env, occ_env', setNameOcc name occ')
	-- Even local, internal names must get a unique occurrence, because
	-- if we do -split-objs we globalise the name later, n the code generator

  | global && external = (orig_env, occ_env, name)
	-- Global names are assumed to have been allocated by the renamer,
	-- so they already have the "right" unique

  | local  && external = case lookupFM orig_env key of
			   Just orig -> (orig_env,			   occ_env', orig)
			   Nothing   -> (addToFM orig_env key global_name, occ_env', global_name)
	-- If we want to globalise a currently-local name, check
	-- whether we have already assigned a unique for it.
	-- If so, use it; if not, extend the table

  where
    (occ_env', occ') = tidyOccName occ_env (nameOccName name)
    key		     = (moduleName mod, occ')
    global_name      = globaliseName (setNameOcc name occ') mod
    global	     = isGlobalName name
    local	     = not global
    internal	     = not external

------------  Worker  --------------
tidyWorker tidy_env (HasWorker work_id wrap_arity) 
  = HasWorker (tidyVarOcc tidy_env work_id) wrap_arity
tidyWorker tidy_env other
  = NoWorker

------------  Rules  --------------
tidyIdRules :: TidyEnv -> [IdCoreRule] -> [IdCoreRule]
tidyIdRules env [] = []
tidyIdRules env ((fn,rule) : rules)
  = tidyRule env rule  		=: \ rule ->
    tidyIdRules env rules 	=: \ rules ->
     ((tidyVarOcc env fn, rule) : rules)

tidyRule :: TidyEnv -> CoreRule -> CoreRule
tidyRule env rule@(BuiltinRule _) = rule
tidyRule env (Rule name vars tpl_args rhs)
  = tidyBndrs env vars			=: \ (env', vars) ->
    map (tidyExpr env') tpl_args  	=: \ tpl_args ->
     (Rule name vars tpl_args (tidyExpr env' rhs))
\end{code}

%************************************************************************
%*									*
\subsection{Step 2: inner tidying
%*									*
%************************************************************************

\begin{code}
tidyBind :: TidyEnv
	 -> CoreBind
	 ->  (TidyEnv, CoreBind)

tidyBind env (NonRec bndr rhs)
  = tidyBndrWithRhs env (bndr,rhs) =: \ (env', bndr') ->
    (env', NonRec bndr' (tidyExpr env' rhs))

tidyBind env (Rec prs)
  = mapAccumL tidyBndrWithRhs env prs 	=: \ (env', bndrs') ->
    map (tidyExpr env') (map snd prs)	=: \ rhss' ->
    (env', Rec (zip bndrs' rhss'))


tidyExpr env (Var v)   	=  Var (tidyVarOcc env v)
tidyExpr env (Type ty) 	=  Type (tidyType env ty)
tidyExpr env (Lit lit) 	=  Lit lit
tidyExpr env (App f a) 	=  App (tidyExpr env f) (tidyExpr env a)
tidyExpr env (Note n e) =  Note (tidyNote env n) (tidyExpr env e)

tidyExpr env (Let b e) 
  = tidyBind env b 	=: \ (env', b') ->
    Let b' (tidyExpr env' e)

tidyExpr env (Case e b alts)
  = tidyBndr env b 	=: \ (env', b) ->
    Case (tidyExpr env e) b (map (tidyAlt env') alts)

tidyExpr env (Lam b e)
  = tidyBndr env b 	=: \ (env', b) ->
    Lam b (tidyExpr env' e)


tidyAlt env (con, vs, rhs)
  = tidyBndrs env vs 	=: \ (env', vs) ->
    (con, vs, tidyExpr env' rhs)

tidyNote env (Coerce t1 t2)  = Coerce (tidyType env t1) (tidyType env t2)
tidyNote env note            = note
\end{code}


%************************************************************************
%*									*
\subsection{Tidying up non-top-level binders}
%*									*
%************************************************************************

\begin{code}
tidyVarOcc (_, var_env) v = case lookupVarEnv var_env v of
				  Just v' -> v'
				  Nothing -> v

-- tidyBndr is used for lambda and case binders
tidyBndr :: TidyEnv -> Var -> (TidyEnv, Var)
tidyBndr env var
  | isTyVar var = tidyTyVar env var
  | otherwise   = tidyId env var

tidyBndrs :: TidyEnv -> [Var] -> (TidyEnv, [Var])
tidyBndrs env vars = mapAccumL tidyBndr env vars

-- tidyBndrWithRhs is used for let binders
tidyBndrWithRhs :: TidyEnv -> (Id, CoreExpr) -> (TidyEnv, Var)
tidyBndrWithRhs env (id,rhs) = tidyId env id

tidyId :: TidyEnv -> Id -> (TidyEnv, Id)
tidyId env@(tidy_env, var_env) id
  = 	-- Non-top-level variables
    let 
	-- Give the Id a fresh print-name, *and* rename its type
	-- The SrcLoc isn't important now, 
	-- though we could extract it from the Id
	-- 
	-- All local Ids now have the same IdInfo, which should save some
	-- space.
	(tidy_env', occ') = tidyOccName tidy_env (getOccName id)
        ty'          	  = tidyType (tidy_env,var_env) (idType id)
	id'          	  = mkUserLocal occ' (idUnique id) ty' noSrcLoc
	var_env'	  = extendVarEnv var_env id id'
    in
     ((tidy_env', var_env'), id')
\end{code}

\begin{code}
m =: k = m `seq` k m
\end{code}
