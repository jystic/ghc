%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
% Code generation for tail calls.

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module CgTailCall (
	cgTailCall, performTailCall,
	performReturn, performPrimReturn,
	returnUnboxedTuple, ccallReturnUnboxedTuple,
	pushUnboxedTuple,
	tailCallPrimOp,
        tailCallPrimCall,

	pushReturnAddress
    ) where

#include "HsVersions.h"

import CgMonad
import CgBindery
import CgInfoTbls
import CgCallConv
import CgStackery
import CgHeapery
import CgUtils
import CgTicky
import ClosureInfo
import OldCmm	
import OldCmmUtils
import CLabel
import Type
import Id
import StgSyn
import PrimOp
import DynFlags
import Outputable
import Util

import Control.Monad
import Data.Maybe

-----------------------------------------------------------------------------
-- Tail Calls

cgTailCall :: Id -> [StgArg] -> Code

-- Here's the code we generate for a tail call.  (NB there may be no
-- arguments, in which case this boils down to just entering a variable.)
-- 
--    *	Put args in the top locations of the stack.
--    *	Adjust the stack ptr
--    *	Make R1 point to the function closure if necessary.
--    *	Perform the call.
--
-- Things to be careful about:
--
--    *	Don't overwrite stack locations before you have finished with
-- 	them (remember you need the function and the as-yet-unmoved
-- 	arguments).
--    *	Preferably, generate no code to replace x by x on the stack (a
-- 	common situation in tail-recursion).
--    *	Adjust the stack high water mark appropriately.
-- 
-- Treat unboxed locals exactly like literals (above) except use the addr
-- mode for the local instead of (CLit lit) in the assignment.

cgTailCall fun args
  = do	{ fun_info <- getCgIdInfo fun

	; if isUnLiftedType (idType fun)
	  then 	-- Primitive return
		ASSERT( null args )
	    do	{ fun_amode <- idInfoToAmode fun_info
		; performPrimReturn (cgIdInfoArgRep fun_info) fun_amode } 

	  else -- Normal case, fun is boxed
	    do  { arg_amodes <- getArgAmodes args
		; performTailCall fun_info arg_amodes noStmts }
	}
		

-- -----------------------------------------------------------------------------
-- The guts of a tail-call

performTailCall 
	:: CgIdInfo		-- The function
	-> [(CgRep,CmmExpr)]	-- Args
	-> CmmStmts		-- Pending simultaneous assignments
				--  *** GUARANTEED to contain only stack assignments.
	-> Code

