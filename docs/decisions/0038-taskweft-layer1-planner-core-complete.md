# Taskweft port Layer 1 complete: planner core (Commands, UnifiedGTN, ReentrantPlanner), MultiGoalDecomposition confirmed empty

## Status

Accepted; implemented and verified (`taskweft-commands.shrub`,
`taskweft-unifiedgtn.shrub`, `taskweft-reentrantplanner.shrub`).

## Decision

Layer 1 of the full taskweft port (planner-core extensions beyond
[Layer 0](0036-taskweft-layer0-types-solutiontree-egraph-model.md)) is
complete: `Commands.lean` (tag constructors + a pure substitute for the
original's IO-logging stub), `UnifiedGTN.lean` (`nodeLifecycleStep` —
an `'open` node becomes `'closed` tagged `"new"`; `extractPlan` — a
hand-written filter-map collecting `"new"`-tagged task nodes into
`PlanElement` actions), `ReentrantPlanner.lean` (`markVerified`/
`replan` over a `PlanSolutionTree` record). Each verified independently
against hand-traced expected values, encoded as a single checkable
integer per test, matching every prior layer's methodology.
`MultiGoalDecomposition.lean` stays confirmed empty of portable content
(no re-investigation needed — already established while scoping this
layer).

## Consequences

Good: the planner-core layer is done, each piece independently tested,
none silently assumed correct. Bad: none of these three pieces have
been wired together yet or tested against the `SolutionTree` model as
a whole (only individual functions in isolation) — that composite proof
is Layer 6's job (full integration against a real domain), not this
layer's.
