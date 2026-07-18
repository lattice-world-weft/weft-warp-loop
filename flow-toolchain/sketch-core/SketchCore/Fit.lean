import SketchCore.Vec3

/-! RDP polyline simplification + the Schneider recursive cubic-Bezier
    fitter ("An Algorithm for Automatically Fitting Digitized Curves",
    Graphics Gems 1990), matching the structure of cassie's
    `src/curves/cassie_curve_fit.cpp` / `rdp_simplify.cpp`.

    All math is `Float` (f64) with straight-line arithmetic - no platform
    intrinsics - so every peer computes bit-identical results from
    identical packets. -/

namespace SketchCore

/-- One cubic Bezier segment by absolute control points. -/
structure CubicBezier where
  p0 : Vec3
  p1 : Vec3
  p2 : Vec3
  p3 : Vec3
  deriving Repr, Inhabited

namespace CubicBezier

def eval (b : CubicBezier) (t : Float) : Vec3 :=
  let mt := 1.0 - t
  let b0 := mt * mt * mt
  let b1 := 3.0 * mt * mt * t
  let b2 := 3.0 * mt * t * t
  let b3 := t * t * t
  b0 * b.p0 + b1 * b.p1 + b2 * b.p2 + b3 * b.p3

def deriv1 (b : CubicBezier) (t : Float) : Vec3 :=
  let mt := 1.0 - t
  (3.0 * mt * mt) * (b.p1 - b.p0) + (6.0 * mt * t) * (b.p2 - b.p1)
    + (3.0 * t * t) * (b.p3 - b.p2)

def deriv2 (b : CubicBezier) (t : Float) : Vec3 :=
  (6.0 * (1.0 - t)) * (b.p2 - (2.0 : Float) * b.p1 + b.p0)
    + (6.0 * t) * (b.p3 - (2.0 : Float) * b.p2 + b.p1)

end CubicBezier

namespace Fit

/-- Drop consecutive duplicate points (mirrors `cassie_rdp_remove_duplicates`). -/
def removeDuplicates (pts : Array Vec3) : Array Vec3 := Id.run do
  if pts.size < 2 then
    return pts
  let mut out := #[pts[0]!]
  let mut prev := pts[0]!
  for i in [1:pts.size] do
    let cur := pts[i]!
    if !(cur == prev) then
      out := out.push cur
      prev := cur
  return out

/-- Ramer-Douglas-Peucker: returns the kept indices (always includes first
    and last). Recursive on the span; `partial` because the split index is
    data-dependent. -/
partial def rdpSpan (pts : Array Vec3) (eps : Float) (lo hi : Nat) : Array Nat :=
  if hi <= lo + 1 then
    #[]
  else Id.run do
    let a := pts[lo]!
    let b := pts[hi]!
    let mut maxD := 0.0
    let mut maxI := lo
    for i in [lo+1:hi] do
      let d := Vec3.distToLine pts[i]! a b
      if d > maxD then
        maxD := d
        maxI := i
    if maxD > eps then
      return rdpSpan pts eps lo maxI ++ #[maxI] ++ rdpSpan pts eps maxI hi
    else
      return #[]

/-- RDP reduce to kept indices, mirroring `cassie_rdp_reduce`'s contract. -/
def rdpReduce (pts : Array Vec3) (eps : Float) : Array Nat :=
  if pts.size == 0 then #[]
  else if pts.size == 1 then #[0]
  else if pts.size < 3 then #[0, 1]
  else #[0] ++ rdpSpan pts eps 0 (pts.size - 1) ++ #[pts.size - 1]

/-- Chord-length parameterization over [0,1]. -/
def chordLengthParameterize (pts : Array Vec3) : Array Float := Id.run do
  let n := pts.size
  let mut u := Array.mkEmpty n
  u := u.push 0.0
  for i in [1:n] do
    u := u.push (u[i-1]! + Vec3.distance pts[i]! pts[i-1]!)
  let total := u[n-1]!
  if total > 0.0 then
    let inv := 1.0 / total
    u := u.map (· * inv)
  return u

/-- Least-squares single-cubic fit given endpoint tangents (the classic
    `GenerateBezier` from Graphics Gems, with the Wu-Barsky fallback when
    the normal equations are degenerate). -/
def generateBezier (pts : Array Vec3) (u : Array Float)
    (tanA tanB : Vec3) : CubicBezier := Id.run do
  let n := pts.size
  if n < 2 then
    let p := if n == 1 then pts[0]! else Vec3.zero
    return { p0 := p, p1 := p, p2 := p, p3 := p }
  let v0 := pts[0]!
  let v3 := pts[n-1]!
  let mut c00 := 0.0
  let mut c01 := 0.0
  let mut c11 := 0.0
  let mut x0 := 0.0
  let mut x1 := 0.0
  for i in [0:n] do
    let t := u[i]!
    let mt := 1.0 - t
    let b0 := mt * mt * mt
    let b1 := 3.0 * mt * mt * t
    let b2 := 3.0 * mt * t * t
    let b3 := t * t * t
    let a0 := b1 * tanA
    let a1 := b2 * tanB
    let tmp := pts[i]! - ((b0 + b1) * v0 + (b2 + b3) * v3)
    c00 := c00 + Vec3.dot a0 a0
    c01 := c01 + Vec3.dot a0 a1
    c11 := c11 + Vec3.dot a1 a1
    x0 := x0 + Vec3.dot a0 tmp
    x1 := x1 + Vec3.dot a1 tmp
  let detC := c00 * c11 - c01 * c01
  let mut alphaL := 0.0
  let mut alphaR := 0.0
  if detC != 0.0 then
    alphaL := (x0 * c11 - x1 * c01) / detC
    alphaR := (c00 * x1 - c01 * x0) / detC
  -- Wu-Barsky heuristic when the solve is degenerate or collapses handles.
  let segLen := Vec3.distance v0 v3
  let epsilon := 1.0e-6 * segLen
  if alphaL < epsilon || alphaR < epsilon then
    let d := segLen / 3.0
    return { p0 := v0, p1 := v0 + d * tanA, p2 := v3 + d * tanB, p3 := v3 }
  return { p0 := v0, p1 := v0 + alphaL * tanA, p2 := v3 + alphaR * tanB, p3 := v3 }

