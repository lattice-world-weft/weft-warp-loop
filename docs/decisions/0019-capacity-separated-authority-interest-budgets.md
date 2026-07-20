# Capacity-separated authority/interest budgets, independent of cost-driven splitting

## Status

Accepted; implemented (`Fanoutcore/Zone.lean`'s `authorityCapacity`,
`interestCapacity`; a real capacity-vanish migration bug found and
fixed via re-verification).

## Decision

Cost-driven splitting ([ADR 0018](0018-cost-driven-split-merge.md))
bottoms out at `octreeMaxDepth`, not at any fixed population number — a
sufficiently dense single cell can still grow a zone's entity array and
Θ(population²) fanout cost without bound once splitting can't subdivide
further. Two independent, fixed resource-safety ceilings were added on
top: `authorityCapacity := 256` (a hard cap on live entities a zone
authoritatively holds) and `interestCapacity := 400` (matching
`AuthorityInterest.lean`'s own validated-at-scale value, capping the
adjacent-zone ghost scan). These are legitimate fixed constants — unlike
the "constant delay" anti-pattern rejected elsewhere in this session
(see [ADR 0020](0020-rtt-derived-hysteresis-no-fixed-delays.md)), a
capacity ceiling is a resource-safety bound, not a timing guess.

Re-verification ("double check") surfaced a real bug this capacity
introduced: entity migration into a full target zone unsubbed from the
old zone *before* checking the new zone's capacity, so a migrating
entity into a full zone vanished entirely — silently dropped by
`Zone.sub`'s own capacity refusal, with no old-zone membership left to
recover it. Fixed by checking target capacity before touching the old
zone; if full, the whole move is refused and the entity stays exactly
where it was.

## Consequences

Good: worst-case per-zone cost is now bounded independently of whatever
the cost model's split threshold computes to; the migration-vanish bug
is fixed and covered by regression property tests
(`capacityFullMigrationPreservesEntityCheck`). Bad: a full zone now
structurally refuses new entities/migrations rather than growing to
accommodate them — a real gameplay-visible ceiling (256 concurrent
authoritative entities per zone) that must be respected by anything
sizing zone geometry or population density.