performTailCall fun_info arg_amodes pending_assts
  | Just join_sp <- maybeLetNoEscape fun_info
  = 	   -- A let-no-escape is slightly different, because we
	   -- arrange the stack arguments into pointers and non-pointers
	   -- to make the heap check easier.  The tail-call sequence
	   -- is very similar to returning an unboxed tuple, so we
	   -- share some code.
     do	{ dflags <- getDynFlags
        ; (final_sp, arg_assts, live) <- pushUnboxedTuple join_sp arg_amodes
	; emitSimultaneously (pending_assts `plusStmts` arg_assts)
	; let lbl = enterReturnPtLabel dflags (idUnique (cgIdInfoId fun_info))
	; doFinalJump final_sp True $ jumpToLbl lbl (Just live) }

  | otherwise
  = do 	{ fun_amode <- idInfoToAmode fun_info
	; dflags <- getDynFlags
	; let assignSt  = CmmAssign nodeReg fun_amode
              node_asst = oneStmt assignSt
              node_live = Just [node]
	      (opt_node_asst, opt_node_live)
                      | nodeMustPointToIt dflags lf_info = (node_asst, node_live)
                      | otherwise                 = (noStmts, Just [])
	; EndOfBlockInfo sp _ <- getEndOfBlockInfo

	; case (getCallMethod dflags fun_name fun_has_cafs lf_info (length arg_amodes)) of

	    -- Node must always point to things we enter
	    EnterIt -> do
		{ emitSimultaneously (node_asst `plusStmts` pending_assts) 
		; let target       = entryCode dflags (closureInfoPtr dflags (CmmReg nodeReg))
                      enterClosure = stmtC (CmmJump target node_live)
                      -- If this is a scrutinee
                      -- let's check if the closure is a constructor
                      -- so we can directly jump to the alternatives switch
                      -- statement.
                      jumpInstr = getEndOfBlockInfo >>=
                                  maybeSwitchOnCons dflags enterClosure
		; doFinalJump sp False jumpInstr }
    
	    -- A function, but we have zero arguments.  It is already in WHNF,
	    -- so we can just return it.  
	    -- As with any return, Node must point to it.
	    ReturnIt -> do
		{ emitSimultaneously (node_asst `plusStmts` pending_assts)
		; doFinalJump sp False $ emitReturnInstr node_live }
    
	    -- A real constructor.  Don't bother entering it, 
	    -- just do the right sort of return instead.
	    -- As with any return, Node must point to it.
	    ReturnCon _ -> do
		{ emitSimultaneously (node_asst `plusStmts` pending_assts)
		; doFinalJump sp False $ emitReturnInstr node_live }

	    JumpToIt lbl -> do
		{ emitSimultaneously (opt_node_asst `plusStmts` pending_assts)
		; doFinalJump sp False $ jumpToLbl lbl opt_node_live }
    
	    -- A slow function call via the RTS apply routines
	    -- Node must definitely point to the thing
	    SlowCall -> do 
		{  when (not (null arg_amodes)) $ do
		   { if (isKnownFun lf_info) 
			then tickyKnownCallTooFewArgs
			else tickyUnknownCall
		   ; tickySlowCallPat (map fst arg_amodes) 
		   }

		; let (apply_lbl, args, extra_args) 
			= constructSlowCall arg_amodes

		; directCall sp apply_lbl args extra_args node_live
			(node_asst `plusStmts` pending_assts)

		}
    
	    -- A direct function call (possibly with some left-over arguments)
	    DirectEntry lbl arity -> do
		{ if arity == length arg_amodes
			then tickyKnownCallExact
			else do tickyKnownCallExtraArgs
				tickySlowCallPat (map fst (drop arity arg_amodes))

 		; let
		     -- The args beyond the arity go straight on the stack
		     (arity_args, extra_args) = splitAt arity arg_amodes
     
		; directCall sp lbl arity_args extra_args opt_node_live
			(opt_node_asst `plusStmts` pending_assts)
	        }
	}
  where
    fun_id    = cgIdInfoId fun_info
    fun_name  = idName fun_id
    lf_info   = cgIdInfoLF fun_info
    fun_has_cafs = idCafInfo fun_id
    untag_node dflags = CmmAssign nodeReg (cmmUntag dflags (CmmReg nodeReg))
    -- Test if closure is a constructor
    maybeSwitchOnCons dflags enterClosure eob
              | EndOfBlockInfo _ (CaseAlts lbl _ _) <- eob,
                not (dopt Opt_SccProfilingOn dflags)
                -- we can't shortcut when profiling is on, because we have
                -- to enter a closure to mark it as "used" for LDV profiling
              = do { is_constr <- newLabelC
                   -- Is the pointer tagged?
                   -- Yes, jump to switch statement
                   ; stmtC (CmmCondBranch (cmmIsTagged dflags (CmmReg nodeReg)) 
                                is_constr)
                   -- No, enter the closure.
                   ; enterClosure
                   ; labelC is_constr
                   ; stmtC (CmmJump (entryCode dflags $
                               CmmLit (CmmLabel lbl)) (Just [node]))
                   }
{-
              -- This is a scrutinee for a case expression
              -- so let's see if we can directly inspect the closure
              | EndOfBlockInfo _ (CaseAlts lbl _ _ _) <- eob
              = do { no_cons <- newLabelC
                   -- Both the NCG and gcc optimize away the temp
                   ; z <- newTemp  wordRep
                   ; stmtC (CmmAssign z tag_expr)
                   ; let tag = CmmReg z
                   -- Is the closure a cons?
                   ; stmtC (CmmCondBranch (cond1 tag) no_cons)
                   ; stmtC (CmmCondBranch (cond2 tag) no_cons)
                   -- Yes, jump to switch statement
                   ; stmtC (CmmJump (CmmLit (CmmLabel lbl)))
                   ; labelC no_cons
                   -- No, enter the closure.
                   ; enterClosure
                   }
-}
              -- No case expression involved, enter the closure.
              | otherwise
              = do { stmtC $ untag_node dflags
                   ; enterClosure
                   }
        where
          --cond1 tag  = cmmULtWord tag lowCons
          -- More efficient than the above?
{-
          tag_expr   = cmmGetClosureType (CmmReg nodeReg)
          cond1 tag  = cmmEqWord tag (CmmLit (mkIntCLit 0))
          cond2 tag  = cmmUGtWord tag highCons
          lowCons    = CmmLit (mkIntCLit 1)
            -- CONSTR
          highCons   = CmmLit (mkIntCLit 8)
            -- CONSTR_NOCAF_STATIC (from ClosureType.h)
-}

