-- Property tests for the fanout-core kernel (Plausible, QuickCheck-style).
--
-- The heart is model-based: random operation sequences (alloc / free /
-- update / adversarial garbage ids) run against both the real SlotMap and a
-- trivially-correct model (a flat list of live (id, value) pairs); after
-- every step the two must agree on `find` for every id ever observed. On
-- top of that, allocation freshness (a returned id never equals any id
-- returned before, the generational guarantee) and full-capacity behavior
-- are asserted inline, and Room's fanout algebra is checked directly.
import Fanoutcore.FanoutCore
import Fanoutcore.Zone
import Fanoutcore.Partition
import Fanoutcore.ZoneDispatch
import Plausible

open Fanoutcore Plausible

/-- Simulation state: the real map, the model, and the id sets used for
    checking. `allocated` is every id `alloc` ever returned; `observed`
    additionally includes synthesized garbage ids. -/
structure Sim where
  map       : SlotMap Nat
  model     : List (Id × Nat)
  allocated : List Id
  observed  : List Id
  ok        : Bool

/-- The core agreement invariant: real map and model see the same value (or
    same absence) for every id we have ever touched. -/
def checkConsistent (s : Sim) : Bool :=
  s.observed.all fun id =>
    match s.map.find id, s.model.find? (fun e => e.1 == id) with
    | some v, some (_, mv) => v == mv
    | none, none => true
    | _, _ => false

def addObserved (l : List Id) (id : Id) : List Id :=
  if l.contains id then l else l ++ [id]

/-- One decoded operation. `(code, a, b)`: code selects the op, `a`/`b`
    are its arguments (index into observed ids, value, or garbage bits). -/
