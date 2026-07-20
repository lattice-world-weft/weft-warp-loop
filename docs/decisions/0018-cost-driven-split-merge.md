# AV1-style cost-driven zone split/merge, over the prior art's ray-tracing SAH

## Status

Accepted; implemented (`Partition.lean`/`ZoneDispatch.lean`'s
`maybeSplitZone`/`maybeMergeSiblings`, property-tested, including a real
inverted-condition bug found and fixed post-implementation).

## Decision

A fixed zone count (Fiedler's uniform grid, [ADR 0008](0008-fiedler-scale-constants-and-fabric-interest-authority.md))
doesn't fit the fabric's Hilbert-range model, where dense areas need
more, smaller ranges and sparse areas fewer, larger ones. Rather than
port `lean-predictive-bvh`'s SAH (surface-area-heuristic, built for
ray-tracing broadphase), adopted an AV1-style population-cost model:
`leafCost(k) := k*k`, split when `splitCost < leafCost population`,
octree-aligned. Merge needs the *opposite* polarity from split (merge
when population is cheap enough that combining costs less than staying
split) — a real bug shipped initially with merge using split's identical
comparison, caught by a property test that falsified at the simplest
possible input (`depth := 0, conn := 0`) and fixed together with an
`authorityCapacity` guard preventing merges that would breach the
capacity ceiling ([ADR 0019](0019-capacity-separated-authority-interest-budgets.md)).

## Consequences

Good: split/merge responds to measured population density, not a
pre-drawn map — zone count grows and shrinks with load automatically.
Θ(k²) is this project's own cost model, not a reused formula, so it
needed its own property tests rather than inheriting the prior art's
correctness argument. Bad: the merge-polarity bug shipped once already —
symmetric-looking split/merge logic is a real correctness trap this
codebase has already paid for, worth remembering before touching either
function again.
