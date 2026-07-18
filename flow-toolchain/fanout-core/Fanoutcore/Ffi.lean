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

end Fanoutcore
