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

/-- Splits/merges the zone `pos` now lands in after a move, cost-decided
    (`Partition.lean`'s `splitIsCheaper`) - checked on every move rather
    than a separate timer/tick, since population changes exactly when
    entities move. Shared by both `entityMove` (zero velocity) and
    `entityMoveV` (real velocity) so the split-check logic has one
    definition. -/
def rebalanceAfterMove (w : ZoneWorld) (pos : Pos3) : ZoneWorld :=
  match w.authorityFor pos with
  | none => w
  | some zoneId => w.maybeSplitZone zoneId

@[export fanout_entity_move]
def entityMove (connId : UInt64) (x : Int64) (y : Int64) (z : Int64) : IO Unit := do
  let s ← stateRef.get
  let pos : Pos3 := { x := x, y := y, z := z }
  let moved := s.zoneWorld.moveEntity connId pos
  stateRef.set { s with zoneWorld := rebalanceAfterMove moved pos }

/-- `entityMove` with a known velocity magnitude per axis (μm/tick,
    absolute value - `EntityRecord`) and RTT-derived lookahead window in
    ticks (`rttTicks` - `0` means no RTT sample yet, falls back to
    `defaultLookaheadTicks`; the caller converts picoquic's own measured
    RTT to a tick count before calling, keeping this module's arithmetic
    in one unit system), for k-tick ghost expansion once a caller (the
    wire protocol, later work) actually sends both. `entityMove` above
    stays the zero-velocity/default-lookahead convenience path for
    callers that don't track either. -/
@[export fanout_entity_move_v]
def entityMoveV (connId : UInt64) (x : Int64) (y : Int64) (z : Int64) (vx vy vz : UInt64) (rttTicks : UInt64) : IO Unit := do
  let s ← stateRef.get
  let pos : Pos3 := { x := x, y := y, z := z }
  let moved := s.zoneWorld.moveEntityV connId pos vx vy vz rttTicks
  stateRef.set { s with zoneWorld := rebalanceAfterMove moved pos }

@[export fanout_entity_remove]
def entityRemove (connId : UInt64) : IO Unit := do
  let s ← stateRef.get
  -- Find the zone this entity is leaving *before* removing it, so a merge
  -- (the symmetric counterpart to the split check in entityMove - a
  -- population drop is exactly when merging back into a sibling's parent
  -- could become cost-favourable) has a zone to check. Its id is still
  -- valid after `removeEntity` (that only edits entity membership, never
  -- frees/reallocs zones), so it's still the right handle to check.
  let leavingZoneId := s.zoneWorld.liveZones.find? (fun (_, z) => z.entities.any (·.connId == connId)) |>.map (·.1)
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
