# Adopt mas-bandwidth-scale player/world-server constants and the fabric's interest/authority model

## Status

Proposed (design record only; no code changes accompany this ADR).

## Context and Problem Statement

The near-term target is 1,000 players; the reference architecture cited
for sizing it is Glenn Fiedler's "Creating a first person shooter that
scales to millions of players"
(https://mas-bandwidth.com/creating-a-first-person-shooter-that-scales-to-millions-of-players/),
sized for 1,000,000 players — a 1000x larger deployment. The user's own
call: use Fiedler's raw constants as-written, not scaled-down versions,
even though this repo's near-term target is smaller. Separately, this
repo already shares one concrete number with that architecture by
construction, not coincidence: `picoquic_fanout_server.actor.cpp`'s
`kEntityPacketSize = 100` (`lean-entity-packet`'s fixed wire size) is the
same "100 bytes shallow player state for interpolation and display"
Fiedler's article specifies. That shared ancestry is the sibling
`v-sekai-multiplayer-fabric` org's own wire-format decisions
(`multiplayer-fabric-manuals`'s
`20260612-integral-entity-transform-wire.md`: "the packet keeps its 100
bytes"), not this repo re-deriving the number independently.

This repo's current interest model is flat: `fanout-core`'s `Room` is a
plain subscriber list over a topic, with no spatial concept at all — any
subscriber gets every publish for a room, unconditionally. Fiedler's
architecture and `v-sekai-multiplayer-fabric`'s own prior Lean4 work
(`lean-predictive-bvh`, `lean-interest-mgmt`/`lean-spatial-oracle`) both
depend on a real interest/authority separation this repo doesn't have
yet: which zone *simulates* an entity (authority) versus which
zones/clients merely *observe* it (interest), bounded by a spatial
structure, not a flat per-topic broadcast.

## The constants (Fiedler's, as specified, not rescaled)

Per-machine / per-server capacity:

- **8,000 players per "player server"** (client-connection-terminating
  layer), on a 32-CPU bare-metal machine — 250 players per CPU.
- **10,000 players per "world server"** (simulation layer) — a
  1,000,000-player world divided into a 10km×10km grid at 1km² per cell
  needs 100 world servers; 1,000,000 ÷ 100 = 10,000 players' worth of
  state flowing through each one. A world server's player count is a
  state-volume figure, not a concurrent-connection figure — it's driven
  by how many players' state a given spatial cell needs to track, not by
  how many sockets one process holds open.

Per-player protocol constants (independent of total player count —
these size the wire format and tick rate this repo already partly
shares):

- **100Hz input rate**, batched **10 inputs per packet**, **100 bytes**
  per input packet.
- **100 bytes "shallow" state** (interpolation/display — the number
  this repo's `kEntityPacketSize` already matches) and **1,000 bytes
  "deep" state** (sent back only to the owning client).
- **1 second** mandatory history buffer, **10 seconds** optional
  history (Fiedler's example: 1 GB at that retention depth).
- **~1 Gbps per world server** before delta compression, **~100 Mbps**
  after (an order-of-magnitude reduction Fiedler assumes is achievable).

## The fabric's interest/authority model (already proven elsewhere, not reinvented here)

`v-sekai-multiplayer-fabric/zone-backend`'s own production rule,
verbatim from `lib/uro/controllers/zone.ex`: "The zone whose Hilbert
curve range contains `hilbert3D(pos)` is authoritative for any entity at
that position. Authority is the only zone that executes
`CMD_INSTANCE_ASSET`." Neighbouring zones within `AOI_CELLS` (an
area-of-interest cell radius) receive a `CH_INTEREST` ghost instead of
re-fetching or re-simulating — interest is strictly read-only
observation, never a second authority. Both the Hilbert-curve zone
assignment and the interest bounds are formally proved in Lean4
(`multiplayer-fabric-predictive-bvh`/`PredictiveBVH.lean`,
now split into `lean-predictive-bvh` per
`multiplayer-fabric-manuals`'s `20260612-vertical-slice-repository-map.md`).
Exercised at small scale already: `multiplayer-fabric-manuals`'s
`20260506-maglev-cycle-10-dynamic-physics-score.md`/
`20260506-maglev-intercept-smoke-test.md` — 16 moving clients, the
predictive BVH computing at least 2 distinct interest zones, verified in
`zone-console`. Full cross-zone interest management (multiple zone
servers simultaneously) is explicitly noted there as left for a later
cycle — i.e., proven at the single-shard-boundary scale, not yet at the
"100 world servers" scale these constants imply.

One refinement Fiedler's article doesn't need but this repo's own
reference does: Fiedler's "100 world servers" comes from a *uniform*
grid (10km×10km at 1km² per cell — equal-size cells, so equal
server count follows directly from world area). The fabric's actual
mechanism is not a fixed grid: `zone-backend`'s own invariant is
`ZoneRange.contains(hilbert3D(pos))` — authority is assigned as a
*range* along the 1D Hilbert curve, gossip-learned, proven disjoint
under `DisjointRanges` (`_archive/decisions/20260506-maglev-cycle-11-db-write.md`,
`20260506-maglev-intercept-smoke-test.md`). A Hilbert curve maps a 1D
range to a spatially-coherent 3D region (locality-preserving), but nothing
requires those ranges to be equal length. This means server/zone count
and boundary don't have to track fixed geometry the way Fiedler's
uniform grid does — a dense area can be split into more, smaller ranges
(more world servers covering less space, each still under the
10,000-player figure) and a sparse area merged into fewer, larger ones,
with the split/merge decision driven by measured player density rather
than a pre-drawn map. "100 world servers" is Fiedler's answer for a
uniform world; this repo's actual mechanism can converge on a different
count for the same total player load, redistributed as load shifts,
without invalidating the Hilbert-authority or `AOI_CELLS`-interest
invariants themselves (both are defined in terms of curve position and
range membership, not cell geometry).

The predictive BVH itself (per `multiplayer-fabric-manuals`'s
`20260622-deck-log.md` and `20260612-integral-entity-transform-wire.md`):
R128 fixed-point coordinates with ghost expansion (AABBs grown by
velocity, scaled to `PBVH_V_MAX_PHYSICAL_DEFAULT`, so the same units the
100-byte wire packet's i16 velocity field already uses), SAH
construction, and a Hilbert-curve broadphase — codegen'd to a C header
(`predictive_bvh.h`) through "AmoLean" for consumption outside Lean.
Position on the wire is int64 absolute micrometers (no camera-relative
origin shifting — both the double-precision build and R128 exist
specifically to hold true absolute coordinates); the authoritative
position stays R128 server-side, the wire form is its integer
projection, and clients render rather than re-simulate (server
authority, deferred rollback per that same manuals repo).

## Decision Outcome

Recorded as the target architecture, not implemented in this pass:

1. **Constants**: adopt Fiedler's numbers above as this repo's own
   sizing reference, unscaled, per the user's explicit choice — a
   "world server" here is sized for up to 10,000 players' worth of
   simulated state, a "player server" (this repo's Elixir/OTP hub layer)
   for up to 8,000 concurrent connections per 32-CPU machine. Unlike
   Fiedler's uniform-grid illustration, "10,000 players per world
   server" is a per-Hilbert-range capacity ceiling, not a per-fixed-cell
   one — the fabric's `DisjointRanges`-proven, gossip-learned zone
   assignment can redraw range boundaries to keep any one world server
   under that ceiling as player density shifts, rather than requiring a
   fixed count of equal-size zones up front.
2. **Interest/authority separation**: `fanout-core`'s flat per-topic
   `Room` broadcast is not this repo's end state for spatial gameplay —
   the fabric's own proven model (Hilbert-curve zone authority,
   `AOI_CELLS`-bounded `CH_INTEREST` ghosting, one authority per entity)
   is the intended replacement, reusing `lean-predictive-bvh`'s existing
   Lean4 proofs rather than re-deriving them in this repo's own Lean4
   kernels (`fanout-core`, `sketch-core`).
3. **Wire format**: this repo's existing 100-byte `kEntityPacketSize`
   already matches Fiedler's shallow-state number and the fabric's own
   wire decision — no change needed there; a "deep state" (1000-byte)
   channel back to the owning client and the int64-micrometer/R128
   position split are not yet present in this repo and would need to be
   added to extend beyond the current flat broadcast.

### Consequences

- Good: this repo doesn't need to re-derive spatial interest management
  or its formal proofs — `lean-predictive-bvh` already exists, is
  already proven at small scale, and already shares this repo's own
  100-byte wire convention.
- Good: the constants give concrete sizing targets for the "fabric of
  N-player world servers" question, grounded in a real published
  architecture rather than picked arbitrarily.
- Bad: real gap between what's proven (`lean-predictive-bvh` at 16
  clients, 2 interest zones, single shard boundary) and what these
  constants imply (100 world servers, cross-zone interest at that
  scale) — the manuals repo's own notes flag full cross-zone interest
  management as future work there too, not a solved problem being
  imported wholesale.
- Bad: `fanout-core`'s current topic-broadcast model and a future
  Hilbert-authority/BVH-interest model are different enough that
  adopting the latter is a real redesign of the pub/sub layer, not an
  additive change - scoping that redesign is not done in this ADR.
- Bad: the 8,000/10,000-player-per-machine figures assume Fiedler's own
  bare-metal/bandwidth/CPU assumptions hold for this project's actual
  hardware and protocol overhead, which haven't been independently
  measured here.
