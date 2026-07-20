-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- Checkpoint 2 of ADR 0013/0014's compiler PERT plan: a restricted IR
-- and a translator from Lean.Compiler.LCNF's Phase.mono Decl into it,
-- with explicit rejection (not silent mistranslation) for anything
-- outside the subset. Not part of the build/test suite - a probe
-- script, run via `lake env lean --run IrLowerScratch.lean`.
--
-- At Phase.mono (pure purity), LCNF's own Code/LetValue constructors
-- are already a closed, small set (checked directly against
-- Lean/Compiler/LCNF/Basic.lean in this toolchain, v4.30.0):
--   Code:     let, fun, jp, jmp, cases, return, unreach
--   LetValue: lit, erased, proj, const, fvar
-- The impure-only constructors (ctor, box, unbox, inc/dec, ...) cannot
-- appear here at all - the restricted IR below is a near-1:1 mirror of
-- this subset, plus a call-target whitelist (arithmetic/comparison
-- primitives only) and a same-type-zero-param-alt requirement on cases,
-- so anything reaching Array/List/String operations, recursion into
-- non-whitelisted functions, or pattern matches that bind constructor
-- fields is rejected with a reason, not guessed at.
--
-- Measured results:
--
-- Fanoutcore.hysteresisTicksFor: LOWERED successfully to
--   let x1 = 1
--   let x2 = call UInt64.shiftRight [lookaheadTicks, x1]
--   let x3 = call UInt64.decLe [x1, x2]
--   case x3 of
--     false => return x1
--     true  => return x2
--
-- Fanoutcore.Zone.sub: REJECTED - "cases on non-Bool inductive
-- Fanoutcore.Zone" - the translator hits a cases-split over the Zone
-- structure itself (Zone.sub's `if ... then z else { z with ... }`
-- lowers to something other than a plain Bool cases at this phase) and
-- correctly bails before ever reaching the Array.any/Array.push calls
-- deeper in the body. Real proof the rejection path fires on real
-- out-of-subset content, not a hypothetical one - and evidence the
-- translator fails fast at the first unsupported construct rather than
-- guessing past it.

import Lean.Compiler.LCNF.Main
import Lean.Compiler.LCNF.PhaseExt
import Fanoutcore.Zone

open Lean Lean.Compiler.LCNF

/-- The restricted IR: a near-1:1 mirror of LCNF's own pure-phase
subset, minus anything this compiler doesn't yet support. -/
inductive RExpr where
  | lit (v : LitValue)
  | var (fv : FVarId)
  | call (fn : Name) (args : Array FVarId)
  deriving Inhabited

inductive RStmt where
  | letBind (fv : FVarId) (value : RExpr) (rest : RStmt)
  | boolCase (scrutinee : FVarId) (whenFalse : RStmt) (whenTrue : RStmt)
  | ret (fv : FVarId)
  deriving Inhabited

structure RDecl where
  name   : Name
  params : Array FVarId
  body   : RStmt

/-- Primitives this compiler's RISC-V backend (checkpoint 3) will know
how to emit directly. Anything else is a hard rejection, not a guess. -/
def callWhitelist : List Name :=
  [``UInt64.shiftRight, ``UInt64.shiftLeft, ``UInt64.add, ``UInt64.sub,
   ``UInt64.mul, ``UInt64.div, ``UInt64.mod, ``UInt64.decLe, ``UInt64.decLt,
   ``UInt64.decEq, ``max]

def argToFVar : Arg .pure → Except String FVarId
  | .fvar fv => pure fv
  | .erased => throw "erased argument reached the restricted IR (proof/type argument leaked past erasure)"
  | .type .. => throw "type argument reached the restricted IR"

