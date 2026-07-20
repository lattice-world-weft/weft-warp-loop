import Fanoutcore.SlotMap

namespace Fanoutcore

/- Implements ADR 0008's Hilbert-curve zone-authority model fresh, inside
   fanout-core's own Lean4, rather than depending on
   v-sekai-multiplayer-fabric's `lean-interest-mgmt`/`lean-spatial-oracle`
   directly. Those repos' data model (`ZoneStateAI` with `RelReplica`/
   `VClock`/NoGod ReBAC formulas) targets a much larger, more general
   fabric than this repo's flat slot-map `Room`; pulling in their Lake
   dependency chain (5 packages plus a transitive AmoLean E-graph
   dependency) wouldn't avoid the adaptation work an incompatible data
   model still requires, and would add build/version-pinning surface this
   repo avoids elsewhere (fanout-core and sketch-core are small kernels of
   their own, not built on an upstream framework; libriscv/s7/picoquic are
   vendored as focused, self-contained pieces, never whole dependency
   graphs). This reimplements the *rule*, cited from the prior art, sized
   to fanout-core's actual model. Revisit if `AuthorityInterest.lean`'s own
   proof changes upstream. -/

/-- A position in the fabric's coordinate space: absolute int64
    micrometers, no camera-relative origin shifting. Matches the wire
    format described in
    `docs/decisions/0008-fiedler-scale-constants-and-fabric-interest-authority.md`
    (the lean-predictive-bvh lineage's wire decision). -/
structure Pos3 where
  x : Int64
  y : Int64
  z : Int64
  deriving Repr, BEq, Inhabited

/-- Quantizes one signed micrometer axis into an unsigned `bits`-wide grid
    coordinate for Hilbert indexing. `Int64.toUInt64` is a lossless two's-
    complement reinterpretation, not an arithmetic add; it biases the
    signed range into 0..UInt64.max in ascending order, which is exactly
    the property needed before dropping to the top `bits` bits. Positions
    closer together than the resulting cell size are indistinguishable to
    the curve; that's the intended granularity knob, not a bug. -/
def quantizeAxis (bits : Nat) (v : Int64) : UInt64 :=
  v.toUInt64 >>> (64 - bits).toUInt64

/-- Skilling's `AxesToTranspose` ("Programming the Hilbert Curve", J.
    Skilling, AIP Conf. Proc. 707, 2004; the standard reference
    construction, also used by HEALPix), specialized to exactly 3 axes:
    converts three `bits`-wide unsigned grid coordinates into a
    `3*bits`-bit Hilbert curve distance. Separated from `hilbert3D` (which
    adds the `Int64` quantization step) so TestProps.lean can exhaustively
    verify bijectivity directly on raw grid coordinates over a small grid,
    rather than trusting the algorithm reproduced from memory. -/
def hilbertIndexOfGrid (bits : Nat) (px py pz : UInt64) : UInt64 := Id.run do
  let mut x := px
  let mut y := py
  let mut z := pz
  let m : UInt64 := (1 <<< (bits - 1)).toUInt64

  -- Inverse-undo pass: for each bit level (MSB to LSB), fold y and z
  -- toward the pivot axis x.
  let mut q := m
  while q > 1 do
    let p' := q - 1
    if x &&& q != 0 then
      x := x ^^^ p'
    if y &&& q != 0 then
      x := x ^^^ p'
    else
      let t := (x ^^^ y) &&& p'
      x := x ^^^ t
      y := y ^^^ t
    if z &&& q != 0 then
      x := x ^^^ p'
    else
      let t := (x ^^^ z) &&& p'
      x := x ^^^ t
      z := z ^^^ t
    q := q >>> 1

  -- Gray encode.
  y := y ^^^ x
  z := z ^^^ y

  -- Undo the excess Gray-encoding work above.
  let mut t : UInt64 := 0
  q := m
  while q > 1 do
    if z &&& q != 0 then
      t := t ^^^ (q - 1)
    q := q >>> 1
  x := x ^^^ t
  y := y ^^^ t
  z := z ^^^ t

  -- Interleave x/y/z bit-by-bit, MSB first, into the final linear index.
  let mut d : UInt64 := 0
  let mut k := bits
  while k > 0 do
    k := k - 1
    let kk := k.toUInt64
    d := (d <<< 1) ||| ((x >>> kk) &&& 1)
    d := (d <<< 1) ||| ((y >>> kk) &&& 1)
    d := (d <<< 1) ||| ((z >>> kk) &&& 1)
  return d