directCall :: VirtualSpOffset -> CLabel -> [(CgRep, CmmExpr)]
           -> [(CgRep, CmmExpr)] -> Maybe [GlobalReg] -> CmmStmts
           -> Code
directCall sp lbl args extra_args live_node assts = do
  dflags <- getDynFlags
  let
	-- First chunk of args go in registers
	(reg_arg_amodes, stk_args) = assignCallRegs dflags args
     
	-- Any "extra" arguments are placed in frames on the
	-- stack after the other arguments.
	slow_stk_args = slowArgs dflags extra_args

	reg_assts = assignToRegs reg_arg_amodes
        live_args = map snd reg_arg_amodes
        live_regs = Just $ (fromMaybe [] live_node) ++ live_args
  --
  (final_sp, stk_assts) <- mkStkAmodes sp (stk_args ++ slow_stk_args)
  emitSimultaneously $ reg_assts `plusStmts` stk_assts `plusStmts` assts
  doFinalJump final_sp False $ jumpToLbl lbl live_regs

-- -----------------------------------------------------------------------------
-- The final clean-up before we do a jump at the end of a basic block.
-- This code is shared by tail-calls and returns.

doFinalJump :: VirtualSpOffset -> Bool -> Code -> Code 
doFinalJump final_sp is_let_no_escape jump_code
  = do	{ -- Adjust the high-water mark if necessary
	  adjustStackHW final_sp

	-- Push a return address if necessary (after the assignments
	-- above, in case we clobber a live stack location)
	--
	-- DONT push the return address when we're about to jump to a
	-- let-no-escape: the final tail call in the let-no-escape
	-- will do this.
	; eob <- getEndOfBlockInfo
	; whenC (not is_let_no_escape) (pushReturnAddress eob)

	    -- Final adjustment of Sp/Hp
	; adjustSpAndHp final_sp

	    -- and do the jump
	; jump_code }

-- ----------------------------------------------------------------------------
-- A general return (just a special case of doFinalJump, above)

performReturn :: Code	-- The code to execute to actually do the return
	      -> Code

performReturn finish_code
  = do  { EndOfBlockInfo args_sp _sequel <- getEndOfBlockInfo
	; doFinalJump args_sp False finish_code }

-- ----------------------------------------------------------------------------
-- Primitive Returns
-- Just load the return value into the right register, and return.

performPrimReturn :: CgRep -> CmmExpr -> Code

-- non-void return value
performPrimReturn rep amode | not (isVoidArg rep)
  = do { stmtC (CmmAssign ret_reg amode)
       ; performReturn $ emitReturnInstr live_regs }
  where
    -- careful here as 'dataReturnConvPrim' will panic if given a Void rep
    ret_reg@(CmmGlobal r) = dataReturnConvPrim rep
    live_regs = Just [r]

