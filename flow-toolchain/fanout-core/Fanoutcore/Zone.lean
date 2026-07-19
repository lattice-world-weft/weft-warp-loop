import Fanoutcore.SlotMap

namespace Fanoutcore

/- This module implements ADR 0008's Hilbert-curve zone-authority model
   fresh, inside fanout-core's own Lean4, rather than depending on
   v-sekai-multiplayer-fabric's `lean-interest-mgmt`/`lean-spatial-oracle`
   directly. Those repos' data model (`ZoneStateAI` with `RelReplica`/
   `VClock`/NoGod ReBAC formulas) is built for a much larger, more general
   fabric than this repo's flat slot-map `Room`; pulling in their real
   Lake dependency chain (5 packages plus a transitive AmoLean E-graph
   dependency) would not avoid the adaptation work an incompatible data
   model still requires, while adding real build/version-pinning surface
   this repo has consistently avoided elsewhere (fanout-core and
   sketch-core are this repo's own small kernels, not built on an
   upstream framework; libriscv/s7/picoquic are vendored as focused,
   self-contained pieces, never whole dependency graphs). This
   reimplements the *rule*, cited from the prior art, sized to
   fanout-core's actual model - revisit if `AuthorityInterest.lean`'s own
   proof changes upstream. -/

/-- A position in the fabric's coordinate space: absolute int64
    micrometers, no camera-relative origin shifting - matching the wire
    format `docs/decisions/0008-fiedler-scale-constants-and-fabric-interest-authority.md`
    describes (the lean-predictive-bvh lineage's own wire decision). -/
structure Pos3 where
  x : Int64
  y : Int64
  z : Int64
  deriving Repr, BEq, Inhabited

/-- Quantizes one signed micrometer axis into an unsigned `bits`-wide grid
    coordinate for Hilbert indexing. `Int64.toUInt64` is a lossless two's-
    complement reinterpretation (not an arithmetic add), which already
    biases the signed range into 0..UInt64.max in ascending order - exactly
    the property needed before dropping to the top `bits` bits. Positions
    closer together than the resulting cell size are indistinguishable to
    the curve; that is the intended granularity knob, not a bug. -/
def quantizeAxis (bits : Nat) (v : Int64) : UInt64 :=
  v.toUInt64 >>> (64 - bits).toUInt64

/-- Skilling's `AxesToTranspose` ("Programming the Hilbert Curve", J.
    Skilling, AIP Conf. Proc. 707, 2004 - the standard reference
    construction, also used by HEALPix), specialized to exactly 3 axes:
    converts three `bits`-wide unsigned grid coordinates into a
    `3*bits`-bit Hilbert curve distance. Separated from `hilbert3D` (which
    adds the `Int64` quantization step) so TestProps.lean can exhaustively
    verify it directly on raw grid coordinates - real bijectivity checked
    over a small grid, not the algorithm merely reproduced from memory and
    trusted. -/
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

/-- A zone's authority range along the 1D Hilbert curve: the half-open
    interval `[start, stop)` of curve indices this zone owns. Variable-
    length by design (ADR 0008): a Hilbert curve maps a 1D range to a
    spatially-coherent 3D region, but nothing requires equal-length
    ranges - a dense area splits into more, smaller ranges, a sparse one
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
    overlap - the invariant `authorityFor` needs so "the zone whose range
    contains a position is authoritative" (ADR 0008, citing zone-backend's
    own production rule verbatim) has a well-defined, unique answer rather
    than an ambiguous one. -/
def disjointRanges (rs : Array ZoneRange) : Bool :=
  (List.range rs.size).all fun i =>
    (List.range rs.size).all fun j =>
      i == j || !(ZoneRange.overlaps rs[i]! rs[j]!)

/-- A zone: its authority range, and the entities it currently simulates
    (analogous to `Room.subscribers`, but authority - one owner - not
    subscription - many). -/
structure Zone where
  range    : ZoneRange
  entities : Array UInt64
  deriving Repr, Inhabited

def Zone.sub (z : Zone) (connId : UInt64) : Zone :=
  if z.entities.contains connId then z else { z with entities := z.entities.push connId }

def Zone.unsub (z : Zone) (connId : UInt64) : Zone :=
  { z with entities := z.entities.filter (· != connId) }

/-- The zone whose range contains curve index `idx` is authoritative for
    whatever sits there. `none` if no zone's range covers that index - a
    legitimate state (e.g. a range not yet assigned by gossip), not an
    error to hide. Returns the first match by construction; under
    `disjointRanges`, at most one match ever exists (checked directly in
    TestProps.lean, separately from the Hilbert mapping). -/
def authorityForIndex (zones : Array Zone) (idx : UInt64) : Option Nat :=
  (List.range zones.size).find? fun i => (zones[i]!).range.contains idx

/-- The zone whose range contains `hilbert3D bits pos` is authoritative for
    an entity at that position (ADR 0008, citing zone-backend's own
    production rule verbatim). -/
def authorityFor (bits : Nat) (zones : Array Zone) (pos : Pos3) : Option Nat :=
  authorityForIndex zones (hilbert3D bits pos)

/-- The zones immediately adjacent to `zoneIdx` by curve order (the
    nearest-start zone whose range ends at-or-before `zoneIdx`'s start, and
    the nearest-start zone whose range starts at-or-after `zoneIdx`'s
    stop). A first, deliberately narrow approximation of `AOI_CELLS`-
    bounded interest (v-sekai-multiplayer-fabric/zone-backend's production
    rule): it bounds interest to curve-adjacent zones only. It does not
    (yet) do `AuthorityInterest.lean`'s fuller k-tick kinematic ghost
    expansion (`interestLookahead`/`ghostBound`) - that is later, separate
    work, not silently assumed equivalent here. -/
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
