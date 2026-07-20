# Hilbert-curve zone authority: one authoritative zone per entity, by curve position

## Status

Accepted; implemented (`Fanoutcore/Zone.lean`'s `hilbert3D`/
`authorityForIndex`, property-tested).

## Decision

Per [ADR 0008](0008-fiedler-scale-constants-and-fabric-interest-authority.md),
`fanout-core` needed a real spatial authority model in place of its flat
per-topic `Room` broadcast, without porting `lean-predictive-bvh` as a
dependency (see [ADR 0009](0009-reserved-witness-zones-for-cross-machine-lease-authority.md)
for why that dependency wasn't kept). Implemented from scratch instead,
reusing only the sibling org's proven *rule*: an entity's 3D position
maps to a 1D Hilbert-curve index (`hilbert3D`), and the zone whose
curve-index range contains that value is the entity's sole authority
(`authorityForIndex`) — never more than one. Disjointness and uniqueness
of authority assignment are property-tested, not just asserted.

## Consequences

Good: authority lookup is a pure function of position — no coordination
needed to answer "who owns this point," matching the read-only-ghost
model ADR 0008 adopted. Locality-preserving curve mapping means nearby
positions usually land in nearby (often the same) zones, keeping
per-tick authority churn low. Bad: Hilbert-curve index computation adds
real per-move cost over a flat broadcast; zone boundaries are curve
artifacts, not intuitive world-space shapes, which affects how zone
splits/merges ([ADR 0018](0018-cost-driven-split-merge.md)) actually
subdivide space.
