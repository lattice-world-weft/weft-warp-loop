# Reserved witness zones for cross-machine zone-authority leases, over full Multi-Raft/parallel-commits

## Status

Proposed (design record only; no code changes accompany this ADR).

## Context and Problem Statement

`fanout-core`'s E-GOSSIP work (ADR 0008's Hilbert-curve authority/interest
model, `ZoneDispatch.lean`'s `maybeSplitZone`) gives one process/core
bounded, near-constant-cost fanout *within* a single process's zones. It
says nothing about what happens when the fabric spans more than one
machine: which process is authoritative for a given zone becomes an
open question the moment two machines could both plausibly claim it -
the single-process model has no way to answer "which of us actually
owns zone X right now" once "us" is more than one process.

The obvious answer is real distributed consensus - specifically, port
CockroachDB's own approach (multi-Raft: one consensus group per range,
plus parallel commits for the cross-range atomic-commit case) as Flow
actors, since `flow/` in this repo already is FoundationDB's own actor
framework and the user's standing preference (recorded separately) is
CockroachDB's homogeneous-binary deployment shape over FoundationDB's
heterogeneous one. A PERT estimate for that full port - a from-scratch,
property-verified Raft state machine plus a from-scratch parallel-commits
protocol, each with their own safety-property test suites - came to
~83 hours of critical-path work. That is not a "smallest proven
increment"; it is a general-purpose distributed transaction system built
before anything in this repo has demonstrated it needs one.

Two constraints narrow the actual problem a great deal:

1. **The real question is much smaller than general transaction
   consensus.** A zone stays single-writer, in-memory, on one process
   (unchanged from the single-machine model) - nothing needs its
   per-tick state replicated through consensus. The only fact that needs
   cross-machine agreement is "who currently holds the lease for zone
   X," a narrow leader-election problem, not general log replication or
   cross-range atomic commits. Re-estimated for just that (lease
   acquire/renew/release with mutual-exclusion property tests, snapshot/
   recovery, `E-GOSSIP` integration, multi-machine validation), the
   critical path is ~33.4 hours - still real work, but roughly 40% of
   the general-purpose estimate, and it is the part actually motivated
   by a concrete gap.
