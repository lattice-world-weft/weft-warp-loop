# Hand-ported Scheme content lives under riscv-guests/content/, verified against a Lean4 golden vector

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/content/loot.scm`,
`flow-toolchain/examples/s7_riscv_loot_golden_test.cpp`) — checkpoints 2
and 3 of the "real content through the interpreted s7 path" plan
(ADR 0028).

## Decision

Ported content (loot tables, combat rules, ...) is scheme source, not
C/C++ toolchain code — it belongs next to the guest it runs in
(`riscv-guests/`), in its own `content/` subdirectory, distinct from
`s7_guest_main.c` (the interpreter host wrapper) and the vendored `s7.c`
itself. `loot.scm` is a hand port of
`v-sekai-multiplayer-fabric/loot`'s `core/LootCore/{Rng,Loot}.lean`
(`totalWeight`/`pick`/`roll`, and the exact xorshift32 RNG both the Lean
spec and its SPIR-V kernel already agree on bit-for-bit), fetched via
`gh api` and translated line-for-line, not reinterpreted — Lean's
wrapping `UInt32` arithmetic is reproduced with explicit `(u32 ...)`
masking after every shift/xor, since s7's integers are
arbitrary-precision.

Verified two ways at once, matching this session's established
"prove it" discipline: correctness (the ported Scheme's result must
match a real, freshly-computed Lean4 reference value — computed via
`lake env lean --run`, not by hand) and determinism (ADR 0006's own
proof shape — two independent `Machine` instances given the identical
call). Golden vector: seed `42`, table `[(1,10),(2,20),(3,5)]`. Lean4
reference: `roll = 3`. Both `Machine` instances: `3`, in exactly `92523`
instructions each (dominated by `s7_init()`'s own cost — this test
re-initializes the interpreter per run, matching
`s7_riscv_actor_test.cpp`'s existing pattern — not the roll computation
itself; per-call cost excluding init is a separate, smaller number
checkpoint 4 will need).

## Consequences

Good: this is the actual proof ADR 0028's reversal was betting on —
real ported gameplay content, checked against a real Lean4 reference,
runs correctly and deterministically through the interpreter with no
compiler engineering at all. The methodology (fetch real source via
`gh api`, port by hand with explicit wraparound masking, verify against
a freshly-computed Lean4 golden vector, prove determinism the same way
ADR 0006 already did) is now established and repeatable for
`combat`/`progression`'s own content. Bad: hand-porting is manual and
unverified-by-construction beyond this one golden vector — a second,
untested code path (`cumulativeOf`/`rollIndex`, `resolve`/`winnerEntry`
from the same `Loot.lean`) exists in the Lean4 source and was not
ported or checked here; each additional function needs its own
golden-vector proof, this doesn't generalize automatically.