-- void return value
performPrimReturn _ _
  = performReturn $ emitReturnInstr (Just [])


-- ---------------------------------------------------------------------------
-- Unboxed tuple returns

-- These are a bit like a normal tail call, except that:
--
--   - The tail-call target is an info table on the stack
--
--   - We separate stack arguments into pointers and non-pointers,
--     to make it easier to leave things in a sane state for a heap check.
--     This is OK because we can never partially-apply an unboxed tuple,
--     unlike a function.  The same technique is used when calling
--     let-no-escape functions, because they also can't be partially
--     applied.

returnUnboxedTuple :: [(CgRep, CmmExpr)] -> Code
returnUnboxedTuple amodes
  = do 	{ (EndOfBlockInfo args_sp _sequel) <- getEndOfBlockInfo
	; tickyUnboxedTupleReturn (length amodes)
	; (final_sp, assts, live_regs) <- pushUnboxedTuple args_sp amodes
	; emitSimultaneously assts
	; doFinalJump final_sp False $ emitReturnInstr (Just live_regs) }

pushUnboxedTuple :: VirtualSpOffset		-- Sp at which to start pushing
		 -> [(CgRep, CmmExpr)]		-- amodes of the components
		 -> FCode (VirtualSpOffset,	-- final Sp
			   CmmStmts,		-- assignments (regs+stack)
                           [GlobalReg])         -- registers used (liveness)

pushUnboxedTuple sp [] 
  = return (sp, noStmts, [])
pushUnboxedTuple sp amodes
  = do	{ dflags <- getDynFlags
        ; let	(reg_arg_amodes, stk_arg_amodes) = assignReturnRegs dflags amodes
                live_regs = map snd reg_arg_amodes
	
		-- separate the rest of the args into pointers and non-pointers
		(ptr_args, nptr_args) = separateByPtrFollowness stk_arg_amodes
		reg_arg_assts = assignToRegs reg_arg_amodes
		
	    -- push ptrs, then nonptrs, on the stack
	; (ptr_sp,   ptr_assts)  <- mkStkAmodes sp ptr_args
	; (final_sp, nptr_assts) <- mkStkAmodes ptr_sp nptr_args

	; returnFC (final_sp,
	  	    reg_arg_assts `plusStmts` ptr_assts `plusStmts` nptr_assts,
                    live_regs) }
    
		  
-- -----------------------------------------------------------------------------
-- Returning unboxed tuples.  This is mainly to support _ccall_GC_, where
-- we want to do things in a slightly different order to normal:
-- 
-- 		- push return address
-- 		- adjust stack pointer
-- 		- r = call(args...)
-- 		- assign regs for unboxed tuple (usually just R1 = r)
-- 		- return to continuation
-- 
-- The return address (i.e. stack frame) must be on the stack before
-- doing the call in case the call ends up in the garbage collector.
-- 
-- Sadly, the information about the continuation is lost after we push it
-- (in order to avoid pushing it again), so we end up doing a needless
-- indirect jump (ToDo).

ccallReturnUnboxedTuple :: [(CgRep, CmmExpr)] -> Code -> Code
ccallReturnUnboxedTuple amodes before_jump
  = do 	{ eob@(EndOfBlockInfo args_sp _) <- getEndOfBlockInfo

	-- Push a return address if necessary
	; pushReturnAddress eob
	; setEndOfBlockInfo (EndOfBlockInfo args_sp OnStack)
	    (do	{ adjustSpAndHp args_sp
		; before_jump
  		; returnUnboxedTuple amodes })
    }

-- -----------------------------------------------------------------------------
-- Calling an out-of-line primop

tailCallPrimOp :: PrimOp -> [StgArg] -> Code
tailCallPrimOp op
 = tailCallPrim (mkRtsPrimOpLabel op)

tailCallPrimCall :: PrimCall -> [StgArg] -> Code
tailCallPrimCall primcall
 = tailCallPrim (mkPrimCallLabel primcall)

