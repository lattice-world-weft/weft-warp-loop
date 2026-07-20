# AOT-compile Scheme content to RISC-V machine code, not interpret it via s7's runtime

## Status

Superseded by [ADR 0028](0028-interpret-first-compile-later-supersedes-0014.md)
for the primary execution path — this ADR's pipeline (checkpoints
1-4 shipped as ADR 0015-0025) remains valid as a deferred, optional
optimization, not the mandatory path this ADR originally required.

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
(plain data, total functions) straight to RISC-V machine code, entirely
at build/deploy time — never lazily at content-load, never per-call.
The running server only ever loads the resulting precompiled RISC-V ELF
binaries through libriscv, the same way `godot-sandbox-gdscript-compiler`
itself never ships inside godot-sandbox's runtime, only its ELF output
does. s7 — interpreter and compiler alike — evaporates at runtime: it
exists purely as an offline toolchain component (reference semantics,
review, and the compiler's own implementation language), with zero
footprint in the deployed process. Both Lean4-ported content and
hand-authored s7 scripts go through this same offline path.

Target: single-item compile stays under 5 seconds (one script or table,
not a full rebuild). No RISC-V codegen, register allocator, or ELF
builder existed in this repo before ADR 0013, so this is unmeasured, but
it's a reasonable bar — the reference GDScript compiler has no LLVM or
heavyweight optimizer in its pipeline either, and content-sized inputs
(a spell script, a loot table) are tiny compared to what it was built
against. Under that bar, a "save, recompile, run" loop reads as
hot-reload, not a real build step, which is what actually answers the
workflow-cost concern below — not abandoning offline compilation.

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
already solved for a simpler, closure-free language. Losing s7's live
interpreter also loses the fast edit-and-immediately-run loop content
authors had — mitigated, not eliminated, by the <5s target above: a
content author still waits on a build, just a short enough one that it
doesn't break flow. Revisit trigger: if real compile times land well
above 5s once the backend exists, the interpreter-fallback option this
ADR currently rules out is back on the table for iteration, with
compiled output still required before anything ships.
