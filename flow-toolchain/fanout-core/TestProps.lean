-- Property tests for the fanout-core kernel (Plausible, QuickCheck-style).
--
-- The heart is model-based: random operation sequences (alloc / free /
-- update / adversarial garbage ids) run against both the real SlotMap and a
-- trivially-correct model (a flat list of live (id, value) pairs); after
-- every step the two must agree on `find` for every id ever observed. On
-- top of that, allocation freshness (a returned id never equals any id
-- returned before - the generational guarantee) and full-capacity behavior
-- are asserted inline, and Room's fanout algebra is checked directly.
import Fanoutcore.FanoutCore
import Fanoutcore.Zone
import Plausible

open Fanoutcore Plausible

/-- Simulation state: the real map, the model, and the id sets used for
    checking. `allocated` is every id `alloc` ever returned; `observed`
    additionally includes synthesized garbage ids. -/
structure Sim where
  map       : SlotMap Nat
  model     : List (Id × Nat)
  allocated : List Id
  observed  : List Id
  ok        : Bool

/-- The core agreement invariant: real map and model see the same value (or
    same absence) for every id we have ever touched. -/
def checkConsistent (s : Sim) : Bool :=
  s.observed.all fun id =>
    match s.map.find id, s.model.find? (fun e => e.1 == id) with
    | some v, some (_, mv) => v == mv
    | none, none => true
    | _, _ => false

def addObserved (l : List Id) (id : Id) : List Id :=
  if l.contains id then l else l ++ [id]

/-- One decoded operation. `(code, a, b)`: code selects the op, `a`/`b`
    are its arguments (index into observed ids, value, or garbage bits). -/
