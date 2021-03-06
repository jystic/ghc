
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module RegAlloc.Linear.FreeRegs (
    FR(..),
    maxSpillSlots
)

#include "HsVersions.h"

where

import Reg
import RegClass

import DynFlags
import Panic
import Platform

-- -----------------------------------------------------------------------------
-- The free register set
-- This needs to be *efficient*
-- Here's an inefficient 'executable specification' of the FreeRegs data type:
--
--	type FreeRegs = [RegNo]
--	noFreeRegs = 0
--	releaseReg n f = if n `elem` f then f else (n : f)
--	initFreeRegs = allocatableRegs
--	getFreeRegs cls f = filter ( (==cls) . regClass . RealReg ) f
--	allocateReg f r = filter (/= r) f

import qualified RegAlloc.Linear.PPC.FreeRegs    as PPC
import qualified RegAlloc.Linear.SPARC.FreeRegs  as SPARC
import qualified RegAlloc.Linear.X86.FreeRegs    as X86
import qualified RegAlloc.Linear.X86_64.FreeRegs as X86_64

import qualified PPC.Instr
import qualified SPARC.Instr
import qualified X86.Instr

class Show freeRegs => FR freeRegs where
    frAllocateReg :: Platform -> RealReg -> freeRegs -> freeRegs
    frGetFreeRegs :: Platform -> RegClass -> freeRegs -> [RealReg]
    frInitFreeRegs :: Platform -> freeRegs
    frReleaseReg :: Platform -> RealReg -> freeRegs -> freeRegs

instance FR X86.FreeRegs where
    frAllocateReg  = \_ -> X86.allocateReg
    frGetFreeRegs  = X86.getFreeRegs
    frInitFreeRegs = X86.initFreeRegs
    frReleaseReg   = \_ -> X86.releaseReg

instance FR X86_64.FreeRegs where
    frAllocateReg  = \_ -> X86_64.allocateReg
    frGetFreeRegs  = X86_64.getFreeRegs
    frInitFreeRegs = X86_64.initFreeRegs
    frReleaseReg   = \_ -> X86_64.releaseReg

instance FR PPC.FreeRegs where
    frAllocateReg  = \_ -> PPC.allocateReg
    frGetFreeRegs  = \_ -> PPC.getFreeRegs
    frInitFreeRegs = PPC.initFreeRegs
    frReleaseReg   = \_ -> PPC.releaseReg

instance FR SPARC.FreeRegs where
    frAllocateReg  = SPARC.allocateReg
    frGetFreeRegs  = \_ -> SPARC.getFreeRegs
    frInitFreeRegs = SPARC.initFreeRegs
    frReleaseReg   = SPARC.releaseReg

maxSpillSlots :: DynFlags -> Int
maxSpillSlots dflags
              = case platformArch (targetPlatform dflags) of
                ArchX86       -> X86.Instr.maxSpillSlots dflags
                ArchX86_64    -> X86.Instr.maxSpillSlots dflags
                ArchPPC       -> PPC.Instr.maxSpillSlots dflags
                ArchSPARC     -> SPARC.Instr.maxSpillSlots dflags
                ArchARM _ _ _ -> panic "maxSpillSlots ArchARM"
                ArchPPC_64    -> panic "maxSpillSlots ArchPPC_64"
                ArchUnknown   -> panic "maxSpillSlots ArchUnknown"

