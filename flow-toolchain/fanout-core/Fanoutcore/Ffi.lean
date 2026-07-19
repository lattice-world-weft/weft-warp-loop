import Fanoutcore.FanoutCore

namespace Fanoutcore

/-- Global mutable state, one process-wide fanout core. The C++ host
    adapter is a single Flow actor calling in sequentially — no
    concurrent access to guard against here; Flow's own scheduler is
    what serializes calls into this core, same as it serializes every
    other actor's access to shared state. -/
initialize stateRef : IO.Ref State ← IO.mkRef (State.initial 0)

@[export fanout_init]
def init (capacity : UInt32) : IO Unit :=
  stateRef.set (State.initial capacity.toNat)

@[export fanout_alloc_room]
def allocRoom : IO UInt64 := do
  let s ← stateRef.get
  match s.rooms.alloc Room.empty with
  | none => return SENTINEL
  | some (rooms', id) =>
    stateRef.set { s with rooms := rooms' }
    return id.pack

@[export fanout_free_room]
def freeRoom (roomId : UInt64) : IO Unit := do
  let s ← stateRef.get
  stateRef.set { s with rooms := s.rooms.free (Id.unpack roomId) }

@[export fanout_sub]
def sub (roomId : UInt64) (connId : UInt64) : IO Unit := do
  let s ← stateRef.get
  let id := Id.unpack roomId
  match s.rooms.find id with
  | none => pure ()
  | some room => stateRef.set { s with rooms := s.rooms.update id (room.sub connId) }

@[export fanout_unsub]
def unsub (roomId : UInt64) (connId : UInt64) : IO Unit := do
  let s ← stateRef.get
  let id := Id.unpack roomId
  match s.rooms.find id with
  | none => pure ()
  | some room => stateRef.set { s with rooms := s.rooms.update id (room.unsub connId) }

/-- Returns the fanout target list for a `PUB` on `roomId` from
    `publisherConnId` (every subscriber except the publisher). Empty
    array if the room doesn't exist (a stale/freed roomId). -/
@[export fanout_pub_targets]
def pubTargets (roomId : UInt64) (publisherConnId : UInt64) : IO (Array UInt64) := do
  let s ← stateRef.get
  match s.rooms.find (Id.unpack roomId) with
  | none => return #[]
  | some room => return room.targets publisherConnId

-- ── Zone-authority / interest dispatch (ADR 0008, Zone.lean/ZoneDispatch.lean) ──
-- Additive to the Room/SUB/PUB API above, not yet called from it - the
-- C++ host's wire protocol still only speaks flat Room broadcast. These
-- exports let a future wire verb (e.g. a position-carrying "MOVE") drive
-- zone-based authority/interest fanout once that dispatch rewiring lands.

@[export fanout_zone_alloc]
def zoneAlloc (startIdx : UInt64) (stopIdx : UInt64) : IO UInt64 := do
  let s ← stateRef.get
  match s.zoneWorld.allocZone { start := startIdx, stop := stopIdx } with
  | none => return SENTINEL
  | some (world', id) =>
    stateRef.set { s with zoneWorld := world' }
    return id.pack

@[export fanout_zone_free]
def zoneFree (zoneId : UInt64) : IO Unit := do
  let s ← stateRef.get
  stateRef.set { s with zoneWorld := s.zoneWorld.freeZone (Id.unpack zoneId) }

@[export fanout_entity_move]
def entityMove (connId : UInt64) (x : Int64) (y : Int64) (z : Int64) : IO Unit := do
  let s ← stateRef.get
  let pos : Pos3 := { x := x, y := y, z := z }
  let moved := s.zoneWorld.moveEntity connId pos
  -- AV1-style split/merge (ADR 0008/0009, Partition.lean): check the zone
  -- the entity just landed in for a split every move, not on a separate
  -- timer/tick - population changes exactly when entities move, so there
  -- is no reason to defer the check to a later pass (and no separate
  -- scheduling mechanism to keep in sync with this one if there were).
  -- `maybeSplitZone` itself decides whether splitting is cost-favourable
  -- (Partition.lean's `splitIsCheaper`); no separate threshold parameter
  -- to keep in sync with it.
  let final :=
    match moved.authorityFor pos with
    | none => moved
    | some zoneId => moved.maybeSplitZone zoneId
  stateRef.set { s with zoneWorld := final }

@[export fanout_entity_remove]
def entityRemove (connId : UInt64) : IO Unit := do
  let s ← stateRef.get
  -- Find the zone this entity is leaving *before* removing it, so a merge
  -- (the symmetric counterpart to the split check in entityMove - a
  -- population drop is exactly when merging back into a sibling's parent
  -- could become cost-favourable) has a zone to check. Its id is still
  -- valid after `removeEntity` (that only edits entity membership, never
  -- frees/reallocs zones), so it's still the right handle to check.
  let leavingZoneId := s.zoneWorld.liveZones.find? (fun (_, z) => z.entities.any (·.1 == connId)) |>.map (·.1)
  let removed := s.zoneWorld.removeEntity connId
  let final :=
    match leavingZoneId with
    | none => removed
    | some zid => removed.maybeMergeSiblings zid
  stateRef.set { s with zoneWorld := final }

/-- Returns the zone-authority/interest fanout target list (ZoneDispatch's
    `targetsFor`: the authority zone plus curve-adjacent interest zones)
    for a publish from `publisherConnId` at `(x, y, z)`. Empty array if no
    zone's range covers that position - a legitimate state (gossip hasn't
    assigned that range yet), not an error. -/
@[export fanout_zone_targets]
def zoneTargets (publisherConnId : UInt64) (x : Int64) (y : Int64) (z : Int64) : IO (Array UInt64) := do
  let s ← stateRef.get
  return s.zoneWorld.targetsFor publisherConnId { x := x, y := y, z := z }

end Fanoutcore
