# Taskweft port Layer 3b complete: Iso8601Duration.lean's real recursive-descent parser

## Status

Accepted; implemented and verified (`taskweft-iso8601duration.shrub`).

## Decision

`Iso8601Duration.parse` is a genuine recursive-descent parser (state-
threaded `parseComponents`, a nested numeric/fraction scanner
`takeNumber`, character classifiers `classifyUnit`/`crossSideUnit`,
canonical-order validation `unitRank`), not the simple single-function
layer its signature-only scoping originally assumed — confirmed by a
full read, matching the same "read before scoping" discipline
`MultiGoalDecomposition` already proved necessary. Ported the whole
pipeline: `unitMilliseconds`, `fracContribution`, `totalMilliseconds`,
`totalSeconds`, and `parse`'s full supporting cast.

One deliberate, documented simplification: `ParseError`'s Lean
variants carry diagnostic payload (the offending character, the raw
number string, the conflicting unit) that this port drops, keeping
only the error tag itself (`'invalidNumber`, `'nonCanonicalOrder`,
etc.) — nothing in the source file's own 12 `#eval` doctests inspects
that payload, only the variant. A real simplification, not a silent
one; restoring the payload would be straightforward if a future need
distinguishes two same-tag errors.

Verified against `Iso8601Duration.lean`'s own 12 worked-example
doctests directly, real Lean-computed reference output already in the
source — the same shortcut `FloydWarshall` used (ADR 0039), not a
freshly-computed reference. All 12 passed on the first real run (after
fixing the by-now-familiar missing-`record-macros.scm`-include gotcha,
not a logic bug) — the careful line-for-line structural translation
this session has held to throughout produced a correct parser on the
first attempt for a nontrivial piece of code.

## Consequences

Good: the most structurally complex remaining layer is done, verified
against the strongest evidence available (the source's own worked
examples, covering success, all four error-triggering shapes, and both
fraction-on-any-unit and fraction-position-rejection). Bad: the
dropped `ParseError` payload is a real, if currently harmless,
fidelity gap against the original spec — a caller wanting to
distinguish *which* character was unexpected, or see the raw invalid
number text, won't get it from this port as it stands.
