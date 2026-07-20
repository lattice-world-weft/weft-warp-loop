# Interpret s7 as the primary execution path; AOT-compilation is a deferred, optional optimization

## Status

Accepted; **supersedes [ADR 0014](0014-aot-compile-scheme-content-to-riscv-not-interpret.md)'s**
"s7 evaporates at runtime" mandate for the primary path.

## Decision

One of s7/Lisp-1's stated justifications ([ADR 0011](0011-standardize-sandboxed-scripting-on-s7-lisp1.md))
was code power in Paul Graham's specific sense ("Beating the Averages"):
velocity from interactive, incremental development and macros that bend
the language to the problem, not the reverse. ADR 0014 then required
content to evaporate at runtime — compiled ahead of time, interpreter
absent from the deployed process. That requirement was never fixing a
determinism gap (ADR 0006's interpreted path was already proven
byte-identical across independent `Machine` instances, before ADR 0014
existed); it pursued a separate goal (zero runtime interpreter
footprint) that directly costs the velocity s7 was chosen for. Checked
against real target content ([ADR 0026](0026-closures-and-lists-are-required-not-deferred.md),
[0027](0027-slotmap-shaped-fixed-capacity-collections-no-allocator.md)):
closures, lists, and recursion all already work in s7's interpreter
today, for free — the AOT compiler (checkpoints 1-4, ADR 0015-0025) was
rebuilding a narrower subset of those same features from scratch,
trading a working system for a slower, partial one, in direct tension
with ADR 0011's own reasoning.

Reverted: s7's interpreter (ADR 0006's original design — compiled to
RISC-V, running inside libriscv, `s7_riscv_actor.actor.cpp`'s existing
VMCALL path) is the primary execution path for sandboxed content,
effective immediately. AOT-compilation (the ADR 0013/0014/0015-0025
pipeline) is not abandoned — it stays available as a deferred, optional
optimization for content that has already proven stable through
interpreted development and where footprint or performance is
separately justified, mirroring how mature Lisp systems (SBCL, Common
Lisp's `compile`) actually work: interpret while developing, compile
what's finished, never give up the interpreter as the primary tool.

## Consequences

Good: closures/lists/recursion for real content (`combat`/`progression`/
`loot`-shaped logic) work today with zero further engineering — the
actual, immediate blocker this session was about to spend many more
hours solving from scratch turns out not to be a blocker at all under
the interpreted path. Development velocity — the reason Lisp was chosen
over GDScript in the first place — is restored as the default. Bad: the
compiler work already done (checkpoints 1-4, ADR 0015-0025) isn't
wasted, but its priority drops from "mandatory before any content ships"
to "future optimization, revisit once real content exists and stability/
performance data justifies it" — real hours were spent building
infrastructure whose urgency this decision now retracts. The syscall-
narrowing and fuel-budget-sizing gaps ADR 0006 already flagged as open
remain open and now matter more, since the interpreter is confirmed as
the primary, not fallback, path.
