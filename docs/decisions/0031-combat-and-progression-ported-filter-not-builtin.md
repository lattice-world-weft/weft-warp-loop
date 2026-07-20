# Combat and progression ported to s7; `filter` is not a builtin in this s7 build

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/content/{combat,progression}.scm`, plus
their golden-vector tests).

## Decision

Extended checkpoint 2/3's methodology ([ADR 0030](0030-ported-content-lives-under-riscv-guests-content.md))
to `v-sekai-multiplayer-fabric/combat`'s `Core.lean` (the combo/
invulnerability/damage reducer — a `State` struct, tagged `Event`/
`Effect` unions, an immutable-update reducer) and `progression`'s
`Core.lean` (inventory/affinity-gate/credits — the exact
`map`/`filter`/`find?`/`any` pattern over `List` that
[ADR 0026](0026-closures-and-lists-are-required-not-deferred.md)
originally flagged as blocking the AOT compiler). Both hand-ported
line-for-line, structures represented as fixed-slot vectors with named
accessors, tagged unions as `(list 'tag data...)` or bare symbols for
zero-argument constructors, each `{ s with f := v }` site as an explicit
reconstructor call.

Real finding during porting, not assumed: `filter` throws `unbound
variable` in this s7 build, while `map`/`assoc`/`member` all resolve
fine — this toolchain's build flags (`-DWITH_SYSTEM_EXTRAS=0`, per ADR
0006) apparently exclude whatever library file would normally define
it. Defined locally in `progression.scm` (a four-line recursive
definition) rather than assuming a library load path exists. This is
the first concrete evidence of ADR 0026's own point playing out in
reverse: not "s7 can't do this," but "s7 already can, once one small
gap in this specific build's standard-library surface is noticed and
closed inline" — a five-minute fix, not new compiler engineering.

Golden vectors, both checked against freshly-computed Lean4 references
and cross-machine determinism simultaneously: combat (spawn, 30 ticks,
one opener attack → `enemyHp = 90`, `339498` instructions, both
machines identical); progression (`grant 1, grant 1, sell 1 50, train,
buyArt 1` → `credits = 150`, `271360` instructions, both machines
identical).

## Consequences

Good: two more real gameplay-logic files proven to run correctly and
deterministically under interpretation, with the exact `List`
combinator patterns ADR 0026 was worried about now demonstrated
working, not just claimed to work in principle. The missing-`filter`
gap is now known and cheap to work around for any future port hitting
the same builtin. Bad: only `credits`/`enemyHp` (single scalar fields)
were checked per port, not the full `Profile`/`State` record or the
effects lists — `items`/`arts`/full effect sequences remain unverified
beyond visual inspection; a future pass could extend each golden-vector
test to compare the whole structure, not one field.
