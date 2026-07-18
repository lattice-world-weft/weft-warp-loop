-- Property tests for sketch-core (Plausible, same harness pattern as
-- fanout-core/TestProps.lean: checkIO + explicit NamedBinder wrappers,
-- runCheck exits non-zero on falsification).
import SketchCore
import Plausible

open SketchCore Plausible

/-- Floats that survive the f32 wire roundtrip exactly: small dyadic
    rationals built from a Nat seed. -/
def wireFloat (n : Nat) : Float :=
  ((n % 4096).toFloat - 2048.0) / 16.0

def mkSample (seed : Nat × Nat × Nat × Nat) : Sample :=
  let (a, b, c, d) := seed
  { pos := ⟨wireFloat a, wireFloat b, wireFloat c⟩, pressure := wireFloat d }

def mkPacket (peer stroke seq : Nat) (closed : Bool)
    (seeds : List (Nat × Nat × Nat × Nat)) : StrokePacket :=
  { peerId := peer.toUInt32
    strokeId := stroke.toUInt32
    seq := seq.toUInt16
    closed := closed
    samples := (seeds.map mkSample).toArray }

/-- Codec roundtrip. -/
def propRoundtrip (peer stroke seq : Nat) (closed : Bool)
    (seeds : List (Nat × Nat × Nat × Nat)) : Bool :=
  let p := mkPacket peer stroke seq closed seeds
  StrokePacket.decode p.encode == some p

/-- Decode is canonical: any bytes that decode also re-encode to the same
    bytes (no two byte strings map to the same packet silently). -/
def propCanonical (bytes : List Nat) : Bool :=
  let ba := ByteArray.mk ((bytes.map (·.toUInt8)).toArray)
  match StrokePacket.decode ba with
  | none => true
  | some p => p.encode == ba

/-- RDP invariants: kept indices strictly increasing, endpoints kept, and
    every dropped point lies within eps of the chord of its enclosing kept
    pair. -/
def propRdp (seeds : List (Nat × Nat × Nat × Nat)) (epsSeed : Nat) : Bool := Id.run do
  let pts := Fit.removeDuplicates ((seeds.map (fun s => (mkSample s).pos)).toArray)
  if pts.size < 3 then
    return true
  let eps := 0.01 + (epsSeed % 100).toFloat * 0.01
  let keep := Fit.rdpReduce pts eps
  -- strictly increasing, endpoints present
  if keep.size < 2 then
    return false
  if keep[0]! != 0 || keep[keep.size-1]! != pts.size - 1 then
    return false
  for i in [1:keep.size] do
    if keep[i-1]! >= keep[i]! then
      return false
  -- dropped points within eps of enclosing kept chord
  for k in [1:keep.size] do
    let lo := keep[k-1]!
    let hi := keep[k]!
    for i in [lo+1:hi] do
      if Vec3.distToLine pts[i]! pts[lo]! pts[hi]! > eps + 1.0e-9 then
        return false
  return true

/-- Fit preserves stroke endpoints (after dedup + RDP, which keep both). -/
def propFitEndpoints (seeds : List (Nat × Nat × Nat × Nat)) : Bool :=
  let pts := Fit.removeDuplicates ((seeds.map (fun s => (mkSample s).pos)).toArray)
  let segs := Fit.fitCurve pts Graph.FIT_ERROR Graph.RDP_ERROR
  if pts.size < 2 then
    segs.size == 0
  else
    segs.size > 0
      && segs[0]!.p0 == pts[0]!
      && segs[segs.size-1]!.p3 == pts[pts.size-1]!

/-- History dedup: applying the same packet twice accepts once. -/
def propDedup (peer stroke seq : Nat) (seeds : List (Nat × Nat × Nat × Nat)) : Bool :=
  let bytes := (mkPacket peer stroke seq false ((0,0,0,0) :: seeds)).encode
  let (h1, a1) := RoomHistory.empty.apply bytes
  let (h2, a2) := h1.apply bytes
  a1 == true && a2 == false && h2.packets.size == 1

/-- Within-stroke seq-reordering invariance: the chunks of one stroke may
    arrive in any order; the assembled graph JSON is identical. This is
    the wire-level convergence guarantee for a single stroke. -/
