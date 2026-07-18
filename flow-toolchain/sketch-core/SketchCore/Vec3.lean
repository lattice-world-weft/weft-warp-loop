namespace SketchCore

/-- 3D vector over `Float` (IEEE-754 f64). All core math runs in f64: the
    wire format carries f32, and f32 -> f64 conversion is exact, so every
    peer starts from identical doubles. -/
structure Vec3 where
  x : Float
  y : Float
  z : Float
  deriving Repr, Inhabited

namespace Vec3

def zero : Vec3 := ⟨0.0, 0.0, 0.0⟩

instance : BEq Vec3 where
  beq a b := a.x == b.x && a.y == b.y && a.z == b.z

instance : Add Vec3 := ⟨fun a b => ⟨a.x + b.x, a.y + b.y, a.z + b.z⟩⟩
instance : Sub Vec3 := ⟨fun a b => ⟨a.x - b.x, a.y - b.y, a.z - b.z⟩⟩
instance : Neg Vec3 := ⟨fun a => ⟨-a.x, -a.y, -a.z⟩⟩

def smul (s : Float) (v : Vec3) : Vec3 := ⟨s * v.x, s * v.y, s * v.z⟩

instance : HMul Float Vec3 Vec3 := ⟨smul⟩

def dot (a b : Vec3) : Float := a.x * b.x + a.y * b.y + a.z * b.z

def lengthSq (v : Vec3) : Float := dot v v

def length (v : Vec3) : Float := (lengthSq v).sqrt

def distance (a b : Vec3) : Float := length (a - b)

def normalized (v : Vec3) : Vec3 :=
  let l := length v
  if l > 0.0 then (1.0 / l : Float) * v else zero

def cross (a b : Vec3) : Vec3 :=
  ⟨a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x⟩

/-- Perpendicular distance from `p` to the infinite line through `a`-`b`.
    Degenerate chord (a == b) falls back to point distance. -/
def distToLine (p a b : Vec3) : Float :=
  let ab := b - a
  let l2 := lengthSq ab
  if l2 > 0.0 then
    let t := dot (p - a) ab / l2
    distance p (a + t * ab)
  else
    distance p a

/-- Distance from `p` to the closed segment `a`-`b`. -/
def distToSegment (p a b : Vec3) : Float :=
  let ab := b - a
  let l2 := lengthSq ab
  if l2 > 0.0 then
    let t := dot (p - a) ab / l2
    let t := if t < 0.0 then 0.0 else if t > 1.0 then 1.0 else t
    distance p (a + t * ab)
  else
    distance p a

end Vec3

end SketchCore