def step (cap : Nat) (s : Sim) (op : Nat × Nat × Nat) : Sim :=
  if !s.ok then s
  else
    let (code, a, b) := op
    let s' :=
      match code % 4 with
      | 0 => -- alloc
        match s.map.alloc a with
        | some (m', id) =>
          -- Generational freshness: never re-issue any previously returned id.
          let fresh := !(s.allocated.contains id)
          { s with
            map := m'
            model := (id, a) :: s.model
            allocated := s.allocated ++ [id]
            observed := addObserved s.observed id
            ok := s.ok && fresh }
        | none =>
          -- alloc may only fail when every slot is live.
          { s with ok := s.ok && (s.model.length == cap) }
      | 1 => -- free an observed id (live, stale, or garbage: all must be safe)
        match s.observed[a % (s.observed.length.max 1)]? with
        | some id =>
          { s with map := s.map.free id
                   model := s.model.filter (fun (e : Id × Nat) => e.1 != id) }
        | none => s
      | 2 => -- update an observed id (stale/garbage must be a no-op)
        match s.observed[a % (s.observed.length.max 1)]? with
        | some id =>
          { s with
            map := s.map.update id b
            model := s.model.map (fun (e : Id × Nat) => if e.1 == id then (e.1, b) else e) }
        | none => s
      | _ => -- synthesize an adversarial id (in- or out-of-range, any gen) and free it
        let gid : Id := { index := UInt32.ofNat (a % (cap + 3)), generation := UInt32.ofNat (b % 4) }
        { s with
          map := s.map.free gid
          model := s.model.filter (fun (e : Id × Nat) => e.1 != gid)
          observed := addObserved s.observed gid }
    { s' with ok := s'.ok && checkConsistent s' }

def runOps (capSeed : Nat) (ops : List (Nat × Nat × Nat)) : Bool :=
  let cap := capSeed % 5 + 1 -- small capacities keep the freelist churning
  let init : Sim :=
    { map := SlotMap.empty cap, model := [], allocated := [], observed := [], ok := true }
  (ops.foldl (step cap) init).ok

/-- Build a Room by subscribing a list of connection ids. -/
def roomFrom (l : List Nat) : Room :=
  l.foldl (fun r c => r.sub c.toUInt64) Room.empty

/-- Exhaustively checks `hilbertIndexOfGrid bits` is a bijection from the
    `2^bits`-per-axis grid onto `[0, 2^(3*bits))`: every grid cell maps to
    a distinct index, and every index in range is hit by some cell. Full
    coverage, not a sample: Skilling's algorithm is well-known, but this
    verifies *this* Lean4 transcription of it rather than trusting memory.
    `bits = 3` keeps this small (512 cells) while still exercising every
    branch of the bit-level loop at least twice. -/
def hilbertIsBijective (bits : Nat) : Bool := Id.run do
  let n := 2 ^ bits
  let total := n * n * n
  let mut seen : Array Bool := Array.replicate total false
  for xi in List.range n do
    for yi in List.range n do
      for zi in List.range n do
        let idx := hilbertIndexOfGrid bits xi.toUInt64 yi.toUInt64 zi.toUInt64
        let idxN := idx.toNat
        if idxN >= total then
          return false -- out of range: not a valid index
        if seen[idxN]! then
          return false -- collision: not injective
        seen := seen.set! idxN true
  return seen.all id -- surjective: every index in range was hit

/-- Builds disjoint, contiguous zone ranges by prefix-summing a list of
    lengths (each clamped to at least 1 so no range is empty). Disjoint by
    construction, so `authorityForIndex`/`disjointRanges` are tested
    against inputs guaranteed to satisfy their precondition rather than
    relying on independently-random ranges happening not to overlap. -/
def zonesFromLengths (lens : List Nat) : Array Zone :=
  let lens := lens.map (· + 1)
  let starts := (lens.foldl (fun (acc : List Nat × Nat) len => (acc.1 ++ [acc.2], acc.2 + len)) ([], 0)).1
  (List.zip starts lens).toArray.map fun (s, len) =>
    { range := { start := s.toUInt64, stop := (s + len).toUInt64 }, entities := #[] }

/-- Picks an index within the total span of `zonesFromLengths lens` (or 0
    for the degenerate empty-`lens` case) from `seed`. -/
def idxFromSeed (lens : List Nat) (seed : Nat) : UInt64 :=
  let zones := zonesFromLengths lens
  if h : zones.size > 0 then
    let totalSpan := (zones[zones.size - 1]).range.stop
    (seed % totalSpan.toNat.max 1).toUInt64
  else 0

/-- True iff `authorityForIndex`, given disjoint zones built from `lens`,
    finds a zone whose range actually contains the picked index. Vacuously
    true for the degenerate empty-`lens` case. -/
def authorityContainsCheck (lens : List Nat) (seed : Nat) : Bool :=
  let zones := zonesFromLengths lens
  if zones.size == 0 then true
  else
    let idx := idxFromSeed lens seed
    match authorityForIndex zones idx with
    | none => false -- every idx < totalSpan must land in some zone, by construction
    | some i => (zones[i]!).range.contains idx

/-- True iff `authorityForIndex`'s answer is the *unique* zone containing
    the picked index, given disjoint zones built from `lens`. -/
def authorityUniqueCheck (lens : List Nat) (seed : Nat) : Bool :=
  let zones := zonesFromLengths lens
  if zones.size == 0 then true
  else
    let idx := idxFromSeed lens seed
    match authorityForIndex zones idx with
    | none => true
    | some i => ((List.range zones.size).filter fun j => (zones[j]!).range.contains idx) == [i]

/-- True iff `adjacentZones`, given zones built from `lens`, never includes
    the zone whose neighbours were asked for. Vacuously true when `lens`
    is empty. -/
def adjacentExcludesSelfCheck (lens : List Nat) (seed : Nat) : Bool :=
  let zones := zonesFromLengths lens
  if zones.size == 0 then true
  else
    let zoneIdx := seed % zones.size
    !(adjacentZones zones zoneIdx).contains zoneIdx

/-- Builds a `ZoneWorld` with disjoint, contiguous zone ranges from `lens`
    (mirroring `zonesFromLengths`, but through the real alloc path so
    `ZoneWorld`'s SlotMap-backed identity is exercised, not just the
    plain-array zone logic `zonesFromLengths` feeds directly). -/
def zoneWorldFromLengths (bits : Nat) (lens : List Nat) : ZoneWorld := Id.run do
  let lens := lens.map (· + 1)
  let starts := (lens.foldl (fun (acc : List Nat × Nat) len => (acc.1 ++ [acc.2], acc.2 + len)) ([], 0)).1
  let mut w : ZoneWorld := ZoneWorld.empty (lens.length + 1) bits
  for (s, len) in List.zip starts lens do
    let range : ZoneRange := { start := s.toUInt64, stop := (s + len).toUInt64 }
    match w.allocZone range with
    | some (w', _) => w := w'
    | none => pure ()
  return w

/-- The total curve span covered by `w`'s live zones (the largest `stop`
    among them, or 0 if `w` has no zones). Used to fold an arbitrary test
    seed into a curve index guaranteed to land inside *some* zone, the
    same way `idxFromSeed` does for the plain-array zone tests above. -/
def Fanoutcore.ZoneWorld.totalSpan (w : ZoneWorld) : UInt64 :=
  (w.liveZones.map fun (_, z) => z.range.stop).foldl max 0

/-- True iff, after moving `connId` to `idx`, that zone's authority query
    for `idx` reports a zone whose live entities include `connId`.
    Vacuously true when `lens` is empty (no zone can own anything). -/
def moveThenAuthorityContainsCheck (lens : List Nat) (connId idx : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  if w.liveZones.size == 0 then true
  else
    let boundedIdx := (idx.toUInt64 % (max w.totalSpan 1))
    let w' := w.moveEntityToIndex connId.toUInt64 boundedIdx
    match w'.authorityForIndex boundedIdx with
    | none => false -- every idx < totalSpan must land in some zone, by construction
    | some zoneId =>
      match w'.zones.find zoneId with
      | none => false
      | some zone => zone.entities.any (·.connId == connId.toUInt64)

/-- True iff moving an entity to a *different* zone removes it from its
    previous zone's membership. Vacuously true if either index has no
    authority zone, or both land in the same zone (nothing to migrate). -/
def migrationLeavesOldZoneCheck (lens : List Nat) (connId idxA idxB : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  let w1 := w.moveEntityToIndex connId.toUInt64 idxA.toUInt64
  match w1.authorityForIndex idxA.toUInt64, w1.authorityForIndex idxB.toUInt64 with
  | some zoneAId, some zoneBId =>
    if zoneAId == zoneBId then true
    else
      let w2 := w1.moveEntityToIndex connId.toUInt64 idxB.toUInt64
      match w2.zones.find zoneAId with
      | none => true
      | some zoneA => !zoneA.entities.any (·.connId == connId.toUInt64)
  | _, _ => true

/-- True iff `moveEntityToIndexHysteresisV`'s first placement (no prior
    zone) lands the entity immediately, same as the non-hysteresis path.
    Vacuously true when `lens` is empty. -/
def hysteresisFirstPlacementImmediateCheck (lens : List Nat) (connId idx : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  if w.liveZones.size == 0 then true
  else
    let boundedIdx := idx.toUInt64 % (max w.totalSpan 1)
    let w' := w.moveEntityToIndexHysteresisV connId.toUInt64 boundedIdx 0 0 0
    match w'.authorityForIndex boundedIdx with
    | none => false
    | some zoneId =>
      match w'.zones.find zoneId with
      | none => false
      | some zone => zone.entities.any (·.connId == connId.toUInt64)

/-- True iff a sustained crossing toward a *different* zone stays with its
    current zone for every call short of `hysteresisTicksFor
    defaultLookaheadTicks`, then actually commits on the call that reaches
    it: the behaviour the mechanism exists for, a genuine sustained
    crossing still transfers authority within a bounded number of ticks.
    Vacuously true if either index has no authority zone, or both land in
    the same zone (nothing to migrate). -/
def hysteresisCommitsAfterStreakCheck (lens : List Nat) (connId idxA idxB : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  let boundedA := idxA.toUInt64 % (max w.totalSpan 1)
  let boundedB := idxB.toUInt64 % (max w.totalSpan 1)
  let w1 := w.moveEntityToIndexHysteresisV connId.toUInt64 boundedA 0 0 0
  match w1.authorityForIndex boundedA, w1.authorityForIndex boundedB with
  | some zoneAId, some zoneBId =>
    if zoneAId == zoneBId then true
    else
      let threshold := (hysteresisTicksFor defaultLookaheadTicks).toNat
      let wPending := (List.range (threshold - 1)).foldl
        (fun acc _ => acc.moveEntityToIndexHysteresisV connId.toUInt64 boundedB 0 0 0) w1
      let stillInA :=
        match wPending.zones.find zoneAId with
        | some zoneA => zoneA.entities.any (·.connId == connId.toUInt64)
        | none => false
      let wCommitted := wPending.moveEntityToIndexHysteresisV connId.toUInt64 boundedB 0 0 0
      let nowInB :=
        match wCommitted.zones.find zoneBId with
        | some zoneB => zoneB.entities.any (·.connId == connId.toUInt64)
        | none => false
      stillInA && nowInB
  | _, _ => true

/-- True iff an entity whose evaluated index keeps alternating between its
    own current zone and a neighbour (boundary jitter, never a sustained
    crossing) never migrates, no matter how many rounds of alternation:
    every return to the current zone resets the streak to 0, so the
    streak toward the neighbour never accumulates past 1. Vacuously true
    if either index has no authority zone, or both land in the same zone. -/
def hysteresisAbsorbsOscillationCheck (lens : List Nat) (connId idxA idxB rounds : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  let boundedA := idxA.toUInt64 % (max w.totalSpan 1)
  let boundedB := idxB.toUInt64 % (max w.totalSpan 1)
  let w1 := w.moveEntityToIndexHysteresisV connId.toUInt64 boundedA 0 0 0
  match w1.authorityForIndex boundedA, w1.authorityForIndex boundedB with
  | some zoneAId, some zoneBId =>
    if zoneAId == zoneBId then true
    else
      let n := rounds % 6
      let wf := (List.range n).foldl
        (fun acc i =>
          acc.moveEntityToIndexHysteresisV connId.toUInt64 (if i % 2 == 0 then boundedB else boundedA) 0 0 0)
        w1
      match wf.zones.find zoneAId with
      | some zoneA => zoneA.entities.any (·.connId == connId.toUInt64)
      | none => false
  | _, _ => true

/-- True iff a single zone's live authority membership never exceeds
    `authorityCapacity`, even when far more entities than that keep
    trying to join the *same* single-point cell (a range of length 1,
    `octreeMaxDepth`, nowhere further to split into: the exact degenerate
    case `authorityCapacity` exists for). `n` is bounded (`% 500`, well
    past `authorityCapacity`'s value) to keep the check fast while still
    exercising the cap. -/
def authorityCapacityCheck (n : Nat) : Bool :=
  let n := n % 500
  let w := ZoneWorld.empty (n + 8) 21
  match w.allocZone { start := 0, stop := 1 } with
  | none => true
  | some (w', zid) =>
    let wf := (List.range n).foldl (fun acc i => acc.moveEntityToIndex i.toUInt64 0) w'
    match wf.zones.find zid with
    | none => false
    | some z => z.entities.size <= authorityCapacity

/-- True iff `targetsForIndex`'s *interest* portion (adjacent-zone, ghost-
    range targets) never exceeds `interestCapacity`, even when every
    candidate entity in the adjacent zone genuinely passes the ghost-range
    check (all default zero position/velocity, so `withinGhostRange` is
    trivially true for all of them: the filtering isn't what's supposed to
    bound this, the cap is). Two adjacent unit zones: the publisher alone
    in the authority zone at index 0, `n` (bounded, well past
    `interestCapacity`) entities in the neighbouring zone at index 1. -/
def interestCapacityCheck (n : Nat) : Bool :=
  let n := n % 600
  let w := ZoneWorld.empty (n + 8) 21
  match w.allocZone { start := 0, stop := 1 } with
  | none => true
  | some (w1, _) =>
    match w1.allocZone { start := 1, stop := 2 } with
    | none => true
    | some (w2, _) =>
      let w3 := w2.moveEntityToIndex 0 0
      let wf := (List.range n).foldl (fun acc i => acc.moveEntityToIndex (i + 1).toUInt64 1) w3
      (wf.targetsForIndex 0 0).size <= interestCapacity

/-- Regression guard: `moveEntityToIndexV` used to unsub an entity from its
    previous zone unconditionally, *before* checking whether the target
    zone had room. If the target was already at `authorityCapacity`,
    `Zone.sub` would silently refuse it there too, vanishing the entity
    from every zone in the world with no authority home at all. True iff
    an entity sitting in zone A, attempting to migrate into a zone B
    that's already full, is still findable in *some* live zone afterward
    (fixed: the move is refused outright, leaving the entity in zone A
    untouched, rather than removed from A and rejected by B). `seed` is
    unused, since this scenario is fully deterministic; kept only so this
    runs as a Plausible check like its neighbours. -/
def capacityFullMigrationPreservesEntityCheck (seed : Nat) : Bool :=
  let _ := seed
  let w0 := ZoneWorld.empty (authorityCapacity + 16) 21
  match w0.allocZone { start := 0, stop := 1 } with
  | none => true
  | some (w1, _) =>
    match w1.allocZone { start := 1, stop := 2 } with
    | none => true
    | some (w2, _) =>
      let w3 := w2.moveEntityToIndex 999 0
      let wFull := (List.range authorityCapacity).foldl
        (fun acc i => acc.moveEntityToIndex (i + 1000).toUInt64 1) w3
      let wAfter := wFull.moveEntityToIndex 999 1
      wAfter.liveZones.any fun (_, z) => z.entities.any (·.connId == 999)

/-- Same regression, via the hysteresis-gated path: fills zone B to
    `authorityCapacity`, then drives an entity in zone A toward B for
    enough consecutive ticks to reach a commit (`hysteresisTicksFor`
    ticks, well within a generous fixed bound), and checks it's still
    findable somewhere afterward. The commit branch had the identical
    unsub-before-capacity-check bug, fixed by staying in the current zone
    with the streak preserved when the target has no room. -/
def hysteresisCapacityFullMigrationPreservesEntityCheck (seed : Nat) : Bool :=
  let _ := seed
  let w0 := ZoneWorld.empty (authorityCapacity + 16) 21
  match w0.allocZone { start := 0, stop := 1 } with
  | none => true
  | some (w1, _) =>
    match w1.allocZone { start := 1, stop := 2 } with
    | none => true
    | some (w2, _) =>
      let w3 := w2.moveEntityToIndexHysteresisV 999 0 0 0 0
      let wFull := (List.range authorityCapacity).foldl
        (fun acc i => acc.moveEntityToIndexHysteresisV (i + 1000).toUInt64 1 0 0 0) w3
      let wAfter := (List.range 10).foldl
        (fun acc _ => acc.moveEntityToIndexHysteresisV 999 1 0 0 0) wFull
      wAfter.liveZones.any fun (_, z) => z.entities.any (·.connId == 999)

/-- True iff `targetsForIndex` never includes the publisher itself. -/
def targetsExcludePublisherCheck (lens : List Nat) (connId idx : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  let w' := w.moveEntityToIndex connId.toUInt64 idx.toUInt64
  !((w'.targetsForIndex connId.toUInt64 idx.toUInt64).contains connId.toUInt64)

/-- True iff two entities placed at the *same* curve index (hence the same
    zone) are mutual fanout targets. -/
def sameZoneTargetsEachOtherCheck (lens : List Nat) (connA connB idx : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  if w.liveZones.size == 0 || connA == connB then true
  else
    let boundedIdx := (idx.toUInt64 % (max w.totalSpan 1))
    let w1 := w.moveEntityToIndex connA.toUInt64 boundedIdx
    let w2 := w1.moveEntityToIndex connB.toUInt64 boundedIdx
    (w2.targetsForIndex connA.toUInt64 boundedIdx).contains connB.toUInt64

/-- True iff `targetsForIndex` never returns duplicate connIds. The
    regression guard for dropping targetsForIndex's redundant dedup check
    (an entity can only ever be in one zone at a time, so it can only
    ever appear once across the authority + curve-adjacent zones a
    publish reaches; this exercises several entities scattered across
    several zones to check that directly, not just assume it). -/
def noDuplicateTargetsCheck (lens : List Nat) (conns : List Nat) (idxs : List Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  if w.liveZones.size == 0 then true
  else
    let span := max w.totalSpan 1
    let placements := List.zip conns idxs
    let w' :=
      placements.foldl (fun (acc : ZoneWorld) (c, i) => acc.moveEntityToIndex c.toUInt64 (i.toUInt64 % span)) w
    match conns, idxs with
    | c0 :: _, i0 :: _ =>
      let targets := w'.targetsForIndex c0.toUInt64 (i0.toUInt64 % span)
      (List.range targets.size).all fun i =>
        (List.range targets.size).all fun j => i == j || targets[i]! != targets[j]!
    | _, _ => true

/-- True iff, after `removeEntity`, the connId is gone from every zone. -/
def removeEntityCheck (lens : List Nat) (connId idx : Nat) : Bool :=
  let w := zoneWorldFromLengths 8 lens
  let w1 := w.moveEntityToIndex connId.toUInt64 idx.toUInt64
  let w2 := w1.removeEntity connId.toUInt64
  w2.liveZones.all fun (_, z) => !z.entities.any (·.connId == connId.toUInt64)

/-- `8^d` as a `UInt64`, computed as `1 <<< (3*d)` (`UInt64` has no `HPow
    UInt64 UInt64` instance): `8^d = 2^(3d)`, matching `octreeMaxDepth`'s
    "3 bits per octree level" accounting. -/
def pow8 (d : Nat) : UInt64 := (1 : UInt64) <<< (3 * d).toUInt64

/-- Builds a `ZoneWorld` whose one zone spans the *entire* Hilbert range at
    quantization depth `depth` (`[0, 8^depth)`, always a valid octree cell
    at depth 0, the root, regardless of `depth`'s value, so
    `octreeChildren` always succeeds on it as long as `depth >= 1`), places
    each of `conns` at index `idx % 8^depth`. `depth` is bounded to `1..3`
    (keeps `8^depth`, at most 512, small enough for exhaustive entity
    placement in a property test while still giving `maybeSplitZone`/
    `maybeMergeSiblings` real octree structure to work with, unlike a
    degenerate 1-cell world). -/
def splitSetup (depth : Nat) (conns idxs : List Nat) : Option (ZoneWorld × Id) :=
  let d := depth % 3 + 1
  let span : UInt64 := pow8 d
  let w := ZoneWorld.empty (conns.length + 16) d
  match w.allocZone { start := 0, stop := span } with
  | none => none
  | some (w, zoneId) =>
    let placements := List.zip conns idxs
    let w' :=
      placements.foldl (fun (acc : ZoneWorld) (c, i) =>
        acc.moveEntityToIndex c.toUInt64 (i.toUInt64 % span)) w
    some (w', zoneId)

/-- True iff `maybeSplitZone` preserves the total live entity count across
    the resulting zones: no entity lost or duplicated among the 8
    children. Vacuously true when the setup can't produce a zone, or when
    splitting isn't cost-favourable for this particular entity
    distribution (a no-op, which trivially preserves the count too). -/
def splitPreservesEntityCountCheck (depth : Nat) (conns idxs : List Nat) : Bool :=
  match splitSetup depth conns idxs with
  | none => true
  | some (w, zoneId) =>
    match w.zones.find zoneId with
    | none => true
    | some zone =>
      let before := zone.entities.size
      let w' := w.maybeSplitZone zoneId
      let after := (w'.liveZones.map fun (_, z) => z.entities.size).foldl (· + ·) 0
      before == after

/-- True iff, after a split, every entity lands in a live zone whose
    range actually contains that entity's own stored curve index. This is
    the correctness property the whole split exists for (an entity must
    stay discoverable via `authorityForIndex` at its own position, not
    silently misfiled into the wrong octant by the split). -/
def splitPlacesEntitiesCorrectlyCheck (depth : Nat) (conns idxs : List Nat) : Bool :=
  match splitSetup depth conns idxs with
  | none => true
  | some (w, zoneId) =>
    let w' := w.maybeSplitZone zoneId
    w'.liveZones.all fun (_, z) =>
      z.entities.all fun rec => z.range.contains rec.idx

/-- True iff live zone ranges stay pairwise disjoint after a split.
    `maybeSplitZone` must not silently create overlapping authority. -/
def splitKeepsRangesDisjointCheck (depth : Nat) (conns idxs : List Nat) : Bool :=
  match splitSetup depth conns idxs with
  | none => true
  | some (w, zoneId) =>
    let w' := w.maybeSplitZone zoneId
    disjointRanges (w'.liveZones.map fun (_, z) => z.range)

/-- True iff a zone holding at most one entity is never split.
    `leafCost 1 = 1` while any real split costs at least `zoneOverhead * 8`
    (Partition.lean), so splitting a near-empty zone can never be
    cost-favourable. This shows the cost model doing something sensible,
    unlike the old threshold-only mechanism (`maybeSplitZone zoneId 0` in
    the previous version always split any non-empty zone unconditionally). -/
def splitNeedsEnoughPopulationCheck (depth : Nat) (conn : Nat) : Bool :=
  match splitSetup depth [conn] [0] with
  | none => true
  | some (w, zoneId) =>
    let w' := w.maybeSplitZone zoneId
    w'.liveZones.size == w.liveZones.size

/-- Builds a `ZoneWorld` whose root (depth `d := depth % 3 + 1`, span
    `[0, 8^d)`) has already been split into its 8 real octree children
    (mirroring `splitSetup`, but one level down, the setup
    `maybeMergeSiblings` needs, since it only ever considers merging 8
    already-live sibling leaves back into their shared parent). Split
    directly via `octreeChildren`/`allocZone` rather than
    `maybeSplitZone`, since a lone empty root never meets
    `splitIsCheaper` (see `splitNeedsEnoughPopulationCheck`); this
    fixture needs 8 live children unconditionally, independent of the
    cost model's opinion on an empty root. Entities are placed *after*
    the split, directly into the children via `moveEntityToIndex`, so
    each lands in whichever of the 8 real octants its index falls in,
    not artificially pre-sorted. -/
def mergeSetup (depth : Nat) (conns idxs : List Nat) : Option ZoneWorld := do
  let d := depth % 3 + 1
  let span : UInt64 := pow8 d
  let w := ZoneWorld.empty (conns.length + 16) d
  let children ← octreeChildren d { start := 0, stop := span }
  let w := Id.run do
    let mut w := w
    for c in children do
      match w.allocZone c with
      | none => pure ()
      | some (w', _) => w := w'
    return w
  let placements := List.zip conns idxs
  let w' :=
    placements.foldl (fun (acc : ZoneWorld) (c, i) =>
      acc.moveEntityToIndex c.toUInt64 (i.toUInt64 % span)) w
  some w'

/-- True iff, after `maybeMergeSiblings` on one of the 8 children,
    the total live entity count is preserved: no entity lost or
    duplicated when 8 siblings recombine into their parent. Vacuously
    true when the setup can't produce a zone, or merging isn't
    cost-favourable (a no-op). -/
def mergePreservesEntityCountCheck (depth : Nat) (conns idxs : List Nat) : Bool :=
  match mergeSetup depth conns idxs with
  | none => true
  | some w =>
    match w.liveZones[0]? with
    | none => true
    | some (firstId, _) =>
      let before := (w.liveZones.map fun (_, z) => z.entities.size).foldl (· + ·) 0
      let w' := w.maybeMergeSiblings firstId
      let after := (w'.liveZones.map fun (_, z) => z.entities.size).foldl (· + ·) 0
      before == after

/-- True iff live zone ranges stay pairwise disjoint after a merge. -/
def mergeKeepsRangesDisjointCheck (depth : Nat) (conns idxs : List Nat) : Bool :=
  match mergeSetup depth conns idxs with
  | none => true
  | some w =>
    match w.liveZones[0]? with
    | none => true
    | some (firstId, _) =>
      let w' := w.maybeMergeSiblings firstId
      disjointRanges (w'.liveZones.map fun (_, z) => z.range)

/-- True iff `maybeMergeSiblings` actually performs a merge when merging
    is genuinely cost-favourable. This closes a gap the two checks above
    never caught: they only assert invariants *if* a merge happens,
    vacuously satisfied when no merge happens at all, so they never proved
    a merge actually fires. One entity spread across 8 otherwise-empty
    siblings (`mergeSetup depth [conn] [0]`) is unambiguous: leafCost 1 =
    1 is strictly less than the 8-way splitCost (`leafCost 1 + zoneOverhead
    = 2` for the one occupied child, `leafCost 0 + zoneOverhead = 1` each
    for the other 7, 9 total), so merging must be the cheaper choice and a
    real merge (8 live zones down to 1) must happen. -/
def mergeActuallyMergesWhenCheaperCheck (depth : Nat) (conn : Nat) : Bool :=
  match mergeSetup depth [conn] [0] with
  | none => true
  | some w =>
    match w.liveZones[0]? with
    | none => true
    | some (firstId, _) =>
      let w' := w.maybeMergeSiblings firstId
      w'.liveZones.size < w.liveZones.size

/-- True iff `withinGhostRange` is symmetric in its two entities: whether
    A could reach B doesn't depend on which one is labelled "publisher."
    `axisDist` is itself symmetric and each side's ghost expansion is
    added (not subtracted or otherwise order-sensitive), so swapping the
    two entities' roles must give the same answer. A testable consequence
    of the fix (comparing real per-axis micrometre distance, not curve-
    index distance); the pure function is simple enough to check this
    directly rather than only through a full ZoneWorld scenario. -/
def withinGhostRangeSymmetricCheck
    (px py pz pvx pvy pvz pk tx ty tz tvx tvy tvz tk : Nat) : Bool :=
  let p : Pos3 := { x := Int64.ofNat px, y := Int64.ofNat py, z := Int64.ofNat pz }
  let t : Pos3 := { x := Int64.ofNat tx, y := Int64.ofNat ty, z := Int64.ofNat tz }
  withinGhostRange p pvx.toUInt64 pvy.toUInt64 pvz.toUInt64 pk.toUInt64 t tvx.toUInt64 tvy.toUInt64 tvz.toUInt64 tk.toUInt64
    == withinGhostRange t tvx.toUInt64 tvy.toUInt64 tvz.toUInt64 tk.toUInt64 p pvx.toUInt64 pvy.toUInt64 pvz.toUInt64 pk.toUInt64

/-- True iff, with both entities stationary (zero velocity on every
    axis), `withinGhostRange` is true iff the two positions are exactly
    equal. Zero velocity means zero ghost expansion (`ghostExpansion v _
    _ = 0` when `v = 0`), so the only way a zero-radius entity is "in
    range" of another zero-radius entity is if they're already at the
    same point. This is the property the earlier curve-index-distance
    bug violated in spirit (everything effectively had zero *curve-index*
    radius at realistic velocities, but was tested as if position
    equality was never actually required); now it's true by construction
    for the degenerate all-zero case, and nonzero cases are covered by the
    monotonicity check below. -/
def withinGhostRangeZeroVelocityCheck (px py pz tx ty tz k : Nat) : Bool :=
  let p : Pos3 := { x := Int64.ofNat px, y := Int64.ofNat py, z := Int64.ofNat pz }
  let t : Pos3 := { x := Int64.ofNat tx, y := Int64.ofNat ty, z := Int64.ofNat tz }
  let inRange := withinGhostRange p 0 0 0 k.toUInt64 t 0 0 0 k.toUInt64
  inRange == (p == t)

/-- True iff increasing one entity's velocity on every axis (holding
    everything else fixed) never turns an in-range determination into
    out-of-range. `ghostExpansion` is monotone non-decreasing in `v`
    (`v*k + aHalf*k^2`, `aHalf = 0` here), so a larger radius can only
    keep covering (or newly cover) the same fixed distance, never stop
    covering it. Directly exercises "more velocity means more reach," the
    property the whole ghost-expansion mechanism exists to provide. -/
def withinGhostRangeMonotoneInVelocityCheck
    (px py pz pvx pvy pvz pk tx ty tz tvx tvy tvz tk extra : Nat) : Bool :=
  let p : Pos3 := { x := Int64.ofNat px, y := Int64.ofNat py, z := Int64.ofNat pz }
  let t : Pos3 := { x := Int64.ofNat tx, y := Int64.ofNat ty, z := Int64.ofNat tz }
  let before := withinGhostRange p pvx.toUInt64 pvy.toUInt64 pvz.toUInt64 pk.toUInt64 t tvx.toUInt64 tvy.toUInt64 tvz.toUInt64 tk.toUInt64
  let after := withinGhostRange p (pvx + extra).toUInt64 (pvy + extra).toUInt64 (pvz + extra).toUInt64 pk.toUInt64
    t tvx.toUInt64 tvy.toUInt64 tvz.toUInt64 tk.toUInt64
  !before || after

/-- Run one property; print the counterexample and exit non-zero on failure. -/
def runCheck (name : String) (p : Prop) [Testable p] (cfg : Configuration) : IO Unit := do
  IO.println s!"prop: {name}"
  match ← Testable.checkIO p cfg with
  | .success _ => pure ()
  | .gaveUp n =>
    IO.eprintln s!"  GAVE UP after {n} discarded test cases"
    IO.Process.exit 1
  | .failure _ counterexample n =>
    IO.eprintln s!"  FALSIFIED after {n} tests, counterexample:"
    for line in counterexample do
      IO.eprintln s!"    {line}"
    IO.Process.exit 1

-- Plausible's Testable instances for quantifiers match on `NamedBinder`
-- wrappers (its `#eval`-level front end adds them via macro); executables
-- using `checkIO` directly must write them out.
def main : IO Unit := do
  let cfg : Configuration := { numInst := 500 }

  runCheck "slot map agrees with model under random op sequences \
            (find consistency, id freshness, stale/garbage safety, capacity)"
    (NamedBinder "capSeed" <| ∀ (capSeed : Nat),
     NamedBinder "ops" <| ∀ (ops : List (Nat × Nat × Nat)),
       runOps capSeed ops = true) cfg

  runCheck "fanout targets never include the publisher"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "p" <| ∀ (p : Nat),
      ((roomFrom l).targets p.toUInt64).contains p.toUInt64 = false) cfg

  runCheck "sub is idempotent"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "c" <| ∀ (c : Nat),
      (((roomFrom l).sub c.toUInt64).sub c.toUInt64).subscribers
        = ((roomFrom l).sub c.toUInt64).subscribers) cfg

  runCheck "after unsub, the connection is gone"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "c" <| ∀ (c : Nat),
      (((roomFrom l).unsub c.toUInt64).subscribers.contains c.toUInt64) = false) cfg

  runCheck "a subscriber receives publishes from anyone else"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "c" <| ∀ (c : Nat),
     NamedBinder "p" <| ∀ (p : Nat),
     NamedBinder "h" <|
      c.toUInt64 ≠ p.toUInt64 →
        (((roomFrom l).sub c.toUInt64).targets p.toUInt64).contains c.toUInt64 = true) cfg

  IO.println "prop: hilbertIndexOfGrid is a bijection over a small exhaustive grid (bits = 3)"
  if !hilbertIsBijective 3 then
    IO.eprintln "  FALSIFIED: hilbertIndexOfGrid 3 is not a bijection over the 8x8x8 grid"
    IO.Process.exit 1

  runCheck "zones built from contiguous lengths are always disjoint"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
      disjointRanges ((zonesFromLengths lens).map Zone.range) = true) cfg

  runCheck "authorityForIndex, given disjoint zones, finds a zone whose range actually contains the index"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "seed" <| ∀ (seed : Nat),
      authorityContainsCheck lens seed = true) cfg

  runCheck "authorityForIndex's answer is the *unique* zone containing the index, given disjoint zones"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "seed" <| ∀ (seed : Nat),
      authorityUniqueCheck lens seed = true) cfg

  runCheck "adjacentZones never includes the zone itself"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "seed" <| ∀ (seed : Nat),
      adjacentExcludesSelfCheck lens seed = true) cfg

  runCheck "moveEntityToIndex places the entity in the zone now authoritative for that index"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idx" <| ∀ (idx : Nat),
      moveThenAuthorityContainsCheck lens connId idx = true) cfg

  runCheck "migrating to a different zone removes the entity from its previous zone"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idxA" <| ∀ (idxA : Nat),
     NamedBinder "idxB" <| ∀ (idxB : Nat),
      migrationLeavesOldZoneCheck lens connId idxA idxB = true) cfg

  runCheck "targetsForIndex never includes the publisher itself"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idx" <| ∀ (idx : Nat),
      targetsExcludePublisherCheck lens connId idx = true) cfg

  runCheck "two entities in the same zone are mutual fanout targets"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connA" <| ∀ (connA : Nat),
     NamedBinder "connB" <| ∀ (connB : Nat),
     NamedBinder "idx" <| ∀ (idx : Nat),
      sameZoneTargetsEachOtherCheck lens connA connB idx = true) cfg

  runCheck "removeEntity clears the connId from every zone"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idx" <| ∀ (idx : Nat),
      removeEntityCheck lens connId idx = true) cfg

  runCheck "targetsForIndex never returns duplicate connIds (regression guard for dropping the redundant dedup check)"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "conns" <| ∀ (conns : List Nat),
     NamedBinder "idxs" <| ∀ (idxs : List Nat),
      noDuplicateTargetsCheck lens conns idxs = true) cfg

  runCheck "maybeSplitZone preserves the total live entity count"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conns" <| ∀ (conns : List Nat),
     NamedBinder "idxs" <| ∀ (idxs : List Nat),
      splitPreservesEntityCountCheck depth conns idxs = true) cfg

  runCheck "maybeSplitZone places every entity in a zone whose range contains its own curve index"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conns" <| ∀ (conns : List Nat),
     NamedBinder "idxs" <| ∀ (idxs : List Nat),
      splitPlacesEntitiesCorrectlyCheck depth conns idxs = true) cfg

  runCheck "maybeSplitZone keeps live zone ranges pairwise disjoint"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conns" <| ∀ (conns : List Nat),
     NamedBinder "idxs" <| ∀ (idxs : List Nat),
      splitKeepsRangesDisjointCheck depth conns idxs = true) cfg

  runCheck "maybeSplitZone never splits a zone holding at most one entity"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conn" <| ∀ (conn : Nat),
      splitNeedsEnoughPopulationCheck depth conn = true) cfg

  runCheck "maybeMergeSiblings preserves the total live entity count"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conns" <| ∀ (conns : List Nat),
     NamedBinder "idxs" <| ∀ (idxs : List Nat),
      mergePreservesEntityCountCheck depth conns idxs = true) cfg

  runCheck "maybeMergeSiblings keeps live zone ranges pairwise disjoint"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conns" <| ∀ (conns : List Nat),
     NamedBinder "idxs" <| ∀ (idxs : List Nat),
      mergeKeepsRangesDisjointCheck depth conns idxs = true) cfg

  runCheck "maybeMergeSiblings actually merges when merging is cheaper than staying split"
    (NamedBinder "depth" <| ∀ (depth : Nat),
     NamedBinder "conn" <| ∀ (conn : Nat),
      mergeActuallyMergesWhenCheaperCheck depth conn = true) cfg

  runCheck "withinGhostRange is symmetric in its two entities"
    (NamedBinder "px" <| ∀ (px : Nat), NamedBinder "py" <| ∀ (py : Nat), NamedBinder "pz" <| ∀ (pz : Nat),
     NamedBinder "pvx" <| ∀ (pvx : Nat), NamedBinder "pvy" <| ∀ (pvy : Nat), NamedBinder "pvz" <| ∀ (pvz : Nat),
     NamedBinder "pk" <| ∀ (pk : Nat),
     NamedBinder "tx" <| ∀ (tx : Nat), NamedBinder "ty" <| ∀ (ty : Nat), NamedBinder "tz" <| ∀ (tz : Nat),
     NamedBinder "tvx" <| ∀ (tvx : Nat), NamedBinder "tvy" <| ∀ (tvy : Nat), NamedBinder "tvz" <| ∀ (tvz : Nat),
     NamedBinder "tk" <| ∀ (tk : Nat),
      withinGhostRangeSymmetricCheck px py pz pvx pvy pvz pk tx ty tz tvx tvy tvz tk = true) cfg

  runCheck "withinGhostRange with both entities stationary is true iff positions are exactly equal"
    (NamedBinder "px" <| ∀ (px : Nat), NamedBinder "py" <| ∀ (py : Nat), NamedBinder "pz" <| ∀ (pz : Nat),
     NamedBinder "tx" <| ∀ (tx : Nat), NamedBinder "ty" <| ∀ (ty : Nat), NamedBinder "tz" <| ∀ (tz : Nat),
     NamedBinder "k" <| ∀ (k : Nat),
      withinGhostRangeZeroVelocityCheck px py pz tx ty tz k = true) cfg

  runCheck "withinGhostRange is monotone non-decreasing in velocity"
    (NamedBinder "px" <| ∀ (px : Nat), NamedBinder "py" <| ∀ (py : Nat), NamedBinder "pz" <| ∀ (pz : Nat),
     NamedBinder "pvx" <| ∀ (pvx : Nat), NamedBinder "pvy" <| ∀ (pvy : Nat), NamedBinder "pvz" <| ∀ (pvz : Nat),
     NamedBinder "pk" <| ∀ (pk : Nat),
     NamedBinder "tx" <| ∀ (tx : Nat), NamedBinder "ty" <| ∀ (ty : Nat), NamedBinder "tz" <| ∀ (tz : Nat),
     NamedBinder "tvx" <| ∀ (tvx : Nat), NamedBinder "tvy" <| ∀ (tvy : Nat), NamedBinder "tvz" <| ∀ (tvz : Nat),
     NamedBinder "tk" <| ∀ (tk : Nat),
     NamedBinder "extra" <| ∀ (extra : Nat),
      withinGhostRangeMonotoneInVelocityCheck px py pz pvx pvy pvz pk tx ty tz tvx tvy tvz tk extra = true) cfg

  runCheck "moveEntityToIndexHysteresisV's first placement lands immediately"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idx" <| ∀ (idx : Nat),
      hysteresisFirstPlacementImmediateCheck lens connId idx = true) cfg

  runCheck "moveEntityToIndexHysteresisV commits authority transfer once a crossing sustains for hysteresisTicksFor ticks"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idxA" <| ∀ (idxA : Nat),
     NamedBinder "idxB" <| ∀ (idxB : Nat),
      hysteresisCommitsAfterStreakCheck lens connId idxA idxB = true) cfg

  runCheck "moveEntityToIndexHysteresisV absorbs boundary oscillation without ever migrating"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "connId" <| ∀ (connId : Nat),
     NamedBinder "idxA" <| ∀ (idxA : Nat),
     NamedBinder "idxB" <| ∀ (idxB : Nat),
     NamedBinder "rounds" <| ∀ (rounds : Nat),
      hysteresisAbsorbsOscillationCheck lens connId idxA idxB rounds = true) cfg

  runCheck "a single zone's authority membership never exceeds authorityCapacity"
    (NamedBinder "n" <| ∀ (n : Nat),
      authorityCapacityCheck n = true) cfg

  runCheck "targetsForIndex's interest portion never exceeds interestCapacity"
    (NamedBinder "n" <| ∀ (n : Nat),
      interestCapacityCheck n = true) cfg

  runCheck "moveEntityToIndexV never vanishes an entity when its target zone is full"
    (NamedBinder "seed" <| ∀ (seed : Nat),
      capacityFullMigrationPreservesEntityCheck seed = true) cfg

  runCheck "moveEntityToIndexHysteresisV never vanishes an entity when its target zone is full"
    (NamedBinder "seed" <| ∀ (seed : Nat),
      hysteresisCapacityFullMigrationPreservesEntityCheck seed = true) cfg

  IO.println "ALL PROPERTY TESTS PASSED"