def step (cap : Nat) (s : Sim) (op : Nat × Nat × Nat) : Sim :=
  if !s.ok then s
  else
    let (code, a, b) := op
    let s' :=
      match code % 4 with
      | 0 => -- alloc
        match s.map.alloc a with
        | some (m', id) =>
          -- Generational freshness: never re-issue any previously returned id.
          let fresh := !(s.allocated.contains id)
          { s with
            map := m'
            model := (id, a) :: s.model
            allocated := s.allocated ++ [id]
            observed := addObserved s.observed id
            ok := s.ok && fresh }
        | none =>
          -- alloc may only fail when every slot is live.
          { s with ok := s.ok && (s.model.length == cap) }
      | 1 => -- free an observed id (live, stale, or garbage - all must be safe)
        match s.observed[a % (s.observed.length.max 1)]? with
        | some id =>
          { s with map := s.map.free id
                   model := s.model.filter (fun (e : Id × Nat) => e.1 != id) }
        | none => s
      | 2 => -- update an observed id (stale/garbage must be a no-op)
        match s.observed[a % (s.observed.length.max 1)]? with
        | some id =>
          { s with
            map := s.map.update id b
            model := s.model.map (fun (e : Id × Nat) => if e.1 == id then (e.1, b) else e) }
        | none => s
      | _ => -- synthesize an adversarial id (in- or out-of-range, any gen) and free it
        let gid : Id := { index := UInt32.ofNat (a % (cap + 3)), generation := UInt32.ofNat (b % 4) }
        { s with
          map := s.map.free gid
          model := s.model.filter (fun (e : Id × Nat) => e.1 != gid)
          observed := addObserved s.observed gid }
    { s' with ok := s'.ok && checkConsistent s' }

def runOps (capSeed : Nat) (ops : List (Nat × Nat × Nat)) : Bool :=
  let cap := capSeed % 5 + 1 -- small capacities keep the freelist churning
  let init : Sim :=
    { map := SlotMap.empty cap, model := [], allocated := [], observed := [], ok := true }
  (ops.foldl (step cap) init).ok

/-- Build a Room by subscribing a list of connection ids. -/
def roomFrom (l : List Nat) : Room :=
  l.foldl (fun r c => r.sub c.toUInt64) Room.empty

/-- Exhaustively checks `hilbertIndexOfGrid bits` is a bijection from the
    `2^bits`-per-axis grid onto `[0, 2^(3*bits))`: every grid cell maps to
    a distinct index, and every index in range is hit by some cell. Real
    coverage, not a sample - Skilling's algorithm is well-known, but this
    verifies *this* Lean4 transcription of it rather than trusting memory.
    `bits = 3` keeps this small (512 cells) while still exercising every
    branch of the bit-level loop at least twice. -/
def hilbertIsBijective (bits : Nat) : Bool := Id.run do
  let n := 2 ^ bits
  let total := n * n * n
  let mut seen : Array Bool := Array.replicate total false
  for xi in List.range n do
    for yi in List.range n do
      for zi in List.range n do
        let idx := hilbertIndexOfGrid bits xi.toUInt64 yi.toUInt64 zi.toUInt64
        let idxN := idx.toNat
        if idxN >= total then
          return false -- out of range: not a valid index
        if seen[idxN]! then
          return false -- collision: not injective
        seen := seen.set! idxN true
  return seen.all id -- surjective: every index in range was hit

/-- Builds disjoint, contiguous zone ranges by prefix-summing a list of
    lengths (each clamped to at least 1 so no range is empty) - disjoint by
    construction, so `authorityForIndex`/`disjointRanges` are tested
    against inputs guaranteed to satisfy their precondition rather than
    relying on independently-random ranges happening not to overlap. -/
def zonesFromLengths (lens : List Nat) : Array Zone :=
  let lens := lens.map (· + 1)
  let starts := (lens.foldl (fun (acc : List Nat × Nat) len => (acc.1 ++ [acc.2], acc.2 + len)) ([], 0)).1
  (List.zip starts lens).toArray.map fun (s, len) =>
    { range := { start := s.toUInt64, stop := (s + len).toUInt64 }, entities := #[] }

/-- Picks an index within the total span of `zonesFromLengths lens` (or 0
    for the degenerate empty-`lens` case) from `seed`. -/
def idxFromSeed (lens : List Nat) (seed : Nat) : UInt64 :=
  let zones := zonesFromLengths lens
  if h : zones.size > 0 then
    let totalSpan := (zones[zones.size - 1]).range.stop
    (seed % totalSpan.toNat.max 1).toUInt64
  else 0

/-- True iff `authorityForIndex`, given disjoint zones built from `lens`,
    finds a zone whose range actually contains the picked index - vacuously
    true for the degenerate empty-`lens` case. -/
def authorityContainsCheck (lens : List Nat) (seed : Nat) : Bool :=
  let zones := zonesFromLengths lens
  if zones.size == 0 then true
  else
    let idx := idxFromSeed lens seed
    match authorityForIndex zones idx with
    | none => false -- every idx < totalSpan must land in some zone, by construction
    | some i => (zones[i]!).range.contains idx

/-- True iff `authorityForIndex`'s answer is the *unique* zone containing
    the picked index, given disjoint zones built from `lens`. -/
def authorityUniqueCheck (lens : List Nat) (seed : Nat) : Bool :=
  let zones := zonesFromLengths lens
  if zones.size == 0 then true
  else
    let idx := idxFromSeed lens seed
    match authorityForIndex zones idx with
    | none => true
    | some i => ((List.range zones.size).filter fun j => (zones[j]!).range.contains idx) == [i]

/-- True iff `adjacentZones`, given zones built from `lens`, never includes
    the zone whose neighbours were asked for - vacuously true when `lens`
    is empty. -/
def adjacentExcludesSelfCheck (lens : List Nat) (seed : Nat) : Bool :=
  let zones := zonesFromLengths lens
  if zones.size == 0 then true
  else
    let zoneIdx := seed % zones.size
    !(adjacentZones zones zoneIdx).contains zoneIdx

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

-- Plausible's Testable instances for quantifiers match on `NamedBinder`
-- wrappers (its `#eval`-level front end adds them via macro); executables
-- using `checkIO` directly must write them out.
def main : IO Unit := do
  let cfg : Configuration := { numInst := 500 }

  runCheck "slot map agrees with model under random op sequences \
            (find consistency, id freshness, stale/garbage safety, capacity)"
    (NamedBinder "capSeed" <| ∀ (capSeed : Nat),
     NamedBinder "ops" <| ∀ (ops : List (Nat × Nat × Nat)),
       runOps capSeed ops = true) cfg

  runCheck "fanout targets never include the publisher"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "p" <| ∀ (p : Nat),
      ((roomFrom l).targets p.toUInt64).contains p.toUInt64 = false) cfg

  runCheck "sub is idempotent"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "c" <| ∀ (c : Nat),
      (((roomFrom l).sub c.toUInt64).sub c.toUInt64).subscribers
        = ((roomFrom l).sub c.toUInt64).subscribers) cfg

  runCheck "after unsub, the connection is gone"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "c" <| ∀ (c : Nat),
      (((roomFrom l).unsub c.toUInt64).subscribers.contains c.toUInt64) = false) cfg

  runCheck "a subscriber receives publishes from anyone else"
    (NamedBinder "l" <| ∀ (l : List Nat),
     NamedBinder "c" <| ∀ (c : Nat),
     NamedBinder "p" <| ∀ (p : Nat),
     NamedBinder "h" <|
      c.toUInt64 ≠ p.toUInt64 →
        (((roomFrom l).sub c.toUInt64).targets p.toUInt64).contains c.toUInt64 = true) cfg

  IO.println "prop: hilbertIndexOfGrid is a bijection over a small exhaustive grid (bits = 3)"
  if !hilbertIsBijective 3 then
    IO.eprintln "  FALSIFIED: hilbertIndexOfGrid 3 is not a bijection over the 8x8x8 grid"
    IO.Process.exit 1

  runCheck "zones built from contiguous lengths are always disjoint"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
      disjointRanges ((zonesFromLengths lens).map Zone.range) = true) cfg

  runCheck "authorityForIndex, given disjoint zones, finds a zone whose range actually contains the index"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "seed" <| ∀ (seed : Nat),
      authorityContainsCheck lens seed = true) cfg

  runCheck "authorityForIndex's answer is the *unique* zone containing the index, given disjoint zones"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "seed" <| ∀ (seed : Nat),
      authorityUniqueCheck lens seed = true) cfg

  runCheck "adjacentZones never includes the zone itself"
    (NamedBinder "lens" <| ∀ (lens : List Nat),
     NamedBinder "seed" <| ∀ (seed : Nat),
      adjacentExcludesSelfCheck lens seed = true) cfg

  IO.println "ALL PROPERTY TESTS PASSED"
