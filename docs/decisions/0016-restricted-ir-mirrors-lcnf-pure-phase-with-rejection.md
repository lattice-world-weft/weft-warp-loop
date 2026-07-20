# Restricted IR mirrors LCNF's pure-phase subset, with explicit rejection over silent mistranslation

## Status

Accepted; implemented (`flow-toolchain/fanout-core/IrLowerScratch.lean`,
checkpoint 2 of the ADR 0013/0014 compiler).

## Decision

At `Phase.mono` (pure purity), `Lean.Compiler.LCNF`'s own `Code`/
`LetValue` constructors are already a closed, small set (checked
directly against this toolchain's source): `Code` has only
`let`/`fun`/`jp`/`jmp`/`cases`/`return`/`unreach`; `LetValue` has only
`lit`/`erased`/`proj`/`const`/`fvar` — every impure-only constructor
(`ctor`, `box`, `unbox`, `inc`/`dec`, ...) is structurally unreachable
here. `RExpr`/`RStmt`/`RDecl` mirror this subset near 1:1, narrowed
further by a call-target whitelist (arithmetic/comparison primitives
only) and a zero-param-alt requirement on `cases`. Anything outside this
— `fun`/`jp`/`jmp` (closures, deferred per ADR 0014's own consequence),
non-Bool `cases`, non-whitelisted calls, `proj`, `unreach` — is a hard
`Except.error` with a specific reason, not a best-effort guess.

Verified against two real declarations: `hysteresisTicksFor` lowers
cleanly; `Zone.sub` is rejected with `"cases on non-Bool inductive
Fanoutcore.Zone"`, failing at the first unsupported construct before
ever reaching the `Array.any`/`Array.push` calls deeper in its body —
real proof the rejection path fires on real out-of-subset content.

## Consequences

Good: the restricted IR needs no separate erasure-safety pass of its own
— it's a strict subset of an already-erased representation, so anything
that parses is erasure-safe by construction; rejection is exhaustive
(every `Code`/`LetValue` constructor is matched, none silently ignored).
Bad: the subset is deliberately narrow — no closures, no data structures
beyond bare scalars, no recursion into non-whitelisted calls — real
content (loot tables, NPC behavior) will hit rejections regularly until
the subset grows, each growth needing its own deliberate codegen support
in checkpoint 3, not just a translator change.
