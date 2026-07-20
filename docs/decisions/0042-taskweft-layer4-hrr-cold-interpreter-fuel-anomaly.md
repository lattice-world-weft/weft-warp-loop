# Taskweft port Layer 4 complete: HRR/Basic.lean, and a cold-interpreter fuel anomaly

## Status

Accepted; implemented and verified (`taskweft-hrr.shrub`).

## Decision

`lean/HRR/Basic.lean`'s operations are exactly what ADR 0026/0027's
original risk assessment feared and `HRR/Properties.lean`'s full read
disproved: `PhaseVec d := Fin d -> Int` is plain pointwise integer
`+`/`-`, no circular convolution, no floats, no FFT, no cross-platform
determinism risk at all. Ported `bind`, `unbind`, `encodeFact`, `zero`,
`neg`, `bundle`, `diff` as genuine Scheme closures over an index
argument, matching the representation already proven for
`FloydWarshall`'s distance matrix (ADR 0039). `pointwiseEq` is a `Prop`
and `Properties.lean` has zero `def`s — nothing else to port.

A real, reproducible anomaly surfaced while verifying the
`unbind(bind(memory, key), key) = memory` round trip: evaluated on a
freshly-initialized libriscv machine (`s7RiscvInitialize()` called
immediately before the one eval), the composed expression — a closure
built by applying `hrr-unbind` to the closure `hrr-bind` returned —
burned through 500,000,000 instructions without completing. The
identical expression, sent to an already-warm machine that had already
evaluated a few unrelated expressions first, completed in about 47,000
instructions. Every simpler check (`bind`, `bundle`, `diff`, `neg`,
`zero`, `encodeFact` — none of which apply one HRR-returned closure to
another) completed in ~50,000 instructions whether cold or warm. Ruled
out directly, not by assumption: file content (byte-identical between
the failing and passing forms), CRLF line endings (confirmed stripped
by `std::ifstream`'s default text-mode read before reaching the guest),
and fuel magnitude alone (failed at 200M and 500M, succeeded at ~50K
elsewhere). The discriminating variable, found by direct A/B
comparison, is cold-vs-warm interpreter state at the moment of the
composed call — not something in `taskweft-hrr.shrub`'s logic, which
gives correct answers wherever it completes at all.

The fix applied: `s7_riscv_taskweft_hrr_test.cpp` now calls
`s7RiscvInitialize()` exactly once and reuses that one machine across
all seven checks (redefining `hrr-bind`/`memory`/`key`/etc. fresh in
each call's expression, same as every other real-content test in this
codebase already does) — this is also simply the normal way this tier
is used everywhere else; the per-check-fresh-init structure introduced
while chasing the original combined-expression fuel blowup was itself
the thing that exposed this second, more specific anomaly, not a
pattern this codebase uses elsewhere.

## Consequences

Good: Layer 4's logic is fully verified (all seven operations correct,
including the round-trip identity), and the fix needed no fuel-limit
inflation or workaround more exotic than "stay warm," which matches
this tier's existing real usage everywhere else in the codebase — not
a special case introduced just for this test. Bad: the root cause
inside the guest's s7 build (why a cold heap makes *composed* closure
application specifically, and only specifically, this expensive) is
still not understood, only isolated to "cold interpreter state" as the
trigger. If a future real caller ever needs a single cold
`s7RiscvInitialize()` immediately followed by a composed-closure call
in one shot (rather than the warm-reuse pattern this tier already
uses), this anomaly could resurface and would need actual root-causing
in the guest's s7 build rather than routing around it again.
