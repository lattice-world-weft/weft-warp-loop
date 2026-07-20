# Taskweft port Layer 5: WitnessDAG.lean confirmed non-portable, skipped

## Status

Superseded by [0045](0045-taskweft-layer5-witnessdag-ported-via-own-fuzzer.md):
a minimal own QuickCheck-style fuzzer removed the specific blocker this
decision was about, making the escalation-ladder control flow portable
after all. This record stays as-is below - it was the right call given
what was known at the time (no reason to build a fuzzer had come up
yet), and the analysis of *why* Plausible itself is non-portable is
still accurate and worth keeping.

## Decision

`lean/Planner/WitnessDAG.lean` was read in full (not just its `def`
names, which were all that was known when this layer was scoped) and
turns out to be non-portable, in the same sense
[Layer 1](0038-taskweft-layer1-planner-core-complete.md)'s
`MultiGoalDecomposition.lean` was: every `def` in the file is either a
literal placeholder (`defaultCandidateIsWitness := false`,
`witnessReadback`/`defaultReadback` ignoring all arguments and
returning a constant `found := false` record, `main := pure ()`), or IO
glue over `certify`/`Testable.checkIO` — a call into the vendored
`PlausibleWitnessDag` library's QuickCheck-style randomized `Fin N`
sampler (`github.com/fire/plausible-witness-dag`). The one def with
real control flow, `certifyWitness`, is a for-loop escalating through
`defaultLadder`'s three rungs (walkSteps/finBound/numInst growing at
each), but the loop's actual decision-relevant step — `certify`,
constructing `∀ w : Fin N, ¬ candidateIsWitness w` and handing it to
Plausible's random-instance checker — has no portable pure-computation
form; reimplementing it would mean building a property-based/random-
testing engine, not hand-translating a def, and no per-domain
`candidateIsWitness`/`readback` implementation exists anywhere in this
file or the files that reference it by path.

`defaultLadder` itself is trivially portable (a static 3-row table of
four `Nat` fields each), but nothing in this layer's own logic
consumes it in a way worth porting on its own — it would only be
useful alongside `certifyWitness`'s loop skeleton, which this decision
skips for the reason above.

## Consequences

Good: no port work spent on a file whose real content is a randomized
fuzzer integration outside this project's scope, matching the
`MultiGoalDecomposition` precedent of reading before assuming
portability rather than trusting def names/signatures alone. Bad: if a
future need surfaces for the witness-oracle *escalation policy* itself
(ladder-based retry-with-widening-budget, independent of Plausible),
that shape isn't captured anywhere in shrubbery yet and would need to
be extracted fresh from `certifyWitness`'s loop, not resumed from
partial work here.
