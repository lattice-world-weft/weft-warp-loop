# Ghost-range interest filters by real per-axis distance, not curve-index distance

## Status

Accepted; implemented (`Zone.lean`'s `withinGhostRange`/`ghostExpansion`/
`axisDist`; a real scale bug found and fixed before shipping).

## Decision

Blanket zone-membership visibility (any entity in an adjacent zone is
visible) over-shares at scale. Adopted k-tick kinematic ghost expansion
instead: `ghostExpansion := v*k + aHalf*k²`, per-axis, using each
entity's own RTT-derived lookahead ([ADR 0020](0020-rtt-derived-hysteresis-no-fixed-delays.md))
as `k` — an entity is visible to an observer only if their real
micrometre distance on every axis (`axisDist`) is within the observer's
kinematically-expanded range, not merely because both happen to sit in
adjacent zones.

The first implementation measured distance in Hilbert curve-index space
instead of real per-axis micrometre distance — a real scale bug, since
curve-index adjacency doesn't linearly track spatial adjacency at scale
(the Hilbert curve is locality-preserving on average, not distance-
preserving pointwise). Found and fixed before shipping, replaced with
`axisDist`'s direct per-axis signed-coordinate subtraction.

## Consequences

Good: interest visibility now tracks real kinematic reachability, not
an artifact of the curve used for authority assignment — an entity's
visibility set is independent of which zone-partitioning scheme is in
use. Bad: `axisDist` is Int64 subtraction on signed micrometre
coordinates — extreme-value overflow was an identified but not yet
property-tested risk at the time of the original scale-bug fix; worth a
dedicated property test if entity coordinates ever approach Int64's
range in practice.
