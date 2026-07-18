import SketchCore.Codec
import SketchCore.Graph

/-! Per-room packet history: the append-only, deduplicated log of CSP1
    packets. Because the whole pipeline is deterministic, the log IS the
    room state - late-join sync is "replay the log", and convergence means
    "same log => same graph". -/

namespace SketchCore

structure RoomHistory where
  /-- Raw packets in accepted order. -/
  packets : Array ByteArray
  /-- Dedup keys of accepted packets: (peerId, strokeId, seq). -/
  seen : Array (UInt32 × UInt32 × UInt16)
  deriving Inhabited

namespace RoomHistory

def empty : RoomHistory := { packets := #[], seen := #[] }

def key (p : StrokePacket) : UInt32 × UInt32 × UInt16 := (p.peerId, p.strokeId, p.seq)

/-- Apply an inbound packet: validate, dedup, append. Returns the new
    history and whether the packet was accepted (relay-worthy). -/
def apply (h : RoomHistory) (bytes : ByteArray) : RoomHistory × Bool :=
  match StrokePacket.decode bytes with
  | none => (h, false)
  | some p =>
    if h.seen.contains (key p) then
      (h, false)
    else
      ({ packets := h.packets.push bytes, seen := h.seen.push (key p) }, true)

/-- Assemble strokes from the log: packets with the same (peer, stroke)
    concatenate in seq order (the log already holds them in accepted
    order; we sort per-stroke by seq for robustness against reordering). -/
def strokes (h : RoomHistory) : Array Stroke := Id.run do
  -- Group by (peerId, strokeId), then order groups CANONICALLY by that key:
  -- peers see the same packets in different orders (a peer's own strokes
  -- apply before the relay round-trip), and graph node numbering follows
  -- stroke order - so convergence requires the graph to be a function of
  -- the packet SET, not the arrival sequence.
  let mut order : Array (UInt32 × UInt32) := #[]
  let mut groups : Array (Array StrokePacket) := #[]
  for bytes in h.packets do
    match StrokePacket.decode bytes with
    | none => pure ()
    | some p =>
      let gk := (p.peerId, p.strokeId)
      let mut found := false
      for i in [0:order.size] do
        if order[i]! == gk then
          groups := groups.set! i (groups[i]!.push p)
          found := true
      if !found then
        order := order.push gk
        groups := groups.push #[p]
  -- Canonical group order: insertion sort by (peerId, strokeId).
  let mut sortedIdx : Array Nat := #[]
  for i in [0:order.size] do
    let (pi, si) := order[i]!
    let mut inserted := false
    let mut acc : Array Nat := #[]
    for j in sortedIdx do
      let (pj, sj) := order[j]!
      if !inserted && (pi < pj || (pi == pj && si < sj)) then
        acc := (acc.push i).push j
        inserted := true
      else
        acc := acc.push j
    if !inserted then
      acc := acc.push i
    sortedIdx := acc
  let mut out : Array Stroke := #[]
  for i in sortedIdx do
    let g := groups[i]!
    -- insertion sort by seq (tiny arrays, deterministic)
    let mut sorted : Array StrokePacket := #[]
    for p in g do
      let mut inserted := false
      let mut acc : Array StrokePacket := #[]
      for q in sorted do
        if !inserted && p.seq < q.seq then
          acc := (acc.push p).push q
          inserted := true
        else
          acc := acc.push q
      if !inserted then
        acc := acc.push p
      sorted := acc
    let mut samples : Array Vec3 := #[]
    let mut closed := false
    for p in sorted do
      samples := samples ++ p.samples.map (·.pos)
      closed := closed || p.closed
    let (peerId, strokeId) := order[i]!
    out := out.push { peerId := peerId, strokeId := strokeId, closed := closed, samples := samples }
  return out

/-- The convergence artifact: canonical graph JSON of the replayed log. -/
def graphJson (h : RoomHistory) : String :=
  let ss := strokes h
  Graph.toJson ss (Graph.build ss)

end RoomHistory

end SketchCore
