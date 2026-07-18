import SketchCore.Fit

/-! The sketch graph: strokes -> nodes (merged endpoints + stroke/stroke
    intersections) -> segments (stroke spans between nodes) -> cycle count.

    PR-1 scope note: intersections are computed on the tessellated
    polylines of the fitted curves (cassie's full planar arrangement with
    exact Bezier/Bezier intersection - upstream
    `lean/CassieAvbd/CycleDetect/` - is a later phase). The cycle count is
    the graph-theoretic cyclomatic number E - V + C, which is exactly the
    number of independent closed loops in the sketch.

    Everything is deterministic: fixed tessellation density, insertion-
    ordered nodes with epsilon merge, and integer-quantized JSON output so
    no float-formatting variance can leak into the convergence contract. -/

namespace SketchCore

/-- Tessellation density per cubic segment. Fixed forever: changing it
    changes every peer's graph, so it is part of the protocol. -/
def SAMPLES_PER_SEGMENT : Nat := 16

/-- Node/intersection merge tolerance, in model units. -/
def NODE_EPS : Float := 1.0e-3

structure Stroke where
  peerId   : UInt32
  strokeId : UInt32
  closed   : Bool
  /-- Raw wire samples in arrival order (concatenated across `seq`). -/
  samples  : Array Vec3
  deriving Repr, Inhabited

structure GraphNode where
  pos : Vec3
  deriving Repr, Inhabited

structure GraphSegment where
  strokeIdx : Nat  -- index into the stroke array
  nodeA     : Nat  -- node ids
  nodeB     : Nat
  deriving Repr, Inhabited

structure SketchGraph where
  nodes    : Array GraphNode
  segments : Array GraphSegment
  /-- Per-stroke tessellated polylines (diagnostics / clients). -/
  polylines : Array (Array Vec3)
  deriving Repr, Inhabited

namespace Graph

def FIT_ERROR : Float := 0.02
def RDP_ERROR : Float := 0.01

/-- Deterministic tessellation of a fitted composite curve. -/
def tessellate (segs : Array CubicBezier) : Array Vec3 := Id.run do
  if segs.size == 0 then
    return #[]
  let mut out := #[segs[0]!.p0]
  for b in segs do
    for i in [1:SAMPLES_PER_SEGMENT+1] do
      let t := i.toFloat / SAMPLES_PER_SEGMENT.toFloat
      out := out.push (b.eval t)
  return out

/-- Find-or-insert a node within `NODE_EPS` (first match in insertion
    order wins - deterministic). -/
def internNode (nodes : Array GraphNode) (p : Vec3) : Array GraphNode × Nat := Id.run do
  for i in [0:nodes.size] do
    if Vec3.distance nodes[i]!.pos p < NODE_EPS then
      return (nodes, i)
  return (nodes.push { pos := p }, nodes.size)

/-- Closest-approach parameters of segments a0-a1 and b0-b1, clamped to
    [0,1]^2; returns (ta, tb, distance). Straight-line float math only. -/
def segmentClosest (a0 a1 b0 b1 : Vec3) : Float × Float × Float := Id.run do
  let d1 := a1 - a0
  let d2 := b1 - b0
  let r := a0 - b0
  let a := Vec3.dot d1 d1
  let e := Vec3.dot d2 d2
  let f := Vec3.dot d2 r
  let mut s := 0.0
  let mut t := 0.0
  if a > 0.0 || e > 0.0 then
    let b := Vec3.dot d1 d2
    let c := Vec3.dot d1 r
    let denom := a * e - b * b
    if denom != 0.0 then
      s := (b * f - c * e) / denom
    s := if s < 0.0 then 0.0 else if s > 1.0 then 1.0 else s
    if e > 0.0 then
      t := (b * s + f) / e
      if t < 0.0 then
        t := 0.0
        if a > 0.0 then
          s := -c / a
          s := if s < 0.0 then 0.0 else if s > 1.0 then 1.0 else s
      else if t > 1.0 then
        t := 1.0
        if a > 0.0 then
          s := (b - c) / a
          s := if s < 0.0 then 0.0 else if s > 1.0 then 1.0 else s
  let pa := a0 + s * d1
  let pb := b0 + t * d2
  return (s, t, Vec3.distance pa pb)

/-- Split parameters (cumulative polyline parameter in [0, len-1]) where a
    stroke's polyline passes within `NODE_EPS` of another stroke. -/
def crossingParams (poly other : Array Vec3) : Array Float := Id.run do
  let mut out := #[]
  if poly.size < 2 || other.size < 2 then
    return out
  for i in [0:poly.size-1] do
    let mut best : Option (Float × Float) := none  -- (param, dist)
    for j in [0:other.size-1] do
      let (s, _, d) := segmentClosest poly[i]! poly[i+1]! other[j]! other[j+1]!
      if d < NODE_EPS then
        match best with
        | some (_, bd) => if d < bd then best := some (i.toFloat + s, d)
        | none => best := some (i.toFloat + s, d)
    match best with
    | some (p, _) => out := out.push p
    | none => pure ()
  return out

/-- Point on a polyline at cumulative parameter `t` in [0, len-1]. -/
def polyAt (poly : Array Vec3) (t : Float) : Vec3 :=
  let n := poly.size
  if n == 0 then Vec3.zero
  else if n == 1 then poly[0]!
  else
    let t := if t < 0.0 then 0.0 else if t > (n-1).toFloat then (n-1).toFloat else t
    let i := t.floor.toUInt64.toNat
    let i := if i >= n - 1 then n - 2 else i
    let u := t - i.toFloat
    poly[i]! + u * (poly[i+1]! - poly[i]!)

