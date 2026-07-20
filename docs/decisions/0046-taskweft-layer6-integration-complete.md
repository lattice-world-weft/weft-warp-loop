# Taskweft port Layer 6 complete: integration, and no real fusion of goals+ReBAC+temporal exists to copy

## Status

Accepted; implemented and verified
(`s7_riscv_taskweft_layer6_integration_test.cpp`).

## Decision

Before writing this layer, `taskweft/nif`'s real `c_src/taskweft_nif.cpp`
was fetched and read in full to find the exact call shape a composed
goals+ReBAC+temporal entry point should mirror. There isn't one: the
`plan_with_temporal*` family (4 variants) only ever composes `tw_plan`/
`tw_plan_with_tree` with `tw_check_temporal*` - none of them touch
`TwReBAC::*`. The 8 `rebac_*` NIFs are entirely standalone graph
operations with no planner interaction. `witness_oracle` takes
`state_json`/`tasks_json` parameters but its body ignores both,
re-parsing only `domain_json` - a real oddity in the upstream source
itself, not something to replicate.

Also checked `SimpleTravelExample.lean` and
`HealthcareSchedulingExample.lean` in `lean/Planner/` for a ready-made
golden vector to reuse (this port's established shortcut, e.g. how
[Iso8601Duration](0041-taskweft-layer3b-iso8601duration-complete.md)
and [FloydWarshall](0039-taskweft-layer2-rebac-complete.md) used the
Lean source's own proven values instead of computing fresh ones).
Neither file has a single `#eval` - both verify via `native_decide`-
proved `theorem`s instead, so there's no printed reference output to
lift even if one of them fused all three concerns. And neither one
does anyway: `SimpleTravelExample` is pure STRIPS-style
goals/actions, no ReBAC or temporal constraints at all;
`HealthcareSchedulingExample` adds a `time : Nat` field and per-action
durations but still no ReBAC.

Since the real system - neither the NIF layer nor the example domains -
ever composes all three, Layer 6 builds its own small scenario and
hand-traces the expected result, the same fallback
[Layer 1](0038-taskweft-layer1-planner-core-complete.md)'s taskweft-lite
verification already used when no official worked example existed.
Scenario: a courier delivery task. `find-plan` (goals,
`taskweft-lite.shrub`) decomposes "deliver-package" into
`[pickup, transport, dropoff]` via its one method alternative;
`has-capability` (ReBAC, `taskweft-capabilities.shrub`) checks that
only a courier who is `IS_MEMBER_OF` `authorized_couriers` (which
itself `HAS_CAPABILITY` `access_restricted`) may perform the
`transport` step, since it moves the package into
`restricted_zone` - courier1 (a member) passes, courier2 (not a
member) is correctly denied; `all-constraints-satisfied` (temporal,
`taskweft-temporal.shrub`) checks the produced plan's own order
against `pickup`-before-`transport`, `transport`-before-`dropoff`, and
a `dropoff`-within-30 deadline - checked once against the plan's real
order (holds) and once against a deliberately reordered sequence
(does not hold), so the check isn't just verifying a constant.

No new `.shrub` port was needed - every piece Layer 6 composes
(`find-plan`, `has-capability`, `all-constraints-satisfied`) was
already ported and independently verified in earlier layers; this
layer is purely the composition and its own verification.

## Consequences

Good: the full taskweft port (Layers 0-6) is complete - every layer
either ported and verified, or confirmed non-portable with the reason
recorded (`MultiGoalDecomposition`, and `WitnessDAG` until
[0045](0045-taskweft-layer5-witnessdag-ported-via-own-fuzzer.md)'s own
fuzzer made it portable after all). Bad: this integration scenario is
this port's own invention, not derived from or matching any real
taskweft domain that exercises all three concerns together - if
`taskweft/taskweft` ever adds one, it would be worth re-verifying
against that instead of trusting this hand-traced substitute
indefinitely.
