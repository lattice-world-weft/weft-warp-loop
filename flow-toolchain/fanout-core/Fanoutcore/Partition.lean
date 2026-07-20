import Fanoutcore.Zone

namespace Fanoutcore

/- AV1-style symmetric split/merge for zone authority, adapted from
   v-sekai-multiplayer-fabric/lean-spatial-oracle's
   `PredictiveBvh/core/Partition.lean` + `Shared/Types.lean`'s `PartitionNode`/
   `EClass`/`SpatialEGraph`. What transfers directly: the octree-cell math (a
   `ZoneRange` at Hilbert depth `bits` *is* an octree cell: `hilbertIndexOfGrid`
   interleaves exactly 3 bits per level, so every 3 bits of curve index consumed
   from the top is one octree level, matching that repo's `clz30`/
   `cellWidthNorm` depth arithmetic), and the *structure* of a symmetric
   split-vs-stay-merged cost comparison (their `PartitionNode.none_split` vs
   `.oct`, compared via one cost evaluator, not a separate bolted-on merge
   pass). What does NOT transfer: their cost function itself
   (`predictiveSAH := bvhTraversalCost * surfaceArea bounds`) targets ray-BVH
   traversal cost (spatial compactness), not this project's objective.
   `targetsForIndex`'s real cost is `Θ(K^2)` in a zone's own population (proven
   by this project's O(N^3) regression, fixed in ZoneDispatch.lean's
   `targetsForIndex` doc comment), so the cost function here is population-
   based, not surface-area-based: it reuses their split vocabulary and octree
   depth math, not their ray-tracing-specific heuristic. -/

/-- This zone-world's Hilbert quantization depth in octree levels: `bits` per
    axis (Zone.lean's `hilbert3D`/`quantizeAxis`) interleaves to `3*bits` bits
    total, so there are exactly `bits` octree levels from the root (depth 0,
    the full `[0, 2^(3*bits))` range) down to a single-point cell (depth
    `bits`). -/
def octreeMaxDepth (bits : Nat) : Nat := bits

/-- The octree depth of a `ZoneRange`, if it is a valid, aligned octree cell
    at this Hilbert quantization: its length must be `2^(3*(bits-d))` for some
    `d`, and its start must be a multiple of that length. `none` for a range
    that isn't octree-aligned (e.g. this project's earlier `maybeSplitZone`,
    which bisected at an arbitrary midpoint rather than along real octree
    boundaries, the correctness gap this module exists to fix). -/
def zoneRangeDepth (bits : Nat) (r : ZoneRange) : Option Nat := Id.run do
  let len := r.stop - r.start
  if len == 0 then return none
  -- Find d such that len = 2^(3*(bits-d)), i.e. len's bit-length is a
  -- multiple of 3 and within [0, 3*bits].
  let mut levelsFromLeaf := 0
  let mut rem := len
  while rem > 1 && rem % 2 == 0 do
    rem := rem / 2
    levelsFromLeaf := levelsFromLeaf + 1
  if rem != 1 || levelsFromLeaf % 3 != 0 then
    return none
  let octreeLevelsFromLeaf := levelsFromLeaf / 3
  if octreeLevelsFromLeaf > bits then return none
  let d := bits - octreeLevelsFromLeaf
  -- Alignment: start must be a multiple of len.
  if r.start % len != 0 then return none
  return some d

/-- The 8 equal child ranges of an octree-aligned `ZoneRange` one level down
    (depth `d+1`), in Hilbert curve order. The 8-way analogue of
    `maybeSplitZone`'s old 2-way midpoint bisection, now along real octree
    boundaries instead of an arbitrary split. `none` if `r` is already at
    `octreeMaxDepth bits` (a single-point cell, per `maybeSplitZone`'s
    original "a range of length 1 cannot be split further" floor) or isn't a
    valid octree cell to begin with. -/
def octreeChildren (bits : Nat) (r : ZoneRange) : Option (Array ZoneRange) := do
  let d ← zoneRangeDepth bits r
  if d >= octreeMaxDepth bits then none
  else
    let childLen := (r.stop - r.start) / 8
    some (Array.range 8 |>.map fun i =>
      { start := r.start + i.toUInt64 * childLen, stop := r.start + (i.toUInt64 + 1) * childLen })

/-- Population-based leaf cost: `Θ(K^2)` in this zone's own live entity count,
    matching `targetsForIndex`'s real per-tick fanout cost for a zone with no
    further split (every entity's publish reaches every other entity in the
    same zone). This project's own cost function, not the prior art's
    ray-tracing `predictiveSAH`; see this file's header comment. -/
def leafCost (population : Nat) : Nat := population * population

/-- The fixed overhead of maintaining one additional zone as a live,
    independently-scheduled unit (SlotMap slot, its own authority bookkeeping):
    the cost that must be paid back by a split's reduced leaf costs for the
    split to be worthwhile. Charged once per child a split creates (8 for a
    full octree split), matching `PartitionNode`'s `bvhTraversalCost *
    surfaceArea parent` traversal-step charge in shape (a cost paid for
    visiting/maintaining the split structure itself, not the leaves), sized
    for this project's unit (population count) rather than surface area. -/
def zoneOverhead : Nat := 1

/-- True iff splitting a zone of `population` entities into `childPopulations`
    (the population each of the 8 children would hold after redistribution)
    is cost-favourable: sum of child leaf costs plus per-child overhead is
    strictly less than staying merged as one leaf. This is the one symmetric
    decision `PartitionNode.none_split` vs `.oct` reduces to for this
    project's cost function: split and merge are the same comparison,
    evaluated from either direction, not two separate mechanisms. -/
def splitIsCheaper (population : Nat) (childPopulations : Array Nat) : Bool :=
  let splitCost := (childPopulations.map fun c => leafCost c + zoneOverhead).foldl (· + ·) 0
  splitCost < leafCost population

end Fanoutcore
