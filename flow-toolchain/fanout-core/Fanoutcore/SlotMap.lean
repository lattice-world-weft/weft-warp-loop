namespace Fanoutcore

/-- A slot map (generational index): a fixed-capacity array of optional
    entries, each entry tagged with a generation counter. `alloc` reuses
    the lowest free index (a plain freelist) and bumps its generation;
    `find` on a stale/recycled generation, or an out-of-range index,
    returns `none` rather than aliasing whatever was later allocated
    into that same index or panicking. This is the same shape as
    Niklas Frykholm's "Data Arrays" and the `twiggler/slotmap` C++
    library — this is our own Lean4 code, not a port of either. -/

structure Id where
  index      : UInt32
  generation : UInt32
  deriving Repr, BEq

/-- Every slot always carries its current generation, occupied or not —
    `free` must NOT erase it, only clear the value, or a later `alloc`
    recycling that index would restart at generation 0 and collide with
    the very first allocation there (this was a real bug: caught by
    `test_ffi.c`'s free-then-recycle-then-check-the-old-id case). -/
structure SlotMap (α : Type) where
  slots       : Array (UInt32 × Option α)  -- (generation, value-if-occupied) per index
  freeList    : Array UInt32
  deriving Repr, Inhabited

def SlotMap.empty (capacity : Nat) : SlotMap α :=
  { slots := Array.replicate capacity (0, none)
    freeList := (Array.range capacity).reverse.map UInt32.ofNat }

/-- Every id this module hands back to a caller (from `alloc`) always
    has an in-range index by construction (the freelist only ever holds
    indices `< slots.size`). Every id a caller hands *in* (`find`,
    `free`, `update`) is untrusted — it may be stale, garbage, or
    outright adversarial — so every operation here checks bounds first
    (`idx < m.slots.size`) before any indexing, never relying on the
    panicking `[i]!` for an out-of-range access. -/
def SlotMap.find (m : SlotMap α) (id : Id) : Option α :=
  let idx := id.index.toNat
  if h : idx < m.slots.size then
    let (g, v) := m.slots[idx]
    if g == id.generation then v else none
  else none

def SlotMap.alloc (m : SlotMap α) (v : α) : Option (SlotMap α × Id) :=
  match m.freeList.back? with
  | none => none
  | some idx =>
    let freeList := m.freeList.pop
    let idxN := idx.toNat
    if h : idxN < m.slots.size then
      let (prevGen, _) := m.slots[idxN]
      let gen := prevGen + 1
      let slots := m.slots.set idxN (gen, some v)
      some ({ m with slots := slots, freeList := freeList }, { index := idx, generation := gen })
    else none

def SlotMap.free (m : SlotMap α) (id : Id) : SlotMap α :=
  let idx := id.index.toNat
  if h : idx < m.slots.size then
    let (g, v) := m.slots[idx]
    if g == id.generation && v.isSome then
      { m with slots := m.slots.set idx (g, none), freeList := m.freeList.push id.index }
    else m
  else m

def SlotMap.update (m : SlotMap α) (id : Id) (v : α) : SlotMap α :=
  let idx := id.index.toNat
  if h : idx < m.slots.size then
    let (g, cur) := m.slots[idx]
    if g == id.generation && cur.isSome then { m with slots := m.slots.set idx (g, some v) }
    else m
  else m

end Fanoutcore
