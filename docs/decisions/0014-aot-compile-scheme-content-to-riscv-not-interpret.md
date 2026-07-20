# AOT-compile Scheme content to RISC-V machine code, not interpret it via s7's runtime

## Status

Proposed.

## Decision

ADR 0006's "s7 Scheme running as a libriscv guest" is, as implemented,
interpretation: s7's own interpreter loop is AOT-compiled to RISC-V (real
native code), but the Scheme *content* it runs — mission scripts, loot
tables, Lean4-ported functions ([ADR 0012](0012-lean4-verification-front-end-ported-to-s7.md))
— is parsed and evaluated by that interpreter at call time, not itself
compiled. Adopting a mature AOT-native Scheme compiler (Chez, Racket)
doesn't fix this: ADR 0006 already rejected that family for Rhombus on
the same grounds that apply here — no freestanding-embeddable,
RISC-V-targetable story, and their JIT paths emit **host**-native code,
which breaks the fixed-ISA determinism libriscv provides. The fix is to
extend the compiler [ADR 0013](0013-mechanize-lean4-to-s7-port-via-gdscript-compiler-shape.md)
already scopes one stage further: instead of stopping at generated s7
*source text* for the interpreter to run, lower the same restricted IR
(plain data, total functions) straight to RISC-V machine code, ahead of
time at content-load rather than per-call. Both Lean4-ported content and
hand-authored s7 scripts compile through this path and run as genuine
native RISC-V code inside libriscv; s7's interpreter is demoted to a
reference-semantics and devtool role, not the production execution path.

## Consequences

Good: content actually runs as compiled native code, closing the gap
ADR 0006's wording implied but never built; reuses ADR 0013's IR and
erasure-safety work rather than starting a second compiler project. Bad:
this is now two backends off one IR (s7 source for review/interpretation,
RISC-V machine code for execution) instead of one — real added scope on
top of ADR 0013; s7's macro/closure power (ADR 0011's deciding reason
for choosing s7 at all) still needs a real execution story once
compiled — closures need an actual calling convention and heap in the
generated RISC-V code, not tree-walking, a nontrivial compiler-backend
problem the reference GDScript project's own `riscv_codegen.h/cpp`
already solved for a simpler, closure-free language.