partial def lowerCode : Code .pure → Except String RStmt
  | .return fv => pure (.ret fv)
  | .let decl k => do
    let rexpr ← match decl.value with
      | .lit v => pure (.lit v)
      | .fvar fv args =>
        if args.isEmpty then pure (.var fv)
        else throw s!"unsupported call target: {fv.name} (fvar-applied-to-args, not a whitelisted primitive)"
      | .const declName _ args _ =>
        if callWhitelist.contains declName then
          let args ← args.mapM argToFVar
          pure (.call declName args)
        else
          throw s!"unsupported call target: {declName}"
      | .proj .. => throw "unsupported: structure projection (no arrays/structs in the restricted IR yet)"
      | .erased => throw "unsupported: erased let-value reached the restricted IR"
    let rest ← lowerCode k
    pure (.letBind decl.fvarId rexpr rest)
  | .cases c => do
    if c.typeName != ``Bool then
      throw s!"unsupported: cases on non-Bool inductive {c.typeName} (only Bool case-splits are supported so far)"
    let mut whenFalse : Option RStmt := none
    let mut whenTrue : Option RStmt := none
    for alt in c.alts do
      match alt with
      | .alt ctorName params code _ =>
        if !params.isEmpty then
          throw s!"unsupported: alt for {ctorName} binds {params.size} constructor field(s) (not supported yet)"
        let branch ← lowerCode code
        if ctorName == ``Bool.false then whenFalse := some branch
        else if ctorName == ``Bool.true then whenTrue := some branch
        else throw s!"unsupported: unexpected constructor {ctorName} in a Bool case"
      | .ctorAlt .. => throw "unsupported: impure ctorAlt reached the pure-phase translator"
      | .default code =>
        let branch ← lowerCode code
        if whenFalse.isNone then whenFalse := some branch
        if whenTrue.isNone then whenTrue := some branch
    match whenFalse, whenTrue with
    | some f, some t => pure (.boolCase c.discr f t)
    | _, _ => throw "unsupported: Bool case missing a branch"
  | .fun .. => throw "unsupported: local function/closure (deferred - ADR 0013's closure consequence)"
  | .jp .. | .jmp .. => throw "unsupported: join point (not yet lowered)"
  | .unreach .. => throw "unsupported: unreachable/incomplete match reached the translator"

def lowerDecl (decl : Decl .pure) : Except String RDecl := do
  match decl.value with
  | .extern .. => throw "unsupported: extern declaration (no FFI in the restricted IR)"
  | .code code =>
    let body ← lowerCode code
    pure { name := decl.name, params := decl.params.map (·.fvarId), body }

partial def ppRExpr : RExpr → String
  | .lit v => match v with
    | .nat n => toString n | .uint64 n => toString n | .uint32 n => toString n
    | .uint16 n => toString n | .uint8 n => toString n | .usize n => toString n
    | .str s => s!"\"{s}\""
  | .var fv => fv.name.toString
  | .call fn args =>
    let sep := ", "
    let argList := sep.intercalate (args.map (·.name.toString) |>.toList)
    s!"call {fn} [{argList}]"

partial def ppRStmt (indent : String) : RStmt → String
  | .letBind fv v rest => s!"{indent}let {fv.name} = {ppRExpr v}\n" ++ ppRStmt indent rest
  | .boolCase scrutinee f t =>
    s!"{indent}case {scrutinee.name} of\n" ++
    s!"{indent}  false => \n" ++ ppRStmt (indent ++ "    ") f ++
    s!"{indent}  true  => \n" ++ ppRStmt (indent ++ "    ") t
  | .ret fv => s!"{indent}return {fv.name}\n"

def tryLower (declName : Name) : CoreM Unit := do
  Lean.Compiler.LCNF.main #[declName]
  match ← getDeclAt? declName .mono with
  | none => IO.println s!"{declName}: no Phase.mono decl found"
  | some decl =>
    match lowerDecl decl with
    | .ok rdecl =>
      let indent := "  "
      let body := ppRStmt indent rdecl.body
      IO.println s!"{declName}: LOWERED\n{body}"
    | .error reason =>
      IO.println s!"{declName}: REJECTED - {reason}"

unsafe def main : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let env ← Lean.importModules #[`Fanoutcore.Zone] {}
  let coreCtx : Core.Context := { fileName := "IrLowerScratch", fileMap := default }
  let coreState : Core.State := { env }
  discard <| (tryLower `Fanoutcore.hysteresisTicksFor).toIO coreCtx coreState
  discard <| (tryLower `Fanoutcore.Zone.sub).toIO coreCtx coreState
