import Fanoutcore.SlotMap

namespace Fanoutcore

/-- A room's live state: which connections are currently subscribed.
    A plain `Array` is this project's Lean4 equivalent of the C++ host's
    "intrusive list" idea — for the handful of subscribers a single room
    ever holds (bounded by the 32-player shard target), a small array is
    the natural, simple representation; there is no meaningful
    "intrusive vs. array" distinction once the elements are plain
    connection-id integers rather than heap-allocated nodes. -/
structure Room where
  subscribers : Array UInt64
  deriving Repr, Inhabited

def Room.empty : Room := { subscribers := #[] }

def Room.sub (r : Room) (connId : UInt64) : Room :=
  if r.subscribers.contains connId then r
  else { r with subscribers := r.subscribers.push connId }

def Room.unsub (r : Room) (connId : UInt64) : Room :=
  { r with subscribers := r.subscribers.filter (· != connId) }

/-- Every connection except the publisher gets the fanout. -/
def Room.targets (r : Room) (publisherConnId : UInt64) : Array UInt64 :=
  r.subscribers.filter (· != publisherConnId)

structure State where
  rooms : SlotMap Room
  deriving Repr, Inhabited

def State.initial (capacity : Nat) : State := { rooms := SlotMap.empty capacity }

/-- Packs a slot-map `Id` into one `UInt64` (index in the high 32 bits,
    generation in the low 32) so it can cross the FFI boundary as a
    single scalar instead of a Lean structure. `UInt64.max` is the
    "no such room" / "capacity exceeded" sentinel. -/
def Id.pack (id : Id) : UInt64 := (id.index.toUInt64 <<< 32) ||| id.generation.toUInt64
def Id.unpack (v : UInt64) : Id :=
  { index := (v >>> 32).toUInt32, generation := (v &&& 0xFFFFFFFF).toUInt32 }

def SENTINEL : UInt64 := 0xFFFFFFFFFFFFFFFF

end Fanoutcore
