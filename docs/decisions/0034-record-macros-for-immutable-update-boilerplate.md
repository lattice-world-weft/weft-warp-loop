# define-record/record-with macros replace hand-written vector-reconstruction boilerplate

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/content/record-macros.scm`;
`combat.scm`/`progression.scm` refactored to use it).

## Decision

Per ADR 0028's own Paul Graham citation, macros are the other half of
Lisp's development-velocity case besides interactive iteration — bend
the language to the problem instead of hand-writing the same pattern at
every call site. `combat.scm`/`progression.scm`'s hand ports
(ADR 0031) each wrote out immutable-record-update
(`{ s with f := v }`) as a full positional `(make-state (accessor1 s)
(accessor2 s) ... newval ...)` call, listing every unchanged field —
exactly the repetitive boilerplate macros exist to remove.
`define-record` generates a constructor and per-field accessors over a
plain vector (no new runtime type, no allocator — a console-grade
choice, ADR 0029); `record-with` expands, at macro-expansion time, to a
positional reconstruction where only changed fields are named — no
runtime `case` dispatch, no `vector-copy`, no hidden state shared across
macro invocations. The field list is a literal quoted argument at each
call site, not a variable reference: `define-macro` in s7 receives
unevaluated syntax, so a variable holding the field list wouldn't be
visible at expansion time — a real, accepted verbosity cost, still
smaller than the boilerplate it replaces.

`s7RiscvEvalInt`'s new use here caught one more thing: content must
never call `(load ...)` from inside the guest. `record-macros.scm` is
concatenated onto `combat.scm`/`progression.scm` on the **host** side
(the same pattern the golden tests already used for a single file, now
extended to two), because a guest-side `load` would need a real
filesystem syscall from inside libriscv's fuel-metered/gas-limited
sandbox — outside the marshaled VMCALL boundary that gives this whole
tier its resume/pause/gas-limit/sandbox properties in the first place.

Verified in three stages: the macros alone (`define-record`
`thing`/`record-with`, checked against a hand-computed expected value);
`combat.scm` refactored, re-run through its existing golden-vector test
(`enemyHp = 90`, unchanged — pure refactor, not a behavior change);
`progression.scm` likewise (`credits = 150`, unchanged).

## Consequences

Good: `{ s with f := v }` sites in ported content now name only what
changed, directly mirroring the Lean source instead of spelling out
every unchanged field — less to get wrong when porting or editing.
Reusable for any future port with the same immutable-struct-update
shape. Bad: real, measured runtime cost — `combat.scm`'s golden test
went from `339498` to `771414` instructions (2.3x), `progression.scm`
from `271360` to `401955` instructions (1.5x), after the macro refactor
— macro-expanded code is less hand-optimized than the original
accessor-call pattern. Acceptable for interpreted content per ADR 0028
(velocity over footprint), but a real number to know before assuming
macros are free.
