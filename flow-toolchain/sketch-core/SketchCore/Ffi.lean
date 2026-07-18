import SketchCore.History

/-! C FFI surface for the Flow bridge actor. Same conventions as
    fanout-core: process-global `IO.Ref` state, the single Flow reactor
    thread serializes all calls, rooms keyed by the caller's own u64 room
    handle (the fanout-core packed slot-map id). -/

namespace SketchCore

structure FfiState where
  rooms : Array (UInt64 × RoomHistory)
  deriving Inhabited

initialize stateRef : IO.Ref FfiState ← IO.mkRef { rooms := #[] }

private def withRoom (roomId : UInt64) (f : RoomHistory → RoomHistory × α) (dflt : α) : IO α := do
  let s ← stateRef.get
  for i in [0:s.rooms.size] do
    let (rid, h) := s.rooms[i]!
    if rid == roomId then
      let (h', a) := f h
      stateRef.set { rooms := s.rooms.set! i (rid, h') }
      return a
  let (h', a) := f RoomHistory.empty
  stateRef.set { rooms := s.rooms.push (roomId, h') }
  let _ := dflt
  return a

@[export sketch_reset]
def reset : IO Unit :=
  stateRef.set { rooms := #[] }

/-- Apply an inbound CSP1 packet to a room's history. Returns 1 if the
    packet was accepted (valid + fresh: relay it), 0 otherwise. -/
@[export sketch_apply_packet]
def applyPacket (roomId : UInt64) (bytes : ByteArray) : IO UInt8 :=
  withRoom roomId (fun h =>
    let (h', accepted) := h.apply bytes
    (h', if accepted then (1 : UInt8) else 0)) 0

/-- Number of packets in a room's accepted history. -/
@[export sketch_history_count]
def historyCount (roomId : UInt64) : IO UInt32 := do
  let s ← stateRef.get
  for (rid, h) in s.rooms do
    if rid == roomId then
      return h.packets.size.toUInt32
  return 0

/-- The i-th accepted packet (raw bytes) - the late-join replay source.
    Empty array if out of range. -/
@[export sketch_history_packet]
def historyPacket (roomId : UInt64) (i : UInt32) : IO ByteArray := do
  let s ← stateRef.get
  for (rid, h) in s.rooms do
    if rid == roomId then
      if i.toNat < h.packets.size then
        return h.packets[i.toNat]!
  return ByteArray.empty

/-- Canonical sketch-graph JSON for a room (the convergence artifact). -/
@[export sketch_graph_json]
def graphJson (roomId : UInt64) : IO String := do
  let s ← stateRef.get
  for (rid, h) in s.rooms do
    if rid == roomId then
      return h.graphJson
  return RoomHistory.empty.graphJson

end SketchCore
