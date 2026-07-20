# Adopt mas-bandwidth-scale player/world-server constants and the fabric's interest/authority model

## Status

Constants: adopted as a sizing reference (capacity ceilings, not yet
load-bearing). Interest/authority separation: implemented, as a
from-scratch reimplementation of this ADR's *rule* inside `fanout-core`'s
own Lean4 — see "Implementation update" below for what shipped (not a
port of `lean-predictive-bvh`/`lean-interest-mgmt` — see
[ADR 0009](0009-reserved-witness-zones-for-cross-machine-lease-authority.md)
for why that dependency wasn't kept).

## Decision

The near-term target is 1,000 players; the sizing reference is Glenn
Fiedler's "Creating a first person shooter that scales to millions of
players" (mas-bandwidth.com), sized for 1,000,000 — 1000x this repo's
near-term target. Per the user's explicit call, Fiedler's constants are
adopted as-written, not scaled down: 8,000 players per player-server
(connection layer, on a 32-CPU machine), 10,000 players per world-server
(simulation layer — a state-volume figure, not a connection-count one),
100Hz input at 10 inputs/packet/100 bytes, 100-byte "shallow" state
(already matched by this repo's `kEntityPacketSize`) plus 1,000-byte
"deep" state to the owning client only, 1s mandatory / 10s optional
history, ~1 Gbps per world server before delta compression (~100 Mbps
after).

`fanout-core`'s interest model was flat (`Room` = unconditional
per-topic broadcast, no spatial concept). The sibling
`v-sekai-multiplayer-fabric` org's own production rule (`zone-backend`'s
`lib/uro/controllers/zone.ex`) is adopted as the replacement model
instead of reinventing one: the zone whose Hilbert-curve range contains
an entity's position is its sole authority; neighboring zones within an
area-of-interest radius get a read-only `CH_INTEREST` ghost, never a
second authority — both proved in Lean4 elsewhere in that org
(`lean-predictive-bvh`) and exercised at small scale (16 clients, 2
interest zones), with full cross-zone interest at fleet scale explicitly
left as future work there too. Unlike Fiedler's uniform grid, the
fabric's Hilbert ranges aren't fixed-size — dense areas split into more,
smaller ranges and sparse areas merge, driven by measured density, while
keeping every world server under the 10,000-player ceiling.

## Consequences

Good: no need to re-derive spatial interest management or its proofs
from scratch; concrete sizing targets grounded in a published
architecture rather than picked arbitrarily. Bad: a real gap exists
between what's proven elsewhere (16 clients, single shard) and what
these constants imply (100 world servers, fleet-scale cross-zone
interest); adopting the Hilbert-authority/interest model is a real
pub/sub redesign, not scoped here; the 8,000/10,000-per-machine figures
assume Fiedler's own hardware/bandwidth assumptions, unmeasured on this
project's actual stack.

## Implementation update

Implemented inside `fanout-core`'s own Lean4 (not a port of
`lean-predictive-bvh` — see ADR 0009 for why that dependency wasn't
kept):

- Hilbert-curve zone authority (`Zone.lean`'s `hilbert3D`/
  `authorityForIndex`), proven disjoint and unique.
- AV1-style cost-driven split/merge (`Partition.lean`/
  `ZoneDispatch.lean`, this project's own `Θ(k²)` cost, not the prior
  art's ray-tracing SAH).
- Ghost-range interest (`withinGhostRange`, k-tick kinematic
  `ghostExpansion`) filtering by real per-axis micrometre distance, not
  curve-index distance — a real scale bug in curve-index distance was
  found and fixed before shipping.
- RTT-derived lookahead per connection (`picoquic_get_rtt` converted to
  ticks at the FFI boundary), never one fixed constant.
- Hysteresis-gated authority transfer (`moveEntityToIndexHysteresisV`)
  requiring a boundary crossing to persist for an RTT-derived tick count
  before authority moves.
- Capacity-separated budgets: `authorityCapacity` (256) and
  `interestCapacity` (400, matching `AuthorityInterest.lean`'s
  validated value), bounding worst-case cost independently of
  cost-driven splitting.
- O(N+k) scaling empirically validated (`ScaleScratch.lean`: flat
  average fanout across a 40x population increase) — decided against
  porting the prior art's `HilbertBroadphase`, since it solves
  broadphase over an unstructured entity set recomputed each tick, and
  this system's zone membership already updates incrementally.
- Wire protocol: `ZPB` carries real velocity end to end, verified live
  up to 128 concurrent connections.

Not yet done: wire-level zone provisioning (still direct FFI, no wire
verb); `fanout_load_client`'s ZPB sends still report zero velocity.
