# Godot as an interest-bounded thin presentation client, over patching Godot's core engine in place

## Status

Proposed (design record only; no code changes accompany this ADR).

## Decision

Godot's core skeleton is costly for console shipping: a mutex-heavy
`ObjectDB` with per-instance locking, fat parent-relative transforms
(non-uniform scale), a renderer that's neither bindless nor reliably
threaded (threaded rendering stays experimental, not recommended), and a
POSIX-heavy memory model with no uniformly-implemented virtual
filesystem. None of this is cheap to change mid-cycle. This project
already commits partially to routing around it — `README.md` scopes
Godot as client-only, all authoritative logic server-side in
Flow/`fanout-core`; ADR 0006 independently routes scripted content
through libriscv rather than native GDScript, for a determinism reason
that happens to point the same way. Interest management
(`fanout-core`'s ghost-range/`interestCapacity`) already bounds how many
entities any client needs to represent, a lever specific to this
architecture.

**Plan A (chosen)**: Godot holds no authoritative gameplay state in
`ObjectDB`/`Variant`/scene graph at all — it only renders, and only
instantiates live `Node`s for entities inside a player's interest set.
This costs no rework; it's already the standing architecture, made
explicit here. **Plan B (fallback)**: if Plan A's bound proves
insufficient on a real console target — profiling shows `ObjectDB`
locking or the non-threaded renderer is the actual bottleneck even under
interest-bounded load — patch only the specific subsystem profiling
identifies, rather than jump further. A full custom engine is rejected
as the default: it discards Godot's tooling/asset-pipeline value for an
unmeasured problem and contradicts this project's smallest-proven-
increment style; it's a last resort only if Plan B's target subsystem
proves structurally inseparable from the rest of the rendering pipeline.
A split editor/console-runtime hybrid is also rejected: it doubles
client-runtime maintenance before any of the above is tried against real
budgets.

## Consequences

Good: zero rework of `fanout-core`, the Flow/ZPB wire protocol, or the
zone/authority/interest system — this ADR makes an already-implicit
choice explicit and names its fallback; console-perf risk is bounded by
`interestCapacity` rather than open-ended; Godot's editor/import tooling
stays available under either plan. Bad: Plan A doesn't fix the stock
renderer being non-bindless/non-threaded, only bounds what's exposed to
it; no console shipping/certification data exists yet to validate either
plan — this ADR is directional, not measured. Revisit trigger: once a
real console target is profiled, if `ObjectDB` locking or the
non-threaded renderer is the actual bottleneck under interest-bounded
load, move to Plan B before considering the full-custom-engine option.
