import Fanoutcore.SlotMap
import Fanoutcore.Zone
import Fanoutcore.Partition

namespace Fanoutcore

/-- The dynamic zone-authority world: a `SlotMap` of zones (alloc/free
    like `Room`), each zone carrying its own live entity membership
    (`Zone.entities`). `bits` is the Hilbert quantization depth, fixed for
    the world's lifetime (set once, mirroring `State.initial`'s
    capacity). -/
structure ZoneWorld where
  zones : SlotMap Zone
  bits  : Nat
  deriving Repr, Inhabited

def ZoneWorld.empty (capacity bits : Nat) : ZoneWorld :=
  { zones := SlotMap.empty capacity, bits := bits }

/-- All live zones as a plain, densely-indexed snapshot, alongside the
    `SlotMap` `Id` each array position corresponds to. `authorityForIndex`/
    `adjacentZones` (Zone.lean) work over plain arrays by design - a
    static snapshot is enough for one lookup; the `SlotMap` is only needed
    for the FFI-facing alloc/free identity. Rebuilt on every call rather
    than cached: simple to reason about and test, and cheap at this
    project's actual zone counts (a handful per shard) - revisit if that
    stops being true. -/
def ZoneWorld.liveZones (w : ZoneWorld) : Array (Id × Zone) :=
  w.zones.liveEntries

def ZoneWorld.allocZone (w : ZoneWorld) (range : ZoneRange) : Option (ZoneWorld × Id) :=
  match w.zones.alloc { range := range, entities := #[] } with
  | none => none
  | some (zones', id) => some ({ w with zones := zones' }, id)

def ZoneWorld.freeZone (w : ZoneWorld) (id : Id) : ZoneWorld :=
  { w with zones := w.zones.free id }

/-- The zone id whose range contains curve index `idx`, if any. Separated
    from the `Pos3` entry point below (same split as Zone.lean's
    `authorityForIndex`/`authorityFor`) so TestProps.lean can test zone
    logic directly on controllable indices, without needing to invert the
    Hilbert curve to find a `Pos3` landing in a specific zone. -/
def ZoneWorld.authorityForIndex (w : ZoneWorld) (idx : UInt64) : Option Id :=
  let live := w.liveZones
  match Fanoutcore.authorityForIndex (live.map (·.2)) idx with
  | none => none
  | some i => (live[i]?).map (·.1)

def ZoneWorld.authorityFor (w : ZoneWorld) (pos : Pos3) : Option Id :=
  w.authorityForIndex (hilbert3D w.bits pos)

/-- Every connId that should receive `publisherConnId`'s update at curve
    index `idx`: every other entity's connId in the authority zone for
    `idx`, plus every entity's connId in a curve-adjacent zone (the
    interest ghosts, `adjacentZones`). Entities are tracked per-zone
    (`Zone.entities`), matching `Room.subscribers`'s existing flat-array
    shape, rather than in a separate global entity table - a zone's own
    membership list is exactly what changes on migration (`moveEntity`
    below).

    No dedup check against `result` here (an earlier version had one,
    `!result.contains connId`): `reach`'s zones are pairwise distinct
    indices (`adjacentZones` never returns `authIdx` itself, and its
    "before"/"after" neighbours are themselves distinct by construction),
    and `moveEntityToIndex` maintains the invariant that an entity lives
    in at most one zone at a time (proven:
    `migrating to a different zone removes the entity from its previous
    zone` in TestProps.lean) - so no connId can appear in two different
    zones' `entities` arrays to begin with. The check was a redundant
    O(result.size) scan on every insertion, making target construction
    O(reach-population^2) instead of O(reach-population) for no
    correctness benefit - a real algorithmic cost this repo's own load
    testing (fanout_load_client) measured directly (super-quadratic
    growth well past what O(N^2) target construction alone would predict,
    since this ran once per publisher per tick).

    Still blanket "everyone in reach hears everyone" visibility, not real
    ghost-expansion interest yet (see `EntityRecord`'s velocity fields,
    added but not yet consumed here) - that replacement is later, separate
    work, not silently assumed solved by adding the fields alone. -/
