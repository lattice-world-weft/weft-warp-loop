# qc-fuzz.shrub ports Plausible's real StdGen/randNat/checkIO algorithm, not a xorshift32 stand-in

## Status

Accepted; implemented and verified (`qc-fuzz.shrub`,
`s7_riscv_qc_fuzz_test.cpp`). Supersedes the PRNG/sampling internals
[0045](0045-taskweft-layer5-witnessdag-ported-via-own-fuzzer.md)
introduced (that ADR's control-flow analysis of `certifyWitness`
itself is unchanged and still accurate).

## Decision

ADR 0045 got Layer 5 unblocked with a deliberately minimal xorshift32
sampler standing in for Plausible's real algorithm — explicitly not a
port of Plausible itself. Replaced it with a faithful one, after
reading the real source in full: `leanprover-community/plausible`
(pinned by `fire/plausible-witness-dag`'s own `lake-manifest.json` at
commit `a456461b368b71d2accd95234832cd9c174b5437`) and Lean core's own
`Init/Data/Random.lean`, since `StdGen` itself lives there, not in
Plausible.

**The real PRNG**: Lean's `StdGen` is L'Ecuyer's 1988 combined
multiplicative-congruential generator — two independent LCG substreams
(moduli 2147483563 and 2147483399) combined by subtraction. Ported
`qc-mk-std-gen`/`qc-std-next` with the exact constants from
`Init/Data/Random.lean`'s `mkStdGen`/`stdNext`, not approximated.

**The real range-reduction**: `randNat` is not a plain modulo of one
PRNG draw — it's an accumulator (`qc-rand-nat-loop`) that folds
consecutive `stdNext` draws into a mixed-radix value until enough
target magnitude (`k * 1000`) has accumulated, then reduces mod `k`.
Ported that loop as a real loop, not assumed away — for every
`finBound` this port actually uses (256/1024/4096) it still terminates
after exactly one `stdNext` call, matching what the research
confirmed, but the loop is there for the general case.

**The real per-trial size scaling** — the load-bearing detail a
signature-only reading of `checkIO` would miss entirely:
`Testable.runSuiteAux` doesn't sample uniformly from `[0, finBound)`
on every trial. Trial `i` (0-indexed) samples from
`[0, min(i * maxSize / numInst, finBound - 1)]` — size 0 on the very
first trial, growing toward `maxSize` (Plausible's own default, 100)
by the last one. Since `plausible-witness-dag`'s own `certify` call
site never overrides `maxSize`, this means candidates above ~99 are
**never sampled at all** for the `finBound := 1024`/`4096` ladder
rungs under real Plausible today — a genuine gap in the upstream
library, not a porting artifact, and this port inherits it faithfully
(`qc-default-max-size` returns 100, unconditionally) rather than
silently "fixing" behavior real Plausible doesn't have.

**Deliberately not ported**: `Shrinkable`/minimization (only changes
which counterexample gets reported after a failure is already found —
`certify`'s caller only reads the boolean `isFailure`, never the
shrunk value) and `gaveUp`/`numRetries` (structurally unreachable for
the exact `∀ w : Fin N, decidable-predicate w` proposition shape
`plausible-witness-dag` actually uses — `Arbitrary.arbitrary` for
`Fin`/`Nat` never raises `GenError`, so `retry` never triggers).

**Seed handling — a real fact about upstream, not glossed over**: real
Plausible's default (`cfg.randomSeed := none`) reads/mutates a
process-global `IO.stdGenRef`, seeded once from OS entropy at process
start — genuinely non-deterministic across runs by Plausible's own doc
comment, and `plausible-witness-dag`'s `certify` never overrides it.
There is no way to "faithfully port" that path into a sandboxed guest
that must give the same answer on every machine; a caller-supplied
seed (`qc-mk-std-gen`) is the only reproducible mode real Plausible
has, and it's the only mode this port implements. `taskweft-
witnessdag.shrub`'s `certify-witness-loop` needed a small new helper,
`qc-next-seed`, to derive a fresh deterministic seed for each ladder
rung — real Plausible relies on the mutable global ref continuing to
evolve across calls in one process; this port has no such state, so
the next rung's seed is derived explicitly from the previous one
instead.

Verified two ways: `s7_riscv_qc_fuzz_test.cpp` checks
`qc-mk-std-gen`/`qc-std-next`/`qc-rand-nat` against an independent
Python re-implementation of the exact same formulas (not against Lean
directly — no Lean toolchain in this build — but against the same
algorithm this file's own header comment quotes verbatim), all 5
checks passing on the first real run. `s7_riscv_taskweft_witnessdag_
test.cpp` (already-passing checks, rebuilt against the new internals)
needed a real fuel bump (20M → 200M) — the real algorithm's per-trial
accumulator loop costs meaningfully more than the xorshift32 stand-in
did, and the always-false path runs the full budget (200/800/2000
trials) across all three ladder rungs.

## Consequences

Good: this is now a real, defensible port of Plausible's actual
algorithm — a reviewer who knows Plausible's internals can check this
port against them directly, not against an ADR's promise that "it's
close enough." The `maxSize`-undersampling gap for large `finBound`
rungs is now documented rather than silently inherited or silently
fixed. Bad: this port's fidelity is bounded by Plausible's own
determinism story - if `plausible-witness-dag` is ever run for real
(not just referenced as this port's model) without an explicit
`randomSeed`, its results still won't match this port's, since real
Plausible's no-seed path is non-deterministic by design. Reconciling
that would mean patching `plausible-witness-dag` itself to set
`randomSeed := some seed`, not something achievable from this side.