/-- Quantizes `p` into a `bits`-wide grid via `quantizeAxis`, then indexes
    it with `hilbertIndexOfGrid`. This is the position-space entry point
    other modules should call. -/
def hilbert3D (bits : Nat) (p : Pos3) : UInt64 :=
  hilbertIndexOfGrid bits (quantizeAxis bits p.x) (quantizeAxis bits p.y) (quantizeAxis bits p.z)

/-- k-tick kinematic ghost expansion, per axis (`AuthorityInterest.lean`'s
    `interestLookahead`, `Formula.lean`'s `expansion`): how far an entity
    moving at velocity `v` (μm/tick, magnitude) with half-acceleration
    `aHalf` (μm/tick², `⌈½|a|⌉` folded in by the caller at parse time, same
    convention as the prior art) could travel in `k` ticks: `v*k +
    aHalf*k^2`, the kinematic ½at² formula. This turns "same zone" from a
    blanket visibility proxy into predictive interest: an entity's ghost
    only needs to reach a neighbouring zone `k` ticks *before* it
    physically crosses, not react after the fact. -/
def ghostExpansion (v aHalf k : UInt64) : UInt64 :=
  v * k + aHalf * k * k

/-- Fallback lookahead (ticks) for an entity with no RTT sample yet (a
    freshly connected client, before picoquic has measured one).
    Matches `AuthorityInterest.lean`'s `interestLookahead` value ("a full
    RTT of lookahead" at that project's tick rate), used here only as a
    floor, not the real per-entity value: a fixed global lookahead doesn't
    adapt to actual client latency — a 20ms-ping and a 300ms-ping client
    need different lead time before a boundary crossing, and picoquic
    already measures real RTT per connection (`picoquic_get_rtt`), so
    there's no reason to guess with one constant once that measurement
    exists. -/
def defaultLookaheadTicks : UInt64 := 6

/-- Consecutive ticks a boundary-crossing entity's curve index must
    consistently point at the *same* neighbouring zone before authority
    actually transfers. This is `AuthorityInterest.lean`'s
    `hysteresisThreshold`, applied to curve-index authority: without it,
    an entity moving exactly along a zone boundary (players hugging a wall
    on a partition line, or floating-point/quantization jitter at rest
    near one) would migrate every tick it's evaluated, thrashing zone
    membership and the fanout targets computed from it.

    Not a fixed constant — that was `defaultLookaheadTicks`'s original
    mistake, corrected here for the same reason: how many ticks a single
    stray/jittery position sample can plausibly span depends on how often
    this entity's position actually updates, which is exactly what
    `EntityRecord.lookaheadTicks` (RTT-derived) measures. A high-RTT
    entity's samples arrive less often, so a single jitter event can look
    like it "persists" across more evaluated ticks than a low-RTT entity's
    would; it needs a longer streak to tell a real crossing from one stale
    sample. Half the entity's own lookahead window, floored at 1 tick:
    long enough to absorb a single stray sample, short enough that a
    genuine crossing still commits within that entity's own ghost horizon
    (`withinGhostRange` already projects `lookaheadTicks` ahead of the
    actual crossing, so committing authority in under that many ticks
    keeps the receiving zone's ghost coverage ahead of, not behind, the
    transfer). -/
def hysteresisTicksFor (lookaheadTicks : UInt64) : UInt64 :=
  max 1 (lookaheadTicks / 2)

/-- Per-axis absolute distance between two signed micrometer coordinates. -/
def axisDist (a b : Int64) : UInt64 :=
  if a >= b then (a - b).toUInt64 else (b - a).toUInt64

/-- True iff a publish from an entity at real position `pubPos` could
    plausibly reach an entity at `targetPos` within *each entity's own*
    lookahead window (`pubK`/`targetK` — typically each side's own
    `EntityRecord.lookaheadTicks`, not a single shared value: a low-
    latency publisher and a high-latency target each need their own ghost
    radius evaluated over their own real RTT, not one side's borrowed onto
    the other).

    Compares per-axis real distance in micrometres (`AuthorityInterest.
    lean`'s `overlapsAxis` check), not curve-index distance. Curve-index
    distance was tried and found to be a measured bug: at this project's
    `zoneBits = 21` quantization, one curve-index unit represents roughly
    8800km, so a realistic ghost expansion (even a 10m/s sprint over 6
    ticks, 60m) always rounds to *zero* curve-index units, silently
    excluding every adjacent-zone entity regardless of real proximity.
    Curve-index distance is the established proxy for spatial locality
    elsewhere (zone partitioning), but it's far too coarse a unit for a
    ghost-expansion distance orders of magnitude smaller than one grid
    cell.

    The check passes if the real distance is within *either* entity's own
    per-axis ghost expansion, whichever is due to move fast enough to
    close the gap (a stationary target can still be reached by a fast-
    moving publisher, and vice versa; matches `overlapsAxis`'s own `pos -
    expand <= zMax && pos + expand >= zMin` shape). Replaces "same
    zone/adjacent zone = always interested" (the previous blanket
    visibility model) with genuine predictive interest: an entity only
    receives a ghost/publish from something that could actually reach it
    within its own lookahead window, not everything that happens to share
    a zone. -/
def withinGhostRange (pubPos : Pos3) (pubVx pubVy pubVz pubK : UInt64) (targetPos : Pos3) (targetVx targetVy targetVz targetK : UInt64) : Bool :=
  let pubExX := ghostExpansion pubVx 0 pubK
  let pubExY := ghostExpansion pubVy 0 pubK
  let pubExZ := ghostExpansion pubVz 0 pubK
  let targetExX := ghostExpansion targetVx 0 targetK
  let targetExY := ghostExpansion targetVy 0 targetK
  let targetExZ := ghostExpansion targetVz 0 targetK
  axisDist pubPos.x targetPos.x <= pubExX + targetExX &&
  axisDist pubPos.y targetPos.y <= pubExY + targetExY &&
  axisDist pubPos.z targetPos.z <= pubExZ + targetExZ

/-- A zone's authority range along the 1D Hilbert curve: the half-open
    interval `[start, stop)` of curve indices this zone owns. Variable
    length by design (ADR 0008): a Hilbert curve maps a 1D range to a
    spatially-coherent 3D region, but nothing requires equal-length
    ranges — a dense area splits into more, smaller ranges, a sparse one
    merges into fewer, larger ones, unlike a fixed uniform grid. -/
structure ZoneRange where
  start : UInt64
  stop  : UInt64 -- exclusive
  deriving Repr, BEq, Inhabited

def ZoneRange.contains (r : ZoneRange) (idx : UInt64) : Bool :=
  r.start <= idx && idx < r.stop

/-- Two half-open ranges overlap iff each one's start lies before the
    other's stop. -/
def ZoneRange.overlaps (a b : ZoneRange) : Bool :=
  a.start < b.stop && b.start < a.stop

/-- A set of zone ranges is disjoint iff no two distinct ranges in it
    overlap. This is the invariant `authorityFor` needs so "the zone whose
    range contains a position is authoritative" (ADR 0008, citing
    zone-backend's production rule) has a well-defined, unique answer. -/
def disjointRanges (rs : Array ZoneRange) : Bool :=
  (List.range rs.size).all fun i =>
    (List.range rs.size).all fun j =>
      i == j || !(ZoneRange.overlaps rs[i]! rs[j]!)

/-- One entity's authority record: connId, its curve index (for authority
    range lookups), its velocity magnitude per axis (micrometres/tick,
    *absolute value*, matching `AuthorityInterest.lean`'s convention: k-
    tick ghost expansion (`Formula.lean`'s `expansion v a_half k := v*k +
    a_half*k*k`) only needs how far something could move, not which
    direction, so a signed velocity would just be extra information the
    formula immediately discards via `abs`. Zero velocity, the default
    before any `entityMoveV`-style call updates it, means zero ghost
    expansion: an entity with no known velocity is treated as stationary,
    not unbounded), and its lookahead window in ticks (`rttTicks`, sourced
    from the connection's measured RTT — picoquic already tracks this per
    connection — converted to ticks at the FFI boundary by the caller, not
    derived here, keeping this module's arithmetic in one unit system,
    matching `Shared/Types.lean`'s "convert at the FFI boundary"
    convention). `0` means no RTT sample yet (a freshly connected entity)
    and falls back to `defaultLookaheadTicks` rather than zero lookahead:
    an entity with unknown latency should get *more* lead time until
    proven otherwise, not none. -/
structure EntityRecord where
  connId   : UInt64
  idx      : UInt64
  pos      : Pos3 := { x := 0, y := 0, z := 0 }
  vx       : UInt64 := 0
  vy       : UInt64 := 0
  vz       : UInt64 := 0
  rttTicks : UInt64 := 0
  /-- The zone id this entity's `idx` currently points at, when that
      differs from the zone actually simulating it (`none` while the
      entity's `idx` still agrees with its own current zone). This is
      `AuthorityInterest.lean`'s `MigrationState` staging concept, sized
      down to just "which candidate, if any": an entity oscillating on a
      boundary keeps resetting this to the same candidate zone (streak
      keeps counting), while one that crosses back and forth between two
      different neighbours resets the streak from scratch each time it
      changes its mind (see `migrationStreak`). -/
  pendingZone : Option Id := none
  /-- Consecutive `moveEntityToIndexHysteresisV` calls in a row where the
      entity's `idx` has pointed at `pendingZone` without reverting to its
      current zone or flipping to a third candidate. Authority transfer
      only commits once this reaches `hysteresisThreshold`
      (`AuthorityInterest.lean`'s `hysteresisThreshold`, applied here to
      curve-index authority instead of that project's AABB-overlap
      authority). -/
  migrationStreak : UInt64 := 0
  deriving Repr, BEq, Inhabited

/-- `rec.rttTicks`, or `defaultLookaheadTicks` if no RTT sample is known
    yet (`rttTicks = 0`, the `EntityRecord` default). -/
def EntityRecord.lookaheadTicks (rec : EntityRecord) : UInt64 :=
  if rec.rttTicks == 0 then defaultLookaheadTicks else rec.rttTicks

/-- A zone: its authority range, and the entities it currently simulates
    (analogous to `Room.subscribers`, but authority — one owner — rather
    than subscription — many). Each entity's last-known curve index and
    velocity are carried alongside its connId, not just the connId alone
    as before E-GOSSIP: splitting a zone needs to know which side of a new
    boundary each existing entity falls on, and ghost expansion needs
    velocity; nothing else in the system otherwise tracks either once
    `moveEntity` has filed an entity into a zone. -/
structure Zone where
  range    : ZoneRange
  entities : Array EntityRecord
  deriving Repr, Inhabited

/-- Hard ceiling on one zone's live authority membership
    (`AuthorityInterest.lean`'s `cap-headroom`), independent of and on top
    of cost-driven splitting (`Partition.lean`'s `splitIsCheaper`).
    Splitting bounds population in the common case by giving a dense zone
    more, smaller children, but it bottoms out at `octreeMaxDepth` (a
    single curve-index cell, `Zone.lean`'s own quantization granularity),
    so however many entities land in the exact same cell — or close enough
    that no further split ever separates them: a stationary crowd, a
    coordinate clamp bug on some client, deliberate abuse — have nowhere
    left to split into. This is a resource-safety ceiling, not a value
    math could derive from per-connection data (unlike
    `hysteresisTicksFor`/RTT-derived lookahead, it doesn't vary per entity
    or improve with better measurement — it exists so one degenerate cell
    can't grow this zone's `Θ(population^2)` fanout cost or entity-array
    size without bound), the same role `SlotMap`'s fixed `capacity` plays
    for room/zone allocation itself. Not derived from any measured load
    yet: large enough that ordinary crowding (this project's
    `ScaleScratch.lean` benchmark measured max 5 in a well-split zone)
    never comes close, small enough to still bound worst-case cost to
    something sub-catastrophic. -/
def authorityCapacity : Nat := 256

/-- Hard ceiling on how many *interest* (adjacent-zone, ghost-range)
    targets a single publish fans out to. This is `AuthorityInterest.
    lean`'s `InterestCapacity` (that project's value: 400, validated at
    production scale against VRChat's Kaguya concert), reused directly
    since interest-list size is the same kind of message-fanout safety
    bound at any project's scale, unlike `authorityCapacity` which is
    specific to this project's cost model. Applies only to the interest
    portion of `targetsForIndex`'s result, not authority membership
    (already separately bounded by `authorityCapacity`); the same
    authority/interest separation `AuthorityInterest.lean` keeps
    independently budgeted. -/
def interestCapacity : Nat := 400

def Zone.sub (z : Zone) (rec : EntityRecord) : Zone :=
  if z.entities.any (·.connId == rec.connId) then z
  else if z.entities.size >= authorityCapacity then z
  else { z with entities := z.entities.push rec }

def Zone.unsub (z : Zone) (connId : UInt64) : Zone :=
  { z with entities := z.entities.filter (·.connId != connId) }

/-- The zone whose range contains curve index `idx` is authoritative for
    whatever sits there. `none` if no zone's range covers that index — a
    legitimate state (e.g. a range not yet assigned by gossip), not an
    error to hide. Returns the first match by construction; under
    `disjointRanges`, at most one match ever exists (checked directly in
    TestProps.lean, separately from the Hilbert mapping). -/
def authorityForIndex (zones : Array Zone) (idx : UInt64) : Option Nat :=
  (List.range zones.size).find? fun i => (zones[i]!).range.contains idx

/-- The zone whose range contains `hilbert3D bits pos` is authoritative for
    an entity at that position (ADR 0008, citing zone-backend's production
    rule verbatim). -/
def authorityFor (bits : Nat) (zones : Array Zone) (pos : Pos3) : Option Nat :=
  authorityForIndex zones (hilbert3D bits pos)

/-- The zones immediately adjacent to `zoneIdx` by curve order: the
    nearest-start zone whose range ends at-or-before `zoneIdx`'s start,
    and the nearest-start zone whose range starts at-or-after `zoneIdx`'s
    stop. A first, deliberately narrow approximation of `AOI_CELLS`-
    bounded interest (v-sekai-multiplayer-fabric/zone-backend's production
    rule) that bounds interest to curve-adjacent zones only. Doesn't
    (yet) implement `AuthorityInterest.lean`'s fuller k-tick kinematic
    ghost expansion (`interestLookahead`/`ghostBound`) — that's later,
    separate work, not silently assumed equivalent here. -/
def adjacentZones (zones : Array Zone) (zoneIdx : Nat) : Array Nat := Id.run do
  if h : zoneIdx < zones.size then
    let target := zones[zoneIdx]
    let mut before : Option Nat := none
    let mut beforeStop : UInt64 := 0
    let mut after : Option Nat := none
    let mut afterStart : UInt64 := 0xFFFFFFFFFFFFFFFF
    for i in List.range zones.size do
      if i != zoneIdx then
        let z := zones[i]!
        if z.range.stop <= target.range.start && z.range.stop > beforeStop then
          before := some i
          beforeStop := z.range.stop
        if z.range.start >= target.range.stop && z.range.start < afterStart then
          after := some i
          afterStart := z.range.start
    let mut result : Array Nat := #[]
    match before with
    | some i => result := result.push i
    | none => pure ()
    match after with
    | some i => result := result.push i
    | none => pure ()
    return result
  else
    return #[]

end Fanoutcore
