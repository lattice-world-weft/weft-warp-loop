# Validate O(N+k) fanout scaling empirically, over porting the prior art's HilbertBroadphase

## Status

Accepted; validated, not implemented further (`ScaleScratch.lean`, a
benchmark script, not a property test or shipped mechanism).

## Decision

The prior art's `HilbertBroadphase` (radix sort + `clz30` grouping +
`BucketDir`) solves broadphase collision-pair detection over an
*unstructured* entity set recomputed from scratch every tick. This
system's entities aren't unstructured — zone membership
([ADR 0017](0017-hilbert-curve-zone-authority.md)) already updates
incrementally as each entity moves, so porting that mechanism would
duplicate work the existing spatial partition already does, not add new
capability. Instead of porting it speculatively, measured whether the
already-implemented split/merge + ghost-range machinery already
delivers near-linear total fanout cost: `ScaleScratch.lean` placed
100→4000 entities (a 40x increase) and measured `avgTargetsPerPublish`,
which stayed flat at 2-3 across the entire range — confirming O(N+k)
scaling without adding the broadphase port.

## Consequences

Good: avoided a real, substantial port (radix sort, `clz30` grouping, a
bucket directory — prior art built for a different problem shape) for a
property this codebase already had, once measured. Bad: this is an
empirical benchmark result (`ScaleScratch.lean`), not a property-tested
or formally proven bound — it demonstrates the measured shape held at
these population sizes, not a guarantee it holds at every future scale
or entity distribution; revisit if a future workload's fanout cost stops
looking flat.
