# Compile List/Array content against SlotMap-shaped fixed-capacity collections, never a real allocator

## Status

Accepted; refines [ADR 0026](0026-closures-and-lists-are-required-not-deferred.md)'s
open "fixed-capacity array or real allocator" question. Not yet
implemented.

## Decision

`fanout-core/Fanoutcore/SlotMap.lean` already carries the right design
for compiled list/array content: `Array.replicate capacity` at
construction (no growth, no separate allocation events), every access
bounds-checked (`if h : idx < m.slots.size`, never a panicking `[i]!`),
property-tested (`test_ffi.c`'s free-then-recycle-then-check case).
Reusing this shape — a statically-sized backing buffer, sized at compile
time, reserved as ordinary `.bss`/`.data` in the compiled ELF — resolves
ADR 0026's open question in favor of "fixed-capacity, no allocator": a
freestanding guest with a static buffer never needs `malloc`/GC at all,
consistent with ADR 0006's zero-syscall, minimal-footprint model, and
needs no new runtime support beyond bounds-checked indexing (already
implemented for scalars in checkpoint 2's restricted IR translator, just
not yet extended to array element access).

Checked against real content, not assumed: `loot/core/LootCore/Loot.lean`'s
`LootTable := List (Item × Weight)` carries no static bound today, and
`pick` recurses structurally over it rather than iterating a
fixed-capacity buffer — the SlotMap shape doesn't apply to this code
as currently written. Reusing SlotMap's *design* doesn't make existing
`combat`/`progression`/`loot` source compilable for free; those repos'
own collection types would need to move to something SlotMap-shaped (a
capacity-bounded `Array`, not a plain unbounded `List`) before this
compiler could accept them, and unbounded structural recursion (`pick`'s
own shape) needs a further loop-conversion step regardless of collection
representation.

## Consequences

Good: the memory-representation question is settled without inventing
anything new — reuse a pattern this codebase already designed,
implemented, and property-tested for exactly this reason (bounded,
replay-deterministic collections), rather than building a general
dynamic-allocation story the freestanding guest model was specifically
chosen to avoid. Bad: this pushes real work onto the content side, not
just the compiler side — `combat`/`progression`/`loot`'s existing
`List`-typed fields aren't compilable as-is and would need retyping to a
bounded representation, a cross-repo content change this ADR doesn't
scope or schedule. Recursive functions over those collections (`loot`'s
`pick`) need a structural-recursion-to-loop transform on top of the
array-representation change — a second, separable piece of new compiler
work, not solved by the collection-representation decision alone.
