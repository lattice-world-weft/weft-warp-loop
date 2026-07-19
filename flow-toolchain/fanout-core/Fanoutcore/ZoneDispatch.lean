import Fanoutcore.SlotMap
import Fanoutcore.Zone

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
    since this ran once per publisher per tick). -/
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
        for (connId, _) in plain[i].entities do
          if connId != publisherConnId then
            result := result.push connId
    return result

def ZoneWorld.targetsFor (w : ZoneWorld) (publisherConnId : UInt64) (pos : Pos3) : Array UInt64 :=
  w.targetsForIndex publisherConnId (hilbert3D w.bits pos)

/-- Moves (or first-places) `connId`'s entity to curve index `idx`: removes
    it from whichever zone it was previously authoritative in (a linear
    scan over live zones' entity lists - fine at this scale, matching
    `Room.unsub`'s own linear `filter`), then adds it to the zone now
    authoritative for `idx`, if any. This is the migration operation
    (`AuthorityInterest.lean`'s "authority transfer") - a first version
    with no hysteresis threshold (`AuthorityInterest.lean`'s
    `hysteresisThreshold`), so an entity oscillating exactly on a zone
    boundary can migrate every call; that refinement is later, separate
    work, not silently assumed solved here. -/
def ZoneWorld.moveEntityToIndex (w : ZoneWorld) (connId : UInt64) (idx : UInt64) : ZoneWorld := Id.run do
  let mut zones := w.zones
  for (id, zone) in w.liveZones do
    if zone.entities.any (·.1 == connId) then
      zones := zones.update id (zone.unsub connId)
  let w := { w with zones := zones }
  match w.authorityForIndex idx with
  | none => return w
  | some zoneId =>
    match w.zones.find zoneId with
    | none => return w
    | some zone => return { w with zones := w.zones.update zoneId (zone.sub connId idx) }

def ZoneWorld.moveEntity (w : ZoneWorld) (connId : UInt64) (pos : Pos3) : ZoneWorld :=
  w.moveEntityToIndex connId (hilbert3D w.bits pos)

/-- Removes `connId`'s entity from whichever zone it was in, if any -
    mirrors `Room.unsub`, called when a connection disconnects. -/
def ZoneWorld.removeEntity (w : ZoneWorld) (connId : UInt64) : ZoneWorld := Id.run do
  let mut zones := w.zones
  for (id, zone) in w.liveZones do
    if zone.entities.any (·.1 == connId) then
      zones := zones.update id (zone.unsub connId)
  return { w with zones := zones }

/-- E-GOSSIP (density-tracking zone partitioning, ADR 0008): if `zoneId`'s
    live population exceeds `threshold`, splits its range at the
    midpoint into two new zones and redistributes its entities into
    whichever half their own stored curve index falls in, then frees the
    original zone. A range of length 1 (`stop = start + 1`) cannot be
    split further (the midpoint would equal `start`, producing a
    zero-width half) and is left alone even over threshold - an
    unavoidable floor on how fine partitioning can get, not a bug.

    This bounds each zone's population (and so `targetsForIndex`'s
    per-publish cost, which is quadratic in a zone's own population) by
    `threshold` regardless of how many entities the world holds in total
    - the mechanism the whole Hilbert-zone design exists for: without it,
    every entity lands in one ever-growing zone (this project's current
    startup bootstrap - `fanoutCoreInitialize`'s single default zone
    spanning the entire range) and per-publish cost grows with total
    population `N`, not a per-zone constant `K` - see fanout_load_client's
    own measured O(N^3) regression (fixed in `targetsForIndex` above)
    for what happens when a per-zone cost silently becomes a per-system
    one. No merge counterpart yet (zones that empty out via `removeEntity`
    stay allocated, just idle) - that is later, separate work: merge
    needs a hysteresis threshold of its own (mirroring `moveEntityToIndex`
    doc comment above) to avoid a population oscillating around the split
    threshold causing every publish to alternately split and merge the
    same zone. -/
def ZoneWorld.maybeSplitZone (w : ZoneWorld) (zoneId : Id) (threshold : Nat) : ZoneWorld :=
  match w.zones.find zoneId with
  | none => w
  | some zone =>
    if zone.entities.size <= threshold then w
    else
      let start := zone.range.start
      let stop := zone.range.stop
      let mid := start + (stop - start) / 2
      if mid <= start then w
      else
        let lower : ZoneRange := { start := start, stop := mid }
        let upper : ZoneRange := { start := mid, stop := stop }
        let w := w.freeZone zoneId
        match w.allocZone lower with
        | none => w
        | some (w, lowerId) =>
          match w.allocZone upper with
          | none => w
          | some (w, upperId) =>
            Id.run do
              let mut zones := w.zones
              for (connId, idx) in zone.entities do
                let targetId := if idx < mid then lowerId else upperId
                match zones.find targetId with
                | none => pure ()
                | some target => zones := zones.update targetId (target.sub connId idx)
              return { w with zones := zones }

end Fanoutcore
