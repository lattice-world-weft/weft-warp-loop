# Taskweft port Layer 5 complete: WitnessDAG.lean ported via a minimal own QuickCheck-style fuzzer

## Status

Accepted; implemented and verified (`qc-fuzz.shrub`,
`taskweft-witnessdag.shrub`). Supersedes
[0043](0043-taskweft-layer5-witnessdag-non-portable.md)'s skip
decision.

## Decision

[ADR 0043](0043-taskweft-layer5-witnessdag-non-portable.md) skipped
`WitnessDAG.lean` because its one real algorithm - `certify`'s call
into the vendored Plausible library's randomized `Fin N` sampler - had
no portable pure-computation form. That analysis of Plausible itself
is unchanged; what changed is the premise that porting `certify`
requires porting Plausible. It doesn't: `certifyWitness`'s actual
contract is "sample up to `numInst` candidates from `[0, finBound)`
and see if any satisfies the predicate" - a minimal deterministic
version of that same contract, not a reimplementation of Plausible's
real strategy (size-directed generation, shrinking on failure), is
enough to port the escalation-ladder control flow around it.

`qc-fuzz.shrub` provides that minimal version: `qc-search-loop` samples
via a seeded xorshift32 stream (the same proven shift-xor cascade
`loot.shrub`'s `rng-range` already uses, reproduced under a `qc-`
prefix rather than shared across files - no `(load ...)` inside guest
content), `qc-certify` wraps it to answer "does a witness candidate
exist within budget" the way `certify` did. `taskweft-witnessdag.shrub`
then ports `certifyWitness`'s real control flow precisely: at each
unresolved ladder rung, readback-found wins first, then
qc-certify-found (outcome provablyNone), then budgetHit if rungs
remain, else budgetHit as the final answer - matching the Lean
source's own priority order exactly (traced in ADR 0043's own verbatim
source quote). One deliberate deviation, and the only one: Plausible
manages its own RNG state internally, invisibly; this port has no
hidden global state to depend on; determinism requires the caller to
see exactly what seed produced what result, so the seed is threaded
explicitly and advanced once per rung.

Verified with three hand-traced escalation paths chosen so the outcome
doesn't depend on which specific values the xorshift32 stream samples
- only the control flow is under test, not qc-fuzz's own sampling
distribution: an always-true candidate resolves at rung 0 as
provablyNone; an always-false candidate with the default (never-found)
readback exhausts all three rungs to budgetHit; an always-false
candidate paired with a found-immediately readback short-circuits at
rung 0 regardless of the candidate predicate. Plus a determinism
check: the same seed through `qc-search-loop` twice gives the same
result, the property this whole tier depends on.

## Consequences

Good: Layer 5 is now actually complete, not skipped - the last planner
file with real control-flow content this port needed. The fuzzer
itself is small, self-contained, and reusable if a future port needs
bounded random search again. Bad: `qc-fuzz` is deliberately not a
faithful port of Plausible - it makes no attempt at shrinking, size-
directed generation, or Plausible's actual statistical guarantees; a
`#f`/no-witness-found result here is bounded random search within
`numInst` trials, nothing more, exactly the caveat Plausible's own
documentation carries but not upgraded to anything stronger. If a
future domain genuinely needs Plausible-grade search quality rather
than this ladder's escalating budget, that's new work, not something
this port already did.
