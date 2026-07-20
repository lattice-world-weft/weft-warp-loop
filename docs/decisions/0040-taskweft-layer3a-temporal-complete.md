# Taskweft port Layer 3a complete: Temporal.lean

## Status

Accepted; implemented and verified (`taskweft-temporal.shrub`).

## Decision

`Temporal.lean`'s `occursBefore`, `temporalConstraintValid`
(`after`/`before`/`between`/`within` over `TemporalConstraint`),
`allConstraintsSatisfied`. `IsConsistent` (a `Prop`) and its theorem
need no porting. `find-idx` replicates Lean's `List.findIdx` precisely
— it returns the **list's length** when nothing matches, not a
sentinel like `-1`/`#f` — `occursBefore`'s own bounds checks
(`i < stn.length`, `j < stn.length`) depend on exactly that behavior to
reject not-found cases; a `#f`-returning find would have silently
broken this.

Verified against a hand-traced 3-entry schedule (`stn = (10 20 30)`,
with start/end metadata per entry), covering all four constraint kinds
plus a multi-constraint `allConstraintsSatisfied` check: `1111100`,
matching exactly.

## Consequences

Good: a small, fully self-contained layer, no surprises — matches the
signature-level scope estimate exactly, unlike several earlier layers.
Bad: none noted: this is a low-risk piece.
