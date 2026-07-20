# taskweft's HTN forward-decomposition core, ported to shrubbery, verified against a real domain

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/shrubbery/taskweft-lite.shrub`). Corrects
[ADR 0007](0007-s7-shrubbery-toolchain-scope-and-elixir-nif-comparison.md)'s
stale claim that a `taskweft-lite.scm` already existed.

## Decision

`taskweft/taskweft`'s `plan` tool runs RECTGTN — a GTPyHOP-style HTN
planner (`docs/rectgtn.md`) with three task kinds (`TwCall`/`TwGoal`/
`TwMultiGoal`), goal methods, multigoals, and a ReBAC/capability graph
compiled from a domain's `capabilities`. Reimplementing all of that is
already explicitly out of scope (ADR 0007, item 1). Ported instead: the
actual core search algorithm underneath it all — `find_plan(state,
todo_list)` — scoped to `TwCall` only, exactly what ADR 0007 already
named as the starting point. `find-plan` tries each task in order: an
action's `pointer/set` effects apply directly to state; a method tries
each `alternatives` entry's `subtasks` in order, backtracking (via `#f`)
until one succeeds or all are exhausted. State is a flat alist keyed by
JSON-pointer-style path strings (`"/milestone/stack"`) rather than real
nested-pointer mutation — a documented simplification, not silent
scope-creep, matching the shrubbery reader's and the RISC-V compiler's
own "explicit subset" discipline.

Verified against this repo's own real domain, `plan/bootstrap-domain.json`
— not a synthetic example — hand-encoded as s7 data matching its JSON-LD
structure field for field. `find-plan` on that domain's `todo_list`
(`[["bootstrap"]]`) correctly decomposes through the `bootstrap` method's
one alternative to the single action `bridge_fanout_via_lean_core`,
deterministically: two independent `Machine` instances, `140581`
instructions each, identical.

## Consequences

Good: closes a real gap this session found by accident (a claimed file
that never existed) with the actual thing, not just a corrected
sentence — verified against this project's own real planning content,
not a toy example. The same shrubbery reader, macro system, and
golden-vector methodology already proven for `combat`/`loot`/
`progression` extends cleanly to a structurally different kind of
content (a search algorithm, not a state-machine reducer). Bad: `TwGoal`/
`TwMultiGoal`/ReBAC/capabilities/temporal reasoning remain unported, per
ADR 0007's own standing scope decision — this is deliberately the
smallest real slice, not a claim of planner parity. The flat-alist state
representation doesn't handle real JSON-pointer semantics (array
indices, deep nesting beyond one level) — fine for `bootstrap-domain.json`'s
own shape, a real limit for a more complex domain.
