import Fanoutcore.SlotMap
import Fanoutcore.Zone
import Fanoutcore.ZoneDispatch

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

/-- Hilbert quantization depth for the zone-authority coordinate space
    (ADR 0008 / Zone.lean): 21 bits per axis interleaves to a 63-bit
    curve index, fitting `UInt64` with a bit to spare. Fixed here rather
    than exposed as an FFI parameter - a per-world quantization depth is
    a real future knob (finer resolution costs more curve range to
    partition), not something callers need to choose yet. -/
def zoneBits : Nat := 21

/-- E-GOSSIP split threshold (ZoneDispatch.lean's `maybeSplitZone`):
    once a zone's live population exceeds this, it splits in two. 32
    matches this codebase's own established shard-size target (Room's
    doc comment above: "the handful of subscribers a single room ever
    holds (bounded by the 32-player shard target)") - reusing an
    already-chosen scale rather than picking a new, unjustified number.
    Keeping each zone's population bounded near this is what keeps
    `targetsForIndex`'s per-publish cost (quadratic in a zone's own
    population) close to constant regardless of how many entities the
    world holds in total - see ZoneDispatch.lean's `maybeSplitZone` doc
    comment for the full reasoning. -/
def zoneSplitThreshold : Nat := 32

structure State where
  rooms     : SlotMap Room
  zoneWorld : ZoneWorld
  deriving Repr, Inhabited

def State.initial (capacity : Nat) : State :=
  { rooms := SlotMap.empty capacity, zoneWorld := ZoneWorld.empty capacity zoneBits }

/-- Packs a slot-map `Id` into one `UInt64` (index in the high 32 bits,
    generation in the low 32) so it can cross the FFI boundary as a
    single scalar instead of a Lean structure. `UInt64.max` is the
    "no such room" / "capacity exceeded" sentinel. -/
def Id.pack (id : Id) : UInt64 := (id.index.toUInt64 <<< 32) ||| id.generation.toUInt64
def Id.unpack (v : UInt64) : Id :=
  { index := (v >>> 32).toUInt32, generation := (v &&& 0xFFFFFFFF).toUInt32 }

def SENTINEL : UInt64 := 0xFFFFFFFFFFFFFFFF

end Fanoutcore
