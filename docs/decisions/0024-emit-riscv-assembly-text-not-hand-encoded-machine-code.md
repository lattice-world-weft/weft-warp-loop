# Emit RISC-V assembly text and reuse the vendored assembler, not a hand-rolled machine-code encoder

## Status

Accepted; implemented (`flow-toolchain/fanout-core/IrCodegenScratch.lean`,
checkpoint 3 of the ADR 0013/0014 compiler).

## Decision

ADR 0013 named `godot-sandbox-gdscript-compiler`'s `riscv_codegen.h/cpp`
+ `register_allocator.h/cpp` as the structural reference for this
checkpoint — a hand-rolled RISC-V machine-code bit-encoder. Deviated
from that literally: this codegen emits RISC-V *assembly text* and
assembles it with the already-vendored `riscv-none-elf-as`, the same
toolchain that already builds `s7_guest.elf` ([ADR 0006](0006-libriscv-sandboxed-s7-lisp-over-native-janet.md)).
The reference project hand-encoded instructions because it ships as an
end-user runtime plugin compiler with no host toolchain to assume; this
project's own ADR 0014 already moved compilation to build/deploy time,
where a toolchain dependency is free — this project already depends on
`riscv-none-elf-gcc`/`as` for another target. Reusing a proven assembler
for instruction encoding is strictly lower-risk than hand-writing a
bit-packer, for zero added dependency cost. Register allocation stays
this compiler's own work either way: params map to `a0..a7` in
declaration order, each let-bound value gets the next unused register
from `{t0..t6}`, erroring (not corrupting) past 7 live temporaries.

Verified against `hysteresisTicksFor`: assembles with
`riscv-none-elf-as -march=rv64gc -mabi=lp64d` with zero warnings, and
the disassembly (`riscv-none-elf-objdump -d`) was hand-traced against
both branches (`lookaheadTicks=6` → 3, `lookaheadTicks=1` → 1), both
matching `max 1 (lookaheadTicks / 2)`.

## Consequences

Good: instruction encoding correctness is delegated to an already-proven
tool instead of a new hand-written encoder — the actual bit-packing risk
this checkpoint was flagged as riskiest for is avoided, not merely
managed. Bad: this compiler now depends on invoking an external
assembler as a build step, not just linking a library — a real process
boundary (`IO.Process.output`) between codegen and the object file, with
its own failure mode (assembler exit code, stderr) to handle at
checkpoint 4's ELF-building stage. `max`'s branch-based codegen is
implemented but unexercised by any current real content (Lean's own
compiler already unfolds `max` into a decidable-comparison cases split
before `Phase.mono`, per [ADR 0015](0015-target-lcnf-phase-mono-not-impure.md)) —
correct by inspection, not yet proven against a real declaration.