2. **The user's explicit "no separate component" constraint rules out
   delegating even that narrow lease problem to an external database.**
   Running CockroachDB itself (or etcd/Consul) as the lease backend
   would answer the mutual-exclusion question with already-verified code
   at a fraction of the integration cost - but it reintroduces exactly
   the heterogeneous-component shape (a database process alongside the
   fabric's own binary) the standing CockroachDB-*style*-not-CockroachDB-
   *itself* preference exists to avoid. The lease mechanism has to live
   inside the same homogeneous `flow-toolchain` binary every zone-server
   process already is.

That leaves a small, scoped distributed primitive to build: quorum-based
lease grants among the zone-server processes themselves, with no
external dependency and no general-purpose consensus machinery.

## Decision Outcome

1. **Witnesses are zone-server processes, not a separate role.** Every
   `flow-toolchain` process that owns real-data zones also participates
   as a witness for *other* zones' leases - the same homogeneous binary,
   no CockroachDB-style role-specific process. This matches the standing
   deployment preference exactly rather than trading one heterogeneous
   shape (FoundationDB's role-specific processes) for another (a
   database sidecar).

2. **Reserve a sub-range of the Hilbert index space for witness data,
   reusing the existing zone machinery rather than building a second
   data structure.** `Zone`/`ZoneWorld`/`SlotMap` (`Fanoutcore/Zone.lean`,
   `ZoneDispatch.lean`, `SlotMap.lean`) already provide a correct,
   property-verified authority/split mechanism for "a bounded population
   of records, sharded by range, split when a shard grows past
   threshold." A lease/vote record is exactly such a record. Carving out
   a fixed sub-range of the `UInt64` curve-index space (e.g. the lowest
   indices, disjoint from the range real game entities ever quantize
   into - `zoneBits`'s existing quantization already leaves this
   decision entirely in curve-index space, independent of real-world
   coordinate scale) and treating it as ordinary zone territory means
   lease records are ordinary entities in an ordinary (reserved) zone:
   no new SlotMap, no new split/merge logic, no new property-test
   category beyond what already exists for `maybeSplitZone`.

3. **The reserved range is itself split into multiple witness zones,
   not one - bounding blast radius.** A single witness zone covering the
   entire reserved range would just relocate the single-point-of-failure
   problem from "one authoritative process per zone" to "one witness
   process for the whole fabric's leases" - worse, since every real
   zone's lease now depends on that one witness zone's process staying
   up. Applying the *same* `maybeSplitZone` mechanism to the reserved
   range means witness responsibility shards automatically as the number
   of real zones (and therefore lease records) grows, exactly as real
   game-entity zones already do. A witness zone's process failing then
   only strands the real zones mapped to *that* witness zone, not the
   fabric's leasing capability as a whole.

4. **Each real zone's lease is decided by a deterministic mapping to one
   witness zone, and by majority vote among that witness zone's current
   live members.** The mapping (e.g. a hash of the real zone's range,
   or its curve midpoint, folded into the reserved sub-range) is fixed
   and computable by any process without coordination - the same
   property `authorityForIndex` already gives point lookups over
   `ZoneRange`s. A lease grant requires majority agreement from whichever
   processes are currently live members of the target witness zone at
   the moment of the vote; this is the one genuinely new distributed
   primitive this ADR calls for (majority-vote lease grant/renewal), and
   it is the only piece the ~33.4h critical path (lease protocol +
   mutual-exclusion property tests) is actually about.

5. **Not built here: general multi-Raft (per-zone log replication) and
   parallel commits (cross-range atomic transactions).** Nothing in this
   repo has yet demonstrated a need to replicate a zone's per-tick
   simulation state across processes, or to commit a transaction
   spanning multiple zones atomically - the lease mechanism above answers
   "who owns this zone" and "state recovers from the last snapshot on
   failover" (a bounded loss window, not zero-loss replication), which is
   the actual, current problem. If a future need for zero-loss
   replication or true cross-zone atomic transactions is demonstrated,
   that is new evidence this ADR does not have yet, and the ~83h
   general-purpose estimate (or a fresh one) applies then, per YAGNI's
   actual claim: not "never build it," but "the cost of not having it is
   a real, deferred cost - pay it when the evidence, not the anticipation,
   demands it."

## Consequences

- Good: reuses `Zone`/`ZoneWorld`/`SlotMap`/`maybeSplitZone` as-is for
  the witness layer - no second data structure, no second category of
  property test beyond extending the existing split/authority suite to
  cover witness-zone records.
- Good: stays inside the homogeneous-binary shape - no CockroachDB (or
  etcd/Consul) process, no heterogeneous role, matching the standing
  deployment preference exactly.
- Good: blast radius is bounded and shrinks automatically as the fabric
  grows, via the same split mechanism that already bounds real-zone
  population - this is not a new invariant to prove from scratch, only
  a new application of one already proven (`maybeSplitZone`'s existing
  property tests: entity-count preservation, correct index-based
  partitioning, disjoint ranges post-split, threshold respected).
- Good: ~33.4h critical path versus ~83h for a general Raft/parallel-
  commits port - the majority-vote lease primitive is a small, bounded
  addition on top of already-verified machinery, not a new consensus
  system built from nothing.
- Bad: failover is bounded-loss (state recovers from the last snapshot),
  not zero-loss replication - a real, accepted tradeoff for now, not a
  hidden one; revisit if a workload demonstrates this loss window
  actually matters.
- Bad: the majority-vote lease primitive is still a genuinely new
  distributed algorithm requiring its own mutual-exclusion property
  tests (no two processes ever hold the same zone's lease
  simultaneously, even under partition/clock skew) - smaller than a
  full Raft port, but not zero new risk.
- Bad: the deterministic real-zone-to-witness-zone mapping needs to
  remain stable across witness-zone splits (a witness zone splitting
  must not silently orphan real zones that were mapped to it) - this is
  a real correctness constraint the implementation must prove, not
  assumed free by construction.