/-- Deduplicate + sort split parameters (insertion sort - small arrays,
    deterministic). Two params within half a tessellation step collapse. -/
def canonicalParams (ps : Array Float) : Array Float := Id.run do
  let mut sorted : Array Float := #[]
  for p in ps do
    let mut inserted := false
    let mut out : Array Float := #[]
    for q in sorted do
      if !inserted && p < q then
        out := (out.push p).push q
        inserted := true
      else
        out := out.push q
    if !inserted then
      out := out.push p
    sorted := out
  let mut dedup : Array Float := #[]
  for p in sorted do
    if dedup.size == 0 || p - dedup[dedup.size-1]! > 0.5 then
      dedup := dedup.push p
  return dedup

/-- Build the sketch graph from finished strokes. -/
def build (strokes : Array Stroke) : SketchGraph := Id.run do
  -- 1. Fit + tessellate every stroke.
  let mut polys : Array (Array Vec3) := #[]
  for s in strokes do
    let segs := Fit.fitCurve s.samples FIT_ERROR RDP_ERROR
    let mut poly := tessellate segs
    if s.closed && poly.size > 1 then
      poly := poly.push poly[0]!
    polys := polys.push poly
  -- 2. Split params per stroke: endpoints + crossings with every other stroke.
  let mut nodes : Array GraphNode := #[]
  let mut segments : Array GraphSegment := #[]
  for i in [0:polys.size] do
    let poly := polys[i]!
    if poly.size < 2 then
      continue
    let mut rawParams : Array Float := #[0.0, (poly.size - 1).toFloat]
    for j in [0:polys.size] do
      if j != i then
        rawParams := rawParams ++ crossingParams poly polys[j]!
    let params := canonicalParams rawParams
    -- 3. Intern nodes at split points; emit one graph segment per span.
    -- The span test is on the polyline PARAMETER, not node identity: a
    -- closed stroke's two endpoints intern to the same node, and that
    -- self-loop is a real cycle-carrying edge, not a degenerate span.
    let mut prevNode : Option (Nat × Float) := none
    for t in params do
      let (nodes', id) := internNode nodes (polyAt poly t)
      nodes := nodes'
      match prevNode with
      | some (prev, prevT) =>
        if t - prevT > 0.5 then
          segments := segments.push { strokeIdx := i, nodeA := prev, nodeB := id }
      | none => pure ()
      prevNode := some (id, t)
  return { nodes := nodes, segments := segments, polylines := polys }

/-- Connected-component count via union-find over segment endpoints
    (iterative path lookup; arrays are tiny). -/
def componentCount (g : SketchGraph) : Nat := Id.run do
  let n := g.nodes.size
  if n == 0 then
    return 0
  let mut parent := Array.range n
  for s in g.segments do
    -- find roots (bounded walk: parent chain length <= n)
    let mut ra := s.nodeA
    for _ in [0:n] do
      if parent[ra]! != ra then ra := parent[ra]!
    let mut rb := s.nodeB
    for _ in [0:n] do
      if parent[rb]! != rb then rb := parent[rb]!
    if ra != rb then
      parent := parent.set! rb ra
  let mut count := 0
  for i in [0:n] do
    if parent[i]! == i then
      count := count + 1
  return count

/-- Number of independent cycles: E - V + C (cyclomatic number). -/
def cycleCount (g : SketchGraph) : Nat :=
  let e := g.segments.size
  let v := g.nodes.size
  let c := componentCount g
  if e + c >= v then e + c - v else 0

/-- Quantize a coordinate to integer micro-units for JSON output. Float
    formatting differs across runtimes; integers never do. -/
def toMicro (x : Float) : Int :=
  let scaled := x * 1.0e6
  let r := if scaled >= 0.0 then (scaled + 0.5).floor else (scaled - 0.5).ceil
  -- Float -> Int via string-free path: split sign over UInt64.
  if r >= 0.0 then Int.ofNat r.toUInt64.toNat else -Int.ofNat (-r).toUInt64.toNat

/-- Canonical sketch-graph JSON (cassie-sketch-graph shaped): stable key
    order, integer-quantized positions, no floats anywhere. -/
def toJson (strokes : Array Stroke) (g : SketchGraph) : String := Id.run do
  let mut out := "{\"nodes\":["
  for i in [0:g.nodes.size] do
    if i > 0 then out := out ++ ","
    let p := g.nodes[i]!.pos
    out := out ++ s!"\{\"id\":{i},\"pos_micro\":[{toMicro p.x},{toMicro p.y},{toMicro p.z}]}"
  out := out ++ "],\"segments\":["
  for i in [0:g.segments.size] do
    if i > 0 then out := out ++ ","
    let s := g.segments[i]!
    let strokeId := strokes[s.strokeIdx]!.strokeId
    let peerId := strokes[s.strokeIdx]!.peerId
    out := out ++ s!"\{\"id\":{i},\"peer_id\":{peerId},\"stroke_id\":{strokeId},\"nodes\":[{s.nodeA},{s.nodeB}]}"
  out := out ++ s!"],\"cycles\":{cycleCount g}}"
  return out

end Graph

end SketchCore
