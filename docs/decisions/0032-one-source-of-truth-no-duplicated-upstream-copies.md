# One source of truth: no duplicated copies of upstream repos' source

## Status

Accepted; implemented — removed `LootGoldenVectorScratch.lean`,
`CombatGoldenVectorScratch.lean`, `ProgressionGoldenVectorScratch.lean`.

## Decision

Porting `loot`/`combat`/`progression` to s7
([ADR 0030](0030-ported-content-lives-under-riscv-guests-content.md),
[0031](0031-combat-and-progression-ported-filter-not-builtin.md)) had
drifted into three copies of the same logic: the real upstream Lean4
repos, a verbatim copy-paste of that source into this repo's
`*GoldenVectorScratch.lean` files (to compute a reference value), and
the hand-ported `.scm` files. The scratch-file copy was pure
duplication with no purpose beyond a one-time computation, and a real
risk: if upstream changed, this repo would silently hold a stale,
diverged "reference" with nothing to flag it, exactly the kind of
multiple-sources-of-truth problem the ADR/backfill discipline
([0017](0017-hilbert-curve-zone-authority.md)-[0023](0023-zpb-wire-verb-carries-velocity-and-rtt-lookahead.md))
exists to prevent for this project's own decisions.

Removed. The upstream repos are the only source of truth for their own
logic — never vendored, copied, or mirrored into this repo, even
temporarily. Each `.scm` port's header now pins the exact upstream
commit it was translated from (e.g. `loot.scm`:
`6c4439441c7ea9ef24b80fc68b6486e97219285b`) instead of a vague "fetched
via gh api" — a port is explicitly a snapshot translation, stale the
moment upstream moves, not an ongoing mirror. Golden-vector reference
values, once computed, are recorded permanently in ADRs and test-file
comments (numbers, not source code) — the computation script itself is
disposable, kept only as long as computing the value takes.

## Consequences

Good: exactly one authoritative copy of each hexagon's logic exists at
any time (upstream); this repo holds only the values it needs
(numbers) and the deliberate translations it needs (`.scm`), never a
parallel copy of someone else's source. Drift is now at least visible
in principle — a commit pin gives future readers something to diff
against, even though nothing re-checks it automatically. Bad: the
commit pin is a manual, unenforced convention — nothing fails a build
or flags a warning if `combat`/`loot`/`progression` move past the
pinned commit; catching real drift still requires a human to notice and
re-port by hand. This doesn't yet solve the deeper duplication ADR 0013
already named (the `.scm` files themselves are unavoidably a second
implementation of the same logic in a different language) — only the
avoidable, purposeless third copy.