tailCallPrim :: CLabel -> [StgArg] -> Code
tailCallPrim lbl args
 = do { dflags <- getDynFlags
        -- We're going to perform a normal-looking tail call, 
		-- except that *all* the arguments will be in registers.
		-- Hence the ASSERT( null leftovers )
	; arg_amodes <- getArgAmodes args
	; let (arg_regs, leftovers) = assignPrimOpCallRegs dflags arg_amodes
              live_regs = Just $ map snd arg_regs
	      jump_to_primop = jumpToLbl lbl live_regs

	; ASSERT(null leftovers) -- no stack-resident args
 	  emitSimultaneously (assignToRegs arg_regs)

	; EndOfBlockInfo args_sp _ <- getEndOfBlockInfo
	; doFinalJump args_sp False jump_to_primop }

-- -----------------------------------------------------------------------------
-- Return Addresses

-- We always push the return address just before performing a tail call
-- or return.  The reason we leave it until then is because the stack
-- slot that the return address is to go into might contain something
-- useful.
-- 
-- If the end of block info is 'CaseAlts', then we're in the scrutinee of a
-- case expression and the return address is still to be pushed.
-- 
-- There are cases where it doesn't look necessary to push the return
-- address: for example, just before doing a return to a known
-- continuation.  However, the continuation will expect to find the
-- return address on the stack in case it needs to do a heap check.

pushReturnAddress :: EndOfBlockInfo -> Code

pushReturnAddress (EndOfBlockInfo args_sp (CaseAlts lbl _ _))
  = do	{ sp_rel <- getSpRelOffset args_sp
	; stmtC (CmmStore sp_rel (mkLblExpr lbl)) }

pushReturnAddress _ = nopC

-- -----------------------------------------------------------------------------
-- Misc.

-- Passes no argument to the destination procedure
jumpToLbl :: CLabel -> Maybe [GlobalReg] -> Code
jumpToLbl lbl live = stmtC $ CmmJump (CmmLit $ CmmLabel lbl) live

assignToRegs :: [(CmmExpr, GlobalReg)] -> CmmStmts
assignToRegs reg_args 
  = mkStmts [ CmmAssign (CmmGlobal reg_id) expr
	    | (expr, reg_id) <- reg_args ] 
\end{code}


%************************************************************************
%*									*
\subsection[CgStackery-adjust]{Adjusting the stack pointers}
%*									*
%************************************************************************

This function adjusts the stack and heap pointers just before a tail
call or return.  The stack pointer is adjusted to its final position
(i.e. to point to the last argument for a tail call, or the activation
record for a return).  The heap pointer may be moved backwards, in
cases where we overallocated at the beginning of the basic block (see
CgCase.lhs for discussion).

These functions {\em do not} deal with high-water-mark adjustment.
That's done by functions which allocate stack space.

\begin{code}
adjustSpAndHp :: VirtualSpOffset 	-- New offset for Arg stack ptr
	      -> Code
adjustSpAndHp newRealSp 
  = do	{ -- Adjust stack, if necessary.
	  -- NB: the conditional on the monad-carried realSp
	  --     is out of line (via codeOnly), to avoid a black hole
	; new_sp <- getSpRelOffset newRealSp
	; checkedAbsC (CmmAssign spReg new_sp)	-- Will generate no code in the case
	; setRealSp newRealSp			-- where realSp==newRealSp

	  -- Adjust heap.  The virtual heap pointer may be less than the real Hp
	  -- because the latter was advanced to deal with the worst-case branch
	  -- of the code, and we may be in a better-case branch.  In that case,
 	  -- move the real Hp *back* and retract some ticky allocation count.
	; hp_usg <- getHpUsage
	; let rHp = realHp hp_usg
	      vHp = virtHp hp_usg
	; new_hp <- getHpRelOffset vHp
	; checkedAbsC (CmmAssign hpReg new_hp)	-- Generates nothing when vHp==rHp
	; tickyAllocHeap (vHp - rHp)		-- ...ditto
	; setRealHp vHp
	}
\end{code}

