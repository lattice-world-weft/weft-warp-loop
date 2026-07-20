# Taskweft port Layer 2 complete: ReBAC (Capabilities, FloydWarshall, ReBACGoal)

## Status

Accepted; implemented and verified (`taskweft-capabilities.shrub`,
`taskweft-floydwarshall.shrub`, `taskweft-rebacgoal.shrub`).

## Decision

Layer 2 (ReBAC) is complete: `Capabilities.lean`'s fuel-bounded
`hasCapability` (direct edge, `IS_MEMBER_OF` inheritance, and the
`DELEGATED_TO`→`CONTROLS` special case), `hasCapabilityString` (action-
string dispatch), `checkRelationExpr` (recursive evaluator over
`RelationExpr`'s union/intersection/difference/tuple-to-userset
combinators), `expand` (direct+inherited entity list, deduplicated),
`hasCapabilityReBAC`; `FloydWarshall.lean`'s `fwStep`/`run` (the
`Nat → Nat → Int` distance "matrix" ported as a genuine Scheme closure,
not an array — Lean's own function-valued representation, carried over
directly rather than reinvented); `ReBACGoal.lean`'s `uniSatisfied`/
`multiSatisfied`. `RelationType` (Types.lean, no payload data) is
represented as plain symbols (`'OWNS`, `'CONTROLS`, ...), the same
convention Layer 0 established but not exercised with concrete values
until this layer.

Each verified independently against a small, real, hand-traced
relationship graph (`alice OWNS house1`, `alice IS_MEMBER_OF admins`,
`admins HAS_CAPABILITY delete_anything`, `bob DELEGATED_TO alice`) —
Capabilities' test alone covers six real cases at once (direct,
inherited, delegated-special-case, fuel exhaustion, a union
`RelationExpr`, `expand`'s dedup). `FloydWarshall` was checked against
the Lean source's own already-proven theorems
(`testNegativeCycleDetected`/`testNegativeCycleNodesCaptured`, both
`by decide`) rather than a freshly-computed reference — a legitimate
shortcut when the source itself already carries a proof of the exact
value.

## Consequences

Good: the full ReBAC layer works end to end on a real (if small) graph,
not just individually-plausible functions — the delegated-capability
special case in particular is easy to get backwards (subject/object
swap) and the test specifically exercises it correctly. Bad: `expand`'s
dedup order and `checkRelationExpr`'s `difference` combinator (not
exercised by this graph, which has no case needing it) remain
unverified beyond code inspection; a future pass could extend the test
graph to cover `difference` explicitly.