def propSeqOrderInvariance (peer stroke : Nat)
    (chunks : List (List (Nat × Nat × Nat × Nat))) (shuffleSeed : Nat) : Bool := Id.run do
  let chunks := chunks.take 6
  let n := chunks.length
  if n == 0 then
    return true
  let packets := (List.range n).map (fun i =>
    (mkPacket peer stroke i (i == n - 1) (chunks[i]!)).encode)
  -- deterministic pseudo-shuffle: rotate by seed, then reverse if odd
  let rot := shuffleSeed % n
  let shuffled := (packets.drop rot ++ packets.take rot)
  let shuffled := if shuffleSeed % 2 == 1 then shuffled.reverse else shuffled
  let apply (ps : List ByteArray) : String := Id.run do
    let mut h := RoomHistory.empty
    for p in ps do
      h := (h.apply p).1
    return h.graphJson
  return apply packets == apply shuffled

/-- Cyclomatic count: k disjoint closed squares produce exactly k cycles. -/
def propSquareCycles (kSeed : Nat) : Bool := Id.run do
  let k := kSeed % 4 + 1
  let mut h := RoomHistory.empty
  for i in [0:k] do
    let off := i.toFloat * 100.0
    let square : Array Sample :=
      #[⟨⟨off, 0, 0⟩, 1.0⟩, ⟨⟨off + 10.0, 0, 0⟩, 1.0⟩,
        ⟨⟨off + 10.0, 10.0, 0⟩, 1.0⟩, ⟨⟨off, 10.0, 0⟩, 1.0⟩]
    let p : StrokePacket :=
      { peerId := 1, strokeId := i.toUInt32, seq := 0, closed := true, samples := square }
    h := (h.apply p.encode).1
  return Graph.cycleCount (Graph.build (h.strokes)) == k

/-- Run one property; print the counterexample and exit non-zero on failure. -/
def runCheck (name : String) (p : Prop) [Testable p] (cfg : Configuration) : IO Unit := do
  IO.println s!"prop: {name}"
  match ← Testable.checkIO p cfg with
  | .success _ => pure ()
  | .gaveUp n =>
    IO.eprintln s!"  GAVE UP after {n} discarded test cases"
    IO.Process.exit 1
  | .failure _ counterexample n =>
    IO.eprintln s!"  FALSIFIED after {n} tests, counterexample:"
    for line in counterexample do
      IO.eprintln s!"    {line}"
    IO.Process.exit 1

def main : IO Unit := do
  let cfg : Configuration := { numInst := 300 }

  runCheck "CSP1 roundtrip: decode (encode p) = p"
    (NamedBinder "peer" <| ∀ (peer : Nat),
     NamedBinder "stroke" <| ∀ (stroke : Nat),
     NamedBinder "seq" <| ∀ (seq : Nat),
     NamedBinder "closed" <| ∀ (closed : Bool),
     NamedBinder "seeds" <| ∀ (seeds : List (Nat × Nat × Nat × Nat)),
       propRoundtrip peer stroke seq closed seeds = true) cfg

  runCheck "CSP1 canonical: decodable bytes re-encode identically"
    (NamedBinder "bytes" <| ∀ (bytes : List Nat),
       propCanonical bytes = true) cfg

  runCheck "RDP: monotone kept indices, endpoints kept, dropped points within eps"
    (NamedBinder "seeds" <| ∀ (seeds : List (Nat × Nat × Nat × Nat)),
     NamedBinder "epsSeed" <| ∀ (epsSeed : Nat),
       propRdp seeds epsSeed = true) cfg

  runCheck "fit preserves stroke endpoints"
    (NamedBinder "seeds" <| ∀ (seeds : List (Nat × Nat × Nat × Nat)),
       propFitEndpoints seeds = true) cfg

  runCheck "history rejects duplicate (peer,stroke,seq)"
    (NamedBinder "peer" <| ∀ (peer : Nat),
     NamedBinder "stroke" <| ∀ (stroke : Nat),
     NamedBinder "seq" <| ∀ (seq : Nat),
     NamedBinder "seeds" <| ∀ (seeds : List (Nat × Nat × Nat × Nat)),
       propDedup peer stroke seq seeds = true) cfg

  runCheck "graph invariant under within-stroke seq reordering"
    (NamedBinder "peer" <| ∀ (peer : Nat),
     NamedBinder "stroke" <| ∀ (stroke : Nat),
     NamedBinder "chunks" <| ∀ (chunks : List (List (Nat × Nat × Nat × Nat))),
     NamedBinder "shuffleSeed" <| ∀ (shuffleSeed : Nat),
       propSeqOrderInvariance peer stroke chunks shuffleSeed = true) cfg

  runCheck "k disjoint closed squares => k cycles"
    (NamedBinder "kSeed" <| ∀ (kSeed : Nat),
       propSquareCycles kSeed = true) cfg

  IO.println "ALL PROPERTY TESTS PASSED"