def ZoneWorld.targetsForIndex (w : ZoneWorld) (publisherConnId : UInt64) (idx : UInt64) : Array UInt64 := Id.run do
  let live := w.liveZones
  let plain := live.map (·.2)
  match Fanoutcore.authorityForIndex plain idx with
  | none => return #[]
  | some authIdx =>
    let reach := #[authIdx] ++ adjacentZones plain authIdx
    let mut result : Array UInt64 := #[]
    for i in reach do
      if h : i < plain.size then
        for rec in plain[i].entities do
          if rec.connId != publisherConnId then
            result := result.push rec.connId
    return result

def ZoneWorld.targetsFor (w : ZoneWorld) (publisherConnId : UInt64) (pos : Pos3) : Array UInt64 :=
  w.targetsForIndex publisherConnId (hilbert3D w.bits pos)

/-- Moves (or first-places) `connId`'s entity to curve index `idx` with the
    given velocity magnitude per axis (μm/tick, absolute value - see
    `EntityRecord`): removes it from whichever zone it was previously
    authoritative in (a linear scan over live zones' entity lists - fine
    at this scale, matching `Room.unsub`'s own linear `filter`), then adds
    it to the zone now authoritative for `idx`, if any, carrying the new
    velocity forward. This is the migration operation
    (`AuthorityInterest.lean`'s "authority transfer") - a first version
    with no hysteresis threshold (`AuthorityInterest.lean`'s
    `hysteresisThreshold`), so an entity oscillating exactly on a zone
    boundary can migrate every call; that refinement is later, separate
    work, not silently assumed solved here. -/
def ZoneWorld.moveEntityToIndexV (w : ZoneWorld) (connId idx vx vy vz : UInt64) : ZoneWorld := Id.run do
  let mut zones := w.zones
  for (id, zone) in w.liveZones do
    if zone.entities.any (·.connId == connId) then
      zones := zones.update id (zone.unsub connId)
  let w := { w with zones := zones }
  match w.authorityForIndex idx with
  | none => return w
  | some zoneId =>
    match w.zones.find zoneId with
    | none => return w
    | some zone =>
      return { w with zones := w.zones.update zoneId (zone.sub { connId, idx, vx, vy, vz }) }

/-- `moveEntityToIndexV` with zero velocity - the convenience entry point
    for callers that don't track velocity (most of TestProps.lean's plain
    authority/migration/split property tests, which exercise curve-index
    placement logic independent of ghost expansion). -/
def ZoneWorld.moveEntityToIndex (w : ZoneWorld) (connId : UInt64) (idx : UInt64) : ZoneWorld :=
  w.moveEntityToIndexV connId idx 0 0 0

def ZoneWorld.moveEntityV (w : ZoneWorld) (connId : UInt64) (pos : Pos3) (vx vy vz : UInt64) : ZoneWorld :=
  w.moveEntityToIndexV connId (hilbert3D w.bits pos) vx vy vz

def ZoneWorld.moveEntity (w : ZoneWorld) (connId : UInt64) (pos : Pos3) : ZoneWorld :=
  w.moveEntityToIndex connId (hilbert3D w.bits pos)

/-- Removes `connId`'s entity from whichever zone it was in, if any -
    mirrors `Room.unsub`, called when a connection disconnects. -/
def ZoneWorld.removeEntity (w : ZoneWorld) (connId : UInt64) : ZoneWorld := Id.run do
  let mut zones := w.zones
  for (id, zone) in w.liveZones do
    if zone.entities.any (·.connId == connId) then
      zones := zones.update id (zone.unsub connId)
  return { w with zones := zones }

/-- The population that would land in each of `zone.range`'s 8 octree
    children if split now, in the same order `octreeChildren` returns them -
    just a count per child, no entity data moved yet (this is the input
    `splitIsCheaper` needs before committing to an actual split). -/
def childPopulationsFor (zone : Zone) (children : Array ZoneRange) : Array Nat :=
  children.map fun c => (zone.entities.filter fun rec => c.contains rec.idx).size

/-- AV1-style split (ADR 0008/0009, Partition.lean): if splitting `zoneId`
    into its 8 real octree children (`octreeChildren`, along genuine octant
    boundaries derived from the Hilbert quantization depth - not an
    arbitrary midpoint bisection, this project's earlier approximation) is
    cost-favourable (`splitIsCheaper`, this project's own `Θ(population^2)`
    fanout cost, not the real prior art's ray-tracing surface-area
    heuristic - see Partition.lean's header comment), frees the original
    zone and allocates the 8 children, redistributing entities by which
    child's range contains their own stored curve index. A no-op if
    `zoneId`'s range isn't a valid octree cell (`octreeChildren` returns
    `none`) or splitting isn't cost-favourable - split and merge
    (`maybeMergeSiblings` below) are the same comparison, evaluated from
    either direction, not two separate mechanisms with independent
    thresholds to keep in sync. -/
def ZoneWorld.maybeSplitZone (w : ZoneWorld) (zoneId : Id) : ZoneWorld :=
  match w.zones.find zoneId with
  | none => w
  | some zone =>
    match octreeChildren w.bits zone.range with
    | none => w
    | some children =>
      let childPops := childPopulationsFor zone children
      if !splitIsCheaper zone.entities.size childPops then w
      else
        let w := w.freeZone zoneId
        Id.run do
          let mut w := w
          let mut childIds : Array Id := #[]
          for c in children do
            match w.allocZone c with
            | none => return w
            | some (w', cid) => w := w'; childIds := childIds.push cid
          let mut zones := w.zones
          for rec in zone.entities do
            for i in List.range children.size do
              if (children[i]!).contains rec.idx then
                match childIds[i]? with
                | none => pure ()
                | some cid =>
                  match zones.find cid with
                  | none => pure ()
                  | some target => zones := zones.update cid (target.sub rec)
          return { w with zones := zones }

/-- The range one octree level up from `r` (the parent cell `r` would be one
    of 8 children of), if `r` is itself a valid, non-root octree cell -
    `none` if `r` is already the root (`zoneRangeDepth` gives depth 0) or
    isn't octree-aligned to begin with. -/
def parentRange (bits : Nat) (r : ZoneRange) : Option ZoneRange := do
  let d ← zoneRangeDepth bits r
  if d == 0 then none
  else
    let len := r.stop - r.start
    let parentLen := len * 8
    let parentStart := r.start - (r.start % parentLen)
    some { start := parentStart, stop := parentStart + parentLen }

/-- The symmetric counterpart to `maybeSplitZone`: if `zoneId` is one of 8
    live sibling zones that together exactly tile a common parent octree
    cell, and merging them back into that one parent is cost-favourable
    (population no longer justifies 8 separate zones' overhead), frees all
    8 children and allocates the single parent zone with their combined
    entities. A no-op if `zoneId`'s range has no valid parent, or fewer
    than all 8 siblings are currently live (a zone can only rejoin its
    parent when every one of its 7 siblings is also a plain, unsplit leaf -
    partial merges would leave the parent's range partially double-owned),
    or merging isn't cost-favourable. -/
def ZoneWorld.maybeMergeSiblings (w : ZoneWorld) (zoneId : Id) : ZoneWorld :=
  match w.zones.find zoneId with
  | none => w
  | some zone =>
    match parentRange w.bits zone.range with
    | none => w
    | some parent =>
      match octreeChildren w.bits parent with
      | none => w
      | some children =>
        Id.run do
          let mut siblingIds : Array Id := #[]
          let mut allEntities : Array EntityRecord := #[]
          let mut totalPop := 0
          for c in children do
            match w.authorityForIndex c.start with
            | none => return w
            | some sid =>
              match w.zones.find sid with
              | none => return w
              | some szone =>
                if szone.range.start != c.start || szone.range.stop != c.stop then
                  return w -- that child range isn't a plain leaf zone yet
                else
                  siblingIds := siblingIds.push sid
                  allEntities := allEntities ++ szone.entities
                  totalPop := totalPop + szone.entities.size
          let childPops := children.map fun c =>
            (allEntities.filter fun rec => c.contains rec.idx).size
          if !splitIsCheaper totalPop childPops then return w
          else
            let mut w := w
            for sid in siblingIds do
              w := w.freeZone sid
            match w.allocZone parent with
            | none => return w
            | some (w', pid) =>
              let mut zones := w'.zones
              match zones.find pid with
              | none => return { w' with zones := zones }
              | some pzone =>
                let mut pzone := pzone
                for rec in allEntities do
                  pzone := pzone.sub rec
                zones := zones.update pid pzone
                return { w' with zones := zones }

end Fanoutcore
