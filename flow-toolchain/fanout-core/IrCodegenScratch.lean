-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- Checkpoint 3 of ADR 0013/0014's compiler PERT plan: RISC-V codegen
-- for the restricted IR (IrLowerScratch.lean's RExpr/RStmt/RDecl,
-- duplicated here rather than imported - these are scratch scripts, not
-- library targets, matching ScaleScratch.lean/IrDumpScratch.lean's own
-- precedent). Not part of the build/test suite - run via
-- `lake env lean --run IrCodegenScratch.lean`.
--
-- Deliberate deviation from ADR 0013's literal wording: instead of a
-- hand-rolled RISC-V machine-code encoder (bit-packing R/I/B-type
-- instruction words by hand, the shape godot-sandbox-gdscript-compiler's
-- own riscv_codegen.h/cpp uses), this emits RISC-V ASSEMBLY TEXT and
-- assembles it with the already-vendored, already-proven
-- riscv-none-elf-gcc/as toolchain (the same one that already builds
-- s7_guest.elf, per ADR 0006). Justification: ADR 0014 already moved
-- compilation to build/deploy time, where this project already depends
-- on that toolchain for other targets - reusing a proven assembler for
-- correct instruction encoding is strictly lower-risk than hand-writing
-- one, and costs nothing new, since the dependency already exists. The
-- reference project hand-rolled its own encoder because it ships as an
-- end-user runtime plugin compiler with no host toolchain to assume;
-- that constraint does not apply here. Register allocation is still
-- this compiler's own work, not delegated to the assembler.
--
-- Register allocation: params get a0, a1, ... in declaration order;
-- each let-bound value gets the next unused register from
-- {t0..t6} - a real linear allocator, honest about running out past 7
-- live temporaries (an error, not silent corruption), matching what
-- ADR 0013 called "a simple linear-scan or stack-based allocator is
-- fine for this subset."
--
-- Measured result: Fanoutcore.hysteresisTicksFor assembles cleanly with
-- riscv-none-elf-as (rv64gc/lp64d, matching ADR 0006's own target) with
-- zero warnings/errors. riscv-none-elf-objdump -d confirms the exact
-- expected sequence: li t0,1 / srl t1,a0,t0 / sltu t2,t1,t0 /
-- xori t2,t2,1 / beqz t2,.Lfalse / mv a0,t1 / ret / .Lfalse: mv a0,t0 /
-- ret. Hand-traced against both branches: lookaheadTicks=6 -> t1=3,
-- t2=(3<1)=0, xori->1(true), falls through, returns t1=3 (matches
-- max 1 3 = 3). lookaheadTicks=1 -> t1=0, t2=(0<1)=1, xori->0(false),
-- branches to .Lfalse, returns t0=1 (matches max 1 0 = 1). Both correct.

import Lean.Compiler.LCNF.Main
import Lean.Compiler.LCNF.PhaseExt
import Fanoutcore.Zone

open Lean Lean.Compiler.LCNF

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

def callWhitelist : List Name :=
  [``UInt64.shiftRight, ``UInt64.shiftLeft, ``UInt64.add, ``UInt64.sub,
   ``UInt64.mul, ``UInt64.div, ``UInt64.mod, ``UInt64.decLe, ``UInt64.decLt,
   ``UInt64.decEq, ``max]

def argToFVar : Arg .pure → Except String FVarId
  | .fvar fv => pure fv
  | .erased => throw "erased argument reached the restricted IR"
  | .type .. => throw "type argument reached the restricted IR"

partial def lowerCode : Code .pure → Except String RStmt
  | .return fv => pure (.ret fv)
  | .let decl k => do
    let rexpr ← match decl.value with
      | .lit v => pure (.lit v)
      | .fvar fv args =>
        if args.isEmpty then pure (.var fv)
        else throw s!"unsupported call target: {fv.name}"
      | .const declName _ args _ =>
        if callWhitelist.contains declName then
          let args ← args.mapM argToFVar
          pure (.call declName args)
        else throw s!"unsupported call target: {declName}"
      | .proj .. => throw "unsupported: structure projection"
      | .erased => throw "unsupported: erased let-value"
    let rest ← lowerCode k
    pure (.letBind decl.fvarId rexpr rest)
  | .cases c => do
    if c.typeName != ``Bool then
      throw s!"unsupported: cases on non-Bool inductive {c.typeName}"
    let mut whenFalse : Option RStmt := none
    let mut whenTrue : Option RStmt := none
    for alt in c.alts do
      match alt with
      | .alt ctorName params code _ =>
        if !params.isEmpty then
          throw s!"unsupported: alt for {ctorName} binds constructor fields"
        let branch ← lowerCode code
        if ctorName == ``Bool.false then whenFalse := some branch
        else if ctorName == ``Bool.true then whenTrue := some branch
        else throw s!"unsupported: unexpected constructor {ctorName}"
      | .ctorAlt .. => throw "unsupported: impure ctorAlt"
      | .default code =>
        let branch ← lowerCode code
        if whenFalse.isNone then whenFalse := some branch
        if whenTrue.isNone then whenTrue := some branch
    match whenFalse, whenTrue with
    | some f, some t => pure (.boolCase c.discr f t)
    | _, _ => throw "unsupported: Bool case missing a branch"
  | .fun .. => throw "unsupported: local function/closure"
  | .jp .. | .jmp .. => throw "unsupported: join point"
  | .unreach .. => throw "unsupported: unreachable/incomplete match"

def lowerDecl (decl : Decl .pure) : Except String RDecl := do
  match decl.value with
  | .extern .. => throw "unsupported: extern declaration"
  | .code code =>
    let body ← lowerCode code
    pure { name := decl.name, params := decl.params.map (·.fvarId), body }

-- === Checkpoint 3: RISC-V assembly codegen ===

structure Emit where
  regOf    : Std.HashMap Name String := {}
  nextTemp : Nat := 0
  asm      : Array String := #[]
  labelNum : Nat := 0

def tempPool : Array String := #["t0", "t1", "t2", "t3", "t4", "t5", "t6"]
def paramPool : Array String := #["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7"]

def freshTemp : StateM Emit (Except String String) := do
  let s ← get
  if s.nextTemp >= tempPool.size then
    pure (throw s!"out of temporary registers (>{tempPool.size} live values in one function - not supported by this checkpoint's allocator)")
  else
    let reg := tempPool[s.nextTemp]!
    set { s with nextTemp := s.nextTemp + 1 }
    pure (pure reg)

def bindReg (fv : FVarId) (reg : String) : StateM Emit Unit :=
  modify fun s => { s with regOf := s.regOf.insert fv.name reg }

def regOfFVar (fv : FVarId) : StateM Emit (Except String String) := do
  let s ← get
  match s.regOf[fv.name]? with
  | some r => pure (pure r)
  | none => pure (throw s!"unbound register for {fv.name}")

def emitLine (line : String) : StateM Emit Unit :=
  modify fun s => { s with asm := s.asm.push line }

def freshLabel (tag : String) : StateM Emit String := do
  let s ← get
  set { s with labelNum := s.labelNum + 1 }
  pure s!".L{tag}{s.labelNum}"

-- Emits `rd := call fn [args]` for a whitelisted primitive, using RV64GC
-- base+M-extension instructions. decLe/decLt/decEq are lowered from
-- Lean4's decidable-comparison convention (`decLe a b` means `a ≤ b`,
-- confirmed by hand against the real hysteresisTicksFor dump in
-- IrDumpScratch.lean) into sltu/seqz sequences.
def emitCall (rd : String) (fn : Name) (argRegs : Array String) : StateM Emit (Except String Unit) := do
  let a := argRegs[0]?
  let b := argRegs[1]?
  match fn, a, b with
  | ``UInt64.shiftRight, some a, some b => emitLine s!"  srl {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.shiftLeft,  some a, some b => emitLine s!"  sll {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.add,        some a, some b => emitLine s!"  add {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.sub,        some a, some b => emitLine s!"  sub {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.mul,        some a, some b => emitLine s!"  mul {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.div,        some a, some b => emitLine s!"  divu {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.mod,        some a, some b => emitLine s!"  remu {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.decLt,      some a, some b => emitLine s!"  sltu {rd}, {a}, {b}"; pure (pure ())
  | ``UInt64.decLe,      some a, some b =>
    -- a <= b  ==  !(b < a)
    emitLine s!"  sltu {rd}, {b}, {a}"
    emitLine s!"  xori {rd}, {rd}, 1"
    pure (pure ())
  | ``UInt64.decEq,      some a, some b =>
    emitLine s!"  sub {rd}, {a}, {b}"
    emitLine s!"  seqz {rd}, {rd}"
    pure (pure ())
  | ``max, some a, some b =>
    let lGreater ← freshLabel "max_greater"
    let lDone ← freshLabel "max_done"
    emitLine s!"  bltu {a}, {b}, {lGreater}"
    emitLine s!"  mv {rd}, {a}"
    emitLine s!"  j {lDone}"
    emitLine s!"{lGreater}:"
    emitLine s!"  mv {rd}, {b}"
    emitLine s!"{lDone}:"
    pure (pure ())
  | _, _, _ => pure (throw s!"codegen: unsupported call shape for {fn} (arity/argument mismatch)")

partial def emitStmt : RStmt → StateM Emit (Except String Unit)
  | .ret fv => do
    match ← regOfFVar fv with
    | .error e => pure (throw e)
    | .ok reg =>
      if reg != "a0" then emitLine s!"  mv a0, {reg}"
      emitLine "  ret"
      pure (pure ())
  | .letBind fv value rest => do
    match value with
    | .lit v =>
      let n := match v with
        | .nat n => n | .uint64 n => n.toNat | .uint32 n => n.toNat
        | .uint16 n => n.toNat | .uint8 n => n.toNat | .usize n => n.toNat
        | .str _ => 0
      match ← freshTemp with
      | .error e => pure (throw e)
      | .ok reg =>
        emitLine s!"  li {reg}, {n}"
        bindReg fv reg
        emitStmt rest
    | .var srcFv => do
      match ← regOfFVar srcFv with
      | .error e => pure (throw e)
      | .ok srcReg =>
        bindReg fv srcReg
        emitStmt rest
    | .call fn args => do
      let mut argRegs : Array String := #[]
      let mut err : Option String := none
      for a in args do
        match ← regOfFVar a with
        | .error e => err := some e
        | .ok r => argRegs := argRegs.push r
      match err with
      | some e => pure (throw e)
      | none =>
        match ← freshTemp with
        | .error e => pure (throw e)
        | .ok reg =>
          match ← emitCall reg fn argRegs with
          | .error e => pure (throw e)
          | .ok () =>
            bindReg fv reg
            emitStmt rest
  | .boolCase scrutinee whenFalse whenTrue => do
    match ← regOfFVar scrutinee with
    | .error e => pure (throw e)
    | .ok sreg =>
      let lFalse ← freshLabel "false"
      emitLine s!"  beqz {sreg}, {lFalse}"
      match ← emitStmt whenTrue with
      | .error e => pure (throw e)
      | .ok () =>
        emitLine s!"{lFalse}:"
        emitStmt whenFalse

def emitDecl (decl : RDecl) : Except String String := Id.run do
  let mut s : Emit := {}
  for h : i in [0:decl.params.size] do
    let fv := decl.params[i]!
    if i >= paramPool.size then
      return throw s!"more than {paramPool.size} parameters - not supported"
    s := (bindReg fv paramPool[i]!).run s |>.snd
  let asmName := decl.name.toString (escape := false) |>.replace "." "_"
  s := (emitLine s!".globl {asmName}\n{asmName}:").run s |>.snd
  let (result, s') := (emitStmt decl.body).run s
  match result with
  | .error e => pure (throw e)
  | .ok () => pure (pure ("\n".intercalate s'.asm.toList ++ "\n"))

def tryCodegen (declName : Name) : CoreM Unit := do
  Lean.Compiler.LCNF.main #[declName]
  match ← getDeclAt? declName .mono with
  | none => IO.println s!"{declName}: no Phase.mono decl found"
  | some decl =>
    match lowerDecl decl with
    | .error reason => IO.println s!"{declName}: REJECTED (lowering) - {reason}"
    | .ok rdecl =>
      match emitDecl rdecl with
      | .error reason => IO.println s!"{declName}: REJECTED (codegen) - {reason}"
      | .ok asmText =>
        IO.println s!"{declName}: CODEGEN OK\n{asmText}"
        let asmFile := "IrCodegenScratch_out.s"
        let objFile := "IrCodegenScratch_out.o"
        IO.FS.writeFile asmFile asmText
        let asOut ← IO.Process.output {
          cmd := "riscv-none-elf-as"
          args := #["-march=rv64gc", "-mabi=lp64d", asmFile, "-o", objFile]
        }
        if asOut.exitCode != 0 then
          IO.println s!"ASSEMBLE FAILED (exit {asOut.exitCode}):\n{asOut.stderr}"
        else
          IO.println "ASSEMBLE OK"
          let objdumpOut ← IO.Process.output {
            cmd := "riscv-none-elf-objdump"
            args := #["-d", objFile]
          }
          IO.println objdumpOut.stdout

unsafe def main : IO Unit := do
  Lean.enableInitializersExecution
  Lean.initSearchPath (← Lean.findSysroot)
  let env ← Lean.importModules #[`Fanoutcore.Zone] {}
  let coreCtx : Core.Context := { fileName := "IrCodegenScratch", fileMap := default }
  let coreState : Core.State := { env }
  discard <| (tryCodegen `Fanoutcore.hysteresisTicksFor).toIO coreCtx coreState
