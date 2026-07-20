-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- Checkpoint 1 of ADR 0013/0014's compiler PERT plan: prove Lean4's own
-- compiler IR (Lean.Compiler.LCNF) is queryable from ordinary Lean4 code
-- for a real fanout-core declaration, without writing a from-scratch
-- Expr frontend. Not part of the build/test suite - a benchmark/probe
-- script, run via `lake env lean --run IrDumpScratch.lean`, matching
-- ScaleScratch.lean's precedent.
--
-- Measured result against Fanoutcore.hysteresisTicksFor
-- (`max 1 (lookaheadTicks / 2)`):
--
-- Phase.mono succeeds and returns exactly the restricted-IR shape
-- checkpoint 2 needs - already erased, already monomorphized, no
-- dependent types or typeclass dictionaries visible:
--
--   def Fanoutcore.hysteresisTicksFor lookaheadTicks : UInt64 :=
--     let _x.1 := 1;
--     let _x.2 := UInt64.shiftRight lookaheadTicks _x.1;
--     let _x.3 := UInt64.decLe _x.1 _x.2;
--     cases _x.3 : UInt64
--     | Bool.false => return _x.1
--     | Bool.true => return _x.2
--
-- Lean's own compiler already lowered `/ 2` to a shift and `max` to a
-- decidable-comparison cases split - exactly the kind of simplification
-- a from-scratch Expr frontend would have had to reimplement by hand.
--
-- Phase.impure (the final, closest-to-codegen phase) is NOT queryable
-- via getDeclAt? in this Lean toolchain (v4.30.0) - it throws
-- "Internal compiler error: getDecl? on impure is unuspported for now"
-- [sic, upstream's own typo]. This is a real, load-bearing finding for
-- checkpoint 2's design: target Phase.mono as the IR source, not
-- Phase.impure.

import Lean.Compiler.LCNF.Main
import Lean.Compiler.LCNF.PhaseExt
import Lean.Compiler.LCNF.PrettyPrinter
import Fanoutcore.Zone

open Lean Lean.Compiler.LCNF

def phaseName : Phase → String
  | .base => "base"
  | .mono => "mono"
  | .impure => "impure"

def dumpDecl (declName : Name) (phase : Phase) : CoreM Unit := do
  Lean.Compiler.LCNF.main #[declName]
  match ← getDeclAt? declName phase with
  | none =>
    IO.println s!"no LCNF decl found for {declName} at phase {phaseName phase}"
  | some decl =>
    let fmt ← ppDecl' decl phase
    IO.println s!"=== {declName} @ {phaseName phase} ==="
    IO.println fmt.pretty

unsafe def main : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let env ← Lean.importModules #[`Fanoutcore.Zone] {}
  let coreCtx : Core.Context := { fileName := "IrDumpScratch", fileMap := default }
  let coreState : Core.State := { env }
  discard <| (dumpDecl `Fanoutcore.hysteresisTicksFor .mono).toIO coreCtx coreState
