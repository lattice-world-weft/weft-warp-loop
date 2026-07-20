# Standardize sandboxed content execution on s7 Scheme (Lisp-1)

## Status

Proposed.

## Decision

s7 Scheme, running as a libriscv guest (ADR 0006), is this repo's one
language for sandboxed, frequently-changing content (mission scripts,
loot tables, NPC behavior). Chosen on code power over GDScript (no
macros, unproven in this repo), taskweft's RECTGTN (declarative-only, no
general logic), and a freestanding Lean4 port (no embeddable Lean4
runtime exists anywhere; unproven, against Gall's Law). Lean4 stays a
separate, ahead-of-time-compiled kernel tier (`fanout-core`,
`sketch-core`) — not a competitor for this slot. ADR 0012 covers how
Lean4 still feeds into sandboxed content without running there.

## Consequences

Good: no new vendoring; one language, one determinism-verification
burden (ADR 0004), not one per added language. Bad: script authors need
Scheme, not GDScript — accepted, since the deciding axis is code power,
not onboarding ease. s7 has no static types of its own; see ADR 0012 for
the mitigation.