/-- Max fit error and the index where it occurs. -/
def computeMaxError (pts : Array Vec3) (b : CubicBezier) (u : Array Float) :
    Float × Nat := Id.run do
  let n := pts.size
  let mut maxD := 0.0
  let mut split := n / 2
  for i in [0:n] do
    let d := Vec3.distance (b.eval u[i]!) pts[i]!
    if d > maxD then
      maxD := d
      split := i
  return (maxD, split)

/-- One Newton-Raphson step per sample: u' = u - ((Q(u)-P).Q'(u)) /
    (Q'(u).Q'(u) + (Q(u)-P).Q''(u)). -/
def reparameterize (b : CubicBezier) (pts : Array Vec3) (u : Array Float) :
    Array Float := Id.run do
  let mut out := Array.mkEmpty pts.size
  for i in [0:pts.size] do
    let t := u[i]!
    let d := b.eval t - pts[i]!
    let d1 := b.deriv1 t
    let d2 := b.deriv2 t
    let num := Vec3.dot d d1
    let den := Vec3.dot d1 d1 + Vec3.dot d d2
    out := out.push (if den == 0.0 then t else t - num / den)
  return out

/-- Recursive Schneider fit, mirroring `fit_curve_recursive` including its
    n==2 / n==3 degenerate handles, the <10x-error Newton refinement loop
    (max 20 iterations), and the tangent-mirroring subdivision. -/
partial def fitRecursive (pts : Array Vec3) (tanA tanB : Vec3) (err : Float) :
    Array CubicBezier :=
  let n := pts.size
  if n < 2 then
    #[]
  else if n == 2 then
    #[{ p0 := pts[0]!, p1 := pts[0]!, p2 := pts[1]!, p3 := pts[1]! }]
  else if n == 3 then
    #[{ p0 := pts[0]!, p1 := pts[1]!, p2 := pts[1]!, p3 := pts[2]! }]
  else Id.run do
    let maxIter := 20
    let mut u := chordLengthParameterize pts
    let mut b := generateBezier pts u tanA tanB
    let (e0, _) := computeMaxError pts b u
    let mut maxErr := e0
    if maxErr < err then
      return #[b]
    if maxErr < err * 10.0 then
      for _ in [0:maxIter] do
        let u2 := reparameterize b pts u
        let b2 := generateBezier pts u2 tanA tanB
        let (e2, _) := computeMaxError pts b2 u2
        b := b2
        u := u2
        maxErr := e2
        if maxErr < err then
          return #[b]
    -- Subdivide at the worst-fit point with mirrored split tangents.
    let (_, split) := computeMaxError pts b u
    let split := if split == 0 then 1 else if split >= n - 1 then n - 2 else split
    let tLeftLocal := Vec3.normalized (pts[split-1]! - pts[split]!)
    let tRightLocal := Vec3.normalized (pts[split]! - pts[split+1]!)
    let tSplit := Vec3.normalized ((0.5 : Float) * (tLeftLocal + tRightLocal))
    let left := pts.extract 0 (split + 1)
    let right := pts.extract split n
    return fitRecursive left tanA tSplit err ++ fitRecursive right (-tSplit) tanB err

/-- Full pipeline: dedup -> RDP -> endpoint tangents -> recursive fit.
    Mirrors `cassie_fit_curve`. Returns the composite cubic segments. -/
def fitCurve (pts : Array Vec3) (err rdpErr : Float) : Array CubicBezier :=
  let dedup := removeDuplicates pts
  if dedup.size < 2 then
    #[]
  else if dedup.size == 2 then
    #[{ p0 := dedup[0]!, p1 := dedup[0]!, p2 := dedup[1]!, p3 := dedup[1]! }]
  else
    let keep := rdpReduce dedup rdpErr
    let kept := keep.map (fun i => dedup[i]!)
    if kept.size < 2 then
      #[]
    else if kept.size == 2 then
      #[{ p0 := kept[0]!, p1 := kept[0]!, p2 := kept[1]!, p3 := kept[1]! }]
    else
      let tanA := Vec3.normalized (kept[1]! - kept[0]!)
      let tanB := Vec3.normalized (kept[kept.size-2]! - kept[kept.size-1]!)
      fitRecursive kept tanA tanB err

end Fit

end SketchCore
