# Reserved witness zones for cross-machine zone-authority leases, over full Multi-Raft/parallel-commits

## Status

Proposed (design record only; no code changes accompany this ADR).

## Decision

ADR 0008's Hilbert-curve authority model bounds fanout cost *within* one
process's zones but says nothing about which process is authoritative
once the fabric spans more than one machine. The obvious answer — port
CockroachDB's multi-Raft (one consensus group per range) plus parallel
commits, as Flow actors — PERT-estimated at ~83h of critical-path work,
is a general-purpose distributed transaction system built before
anything here has demonstrated needing one. Two constraints narrow the
real problem: a zone stays single-writer, in-memory, on one process —
only "who currently holds zone X's lease" needs cross-machine agreement,
a leader-election problem, not general log replication or cross-range
atomic commits (re-estimated at ~33.4h, about 40% of the general case);
and the standing "no separate component" constraint rules out delegating
even that to an external database (CockroachDB/etcd/Consul) — the lease
mechanism has to live inside the same homogeneous `flow-toolchain`
binary every zone-server already is.

Adopted: every zone-server process also witnesses *other* zones' leases
(no separate role, matching the homogeneous-binary preference). A fixed
sub-range of the Hilbert curve-index space is reserved and treated as
ordinary zone territory, so lease records reuse `Zone`/`ZoneWorld`/
`SlotMap`/`maybeSplitZone` as-is — no second data structure, no new
property-test category. That reserved range is itself split into
multiple witness zones (via the same `maybeSplitZone`), not one, so a
witness process failing only strands the real zones mapped to it, not
fabric-wide leasing. Each real zone's lease maps deterministically to
one witness zone (a fixed, coordination-free hash/curve-midpoint
function) and is decided by majority vote among that witness zone's
current live members — the one genuinely new distributed primitive this
ADR calls for, and the entire ~33.4h estimate. Explicitly not built:
general multi-Raft log replication or cross-range atomic commits —
nothing here has demonstrated needing zero-loss replication or
cross-zone transactions yet; that evidence, not anticipation, is what
would justify the ~83h path later.

## Consequences

Good: reuses `Zone`/`ZoneWorld`/`SlotMap`/`maybeSplitZone` as-is,
extending already-proven properties rather than adding a new category;
stays inside the homogeneous-binary shape, no database sidecar; blast
radius bounded and shrinks automatically as the fabric grows; ~33.4h
critical path versus ~83h for a full Raft/parallel-commits port. Bad:
failover is bounded-loss (recovers from the last snapshot), not
zero-loss — an accepted, revisitable tradeoff; the majority-vote lease
primitive is still a new distributed algorithm needing its own
mutual-exclusion property tests (no two processes hold the same zone's
lease simultaneously, even under partition/clock skew); the
real-zone-to-witness-zone mapping must stay stable across witness-zone
splits — a real correctness constraint to prove, not assumed free.
