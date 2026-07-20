# Taskweft port Layer 0: Types.lean's SolutionTree/e-graph model, not the simpler find_plan doc account

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/shrubbery/taskweft-types.shrub`).

## Decision

`taskweft/taskweft`'s real current planner architecture
(`lean/Planner/Types.lean`) is an equality-saturation/e-graph-based
`SolutionTree` (node pruning, blacklisting, shadow-states, `EClass`/
`ENode` flat storage) — materially different from and more complex than
the simpler GTPyHOP-style backtracking `find_plan` described in
`docs/rectgtn.md` and already ported as `taskweft-lite.shrub`
([ADR 0035](0035-taskweft-lite-htn-forward-decomposition-ported-to-shrubbery.md)).
Both are real; this layer follows `Types.lean` exactly as written, not
the doc's older/simplified account. Ported the three operational
functions (`pruneNode`, `allocNodeId`, `addToBlacklist`) plus the
supporting record types (`Relationship`, `ActionModel`, `StateVar`,
`TimelineEntry`, `EClass`, `PlanState`, `SolutionNode`, `SolutionTree`,
via `record-macros.scm`'s `define-record`). Their three theorems
(`idMonotonicity`, `pruningDecreasesSize`, `blacklistPersistence`) need
no porting — proofs about these functions, not new runtime code, same
erasure principle already established for the compiler work.
`SolutionTree.is_tree : Prop` is proof-only and correctly carries no
runtime representation.

Two real bugs found while building this, both reusable findings for the
rest of the port: (1) `record-with`'s field-list argument must be a
*literal* quoted list at every call site — a helper function returning
the list (`plan-state-fields()`) doesn't work, since `define-macro`
receives unevaluated syntax (already known from ADR 0034, re-confirmed
here at larger scale — an 11-field record makes the repetition
genuinely painful, accepted anyway). (2) A new, previously-undiscovered
limit of the shrubbery reader itself: a raw parenthesized escape-hatch
term is frozen as opaque text in full — shrubbery call syntax written
*inside* one (e.g. `(next-node-id +(new-id, 1))`) is never recursively
expanded, since `parse_call` only fires at the top of a term. Anything
written inside a raw `(...)` escape hatch must be pure Scheme throughout,
not a mix of styles.

## Consequences

Good: the port now follows taskweft's actual current architecture, not
a stale doc description — a real correction caught by reading the
source instead of trusting the summary. The reader's nesting limitation
is now documented and won't cost debugging time again for layers 1-6.
Bad: the `SolutionTree`/e-graph model is a genuinely bigger, less
familiar shape than `taskweft-lite`'s simple backtracking search —
later layers (`UnifiedGTN`, `MultiGoalDecomposition`) will need to work
against *this* model, which may cost more per-layer time than the
original critical-path estimate assumed (that estimate was built before
this architecture was actually read).
