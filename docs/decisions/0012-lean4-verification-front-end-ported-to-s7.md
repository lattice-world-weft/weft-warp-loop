# Lean4 as a verification front end for s7 content, ported through s7_riscv_actor

## Status

Proposed.

## Decision

For content where correctness matters more than authoring speed: state
and prove the logic in Lean4 first (the same Plausible discipline
`fanout-core`'s 33 property tests already use), then hand-port the
proved function into s7, executed through the existing
`s7_riscv_actor.actor.cpp` sandboxed call site — the same one every other
s7 script uses. Lean4 itself never runs inside the sandbox; only its
proved conclusions do, translated by hand. Optional per content item —
most mission scripts and loot tables stay hand-written s7 directly,
matching ADR 0006's original reasoning (content changes too often to
prove every time). Mechanizing the port (Lean4 → s7 codegen) is not
scoped here; translation is manual and reviewed until a generator proves
worth building.

## Consequences

Good: proof-backed correctness, per item, with no second execution
language and no second ADR-0004-style byte-compare burden. Bad: a hand
translation can drift from its proved Lean4 source — nothing but review
catches that today.
