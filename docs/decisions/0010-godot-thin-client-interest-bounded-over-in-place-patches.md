# Godot as an interest-bounded thin presentation client, over patching Godot's core engine in place

## Status

Proposed (design record only; no code changes accompany this ADR).

## Context and Problem Statement

Godot's core skeleton is a 1990s-style object-oriented engine underneath
its 4.x-era improvements: a mutex-heavy `ObjectID` database with
per-instance locking that makes threading awkward, an authoritative scene
graph with fat parent-relative transforms (non-uniform scale support
makes `Transform3D` costlier than physics/graphics optimization wants), a
renderer that is neither bindless nor reliably threaded (threaded
rendering exists but is still marked experimental and not recommended),
and a POSIX-heavy memory model that under-uses memory mapping and leans
on internal caching/buffering/`memcpy` rather than a uniformly-implemented
virtual filesystem (PCK packaging isn't even uniform across platforms —
Android still ships sparse files inside the APK). None of this is cheap
to change mid-cycle without breaking a lot of things, and all of it sits
squarely in what console shipping/certification cares about most: memory
budget, IO efficiency, and predictable frame threading.

This repository's own working style (Gall's Law, already cited in
`README.md` and ADR 0006/0007) rules out treating this as "replace the
engine" by default. Godot's own modularity is real — a game engine is
roughly 100-120 subsystems, and only some of them are on any given
project's critical path. The question this ADR answers is which single
subsystem boundary to hold the line at, since only one can be the plan
this project commits to, with an explicit fallback if it turns out not to
be enough.

## Decision Drivers

- Console shipping/certification budgets are exactly where Godot's
  named weaknesses bite hardest: `ObjectDB` lock contention under load,
  non-threaded rendering, and POSIX-heavy IO all show up as frame-time
  and load-time problems, not correctness bugs — the kind that are easy
  to miss until a real console target is profiled.
- This project has already made a partial, independent commitment in
  the same direction: `README.md` already scopes Godot as client-only
  (rendering, input, XR) with all authoritative game logic server-side in
  Flow/`fanout-core`. ADR 0006 independently routes scripted content
  through libriscv rather than native GDScript, for a determinism reason
  that happens to point the same way as the console-performance reason
  here.
- Interest management (`fanout-core`'s ghost-range expansion,
  `interestCapacity`) already bounds how many entities any one client
  needs to represent at all — this is a lever specific to this project's
  architecture, not something a generic Godot project gets for free.
- A full engine replacement discards Godot's editor, asset pipeline, and
  import tooling entirely, for a problem not yet measured against a real
  console budget.

## Considered Options

1. **Thin-client Godot, interest-bounded**: Godot holds no authoritative
   gameplay state in its `ObjectDB`/`Variant`/scene graph at all; it only
   renders, and only instantiates live `Node`s for entities inside a
   player's interest set (already capped, not scaled to world
   population). All simulation and gameplay logic stays external (Flow/
   `fanout-core`, and godot-sandbox/taskweft for scripted content, per
   the game-features design notes in `features.md`).
2. **Patch Godot in place**: keep gameplay logic authored against
   Godot's own scene graph/`ObjectDB`/GDScript, and selectively replace
   the specific subsystems that block console shipping — e.g. a
   memory-mapped resource loader bypassing the POSIX-heavy PCK path, or a
   hot-path bypass around `ObjectDB` locking for per-frame entity
   updates.
3. **Full custom engine**: drop Godot's runtime from the shipping client
   entirely; build a bespoke renderer/client directly on the
   already-vendored QUIC/Flow stack, keeping Godot (if at all) as an
   editor/tooling front end only.
4. **Split-target hybrid**: stock Godot for the editor and non-console
   platforms, a separate custom or third-party runtime for certified
   console builds, sharing only the wire protocol and simulation layer.

## Decision Outcome

Chosen option 1 as the plan, with option 2 as the explicit fallback.

**Plan A — thin-client Godot, interest-bounded.** This costs no rework:
it's already this project's standing architecture (`README.md`'s
client-only scoping, `fanout-core`'s interest management), just adopted
here explicitly as the answer to the console-mismatch question rather
than left implicit. It concentrates console-perf risk into one bounded
lever — how many live `Node`s a client ever holds — instead of leaving it
open-ended, and it keeps Godot's editor/asset-pipeline value fully
available since only the shipping client's runtime discipline is
constrained, not tooling.

**Plan B (fallback) — patch Godot in place.** If Plan A's bound turns out
insufficient on a real console target — profiling shows `ObjectDB`
locking or the non-threaded renderer is the actual bottleneck even under
interest-bounded load — the fallback is not a jump to option 3. It's
patching the one specific subsystem profiling identifies (most likely
candidates: the experimental threaded-rendering path, or `ObjectDB`
locking on the interest-set churn path), matching the "fix the 100-120
things that actually annoy you" philosophy this option's name describes,
rather than replacing the engine.

Option 3 (full custom engine) is rejected as the default: it throws away
Godot's tooling/asset-pipeline value entirely for a problem with no
measured console data yet, and contradicts this project's own
smallest-proven-increment working style. It stays a last resort — only
reachable if Plan B's patched subsystem turns out structurally
inseparable from the rest of Godot's rendering pipeline, matching the
quoted concern that "core data structure stuff is very hard to update
mid-cycle without breaking a lot of things."

Option 4 (split-target hybrid) is rejected: it doubles the client-runtime
maintenance surface for a problem not yet proven to require two runtimes,
before any of options 1-3 have been tried against real console budgets.

### Consequences

- Good: zero rework of `fanout-core`, the Flow/ZPB wire protocol, or the
  zone/authority/interest system — this ADR only makes an already-implicit
  architectural choice explicit and names its fallback.
- Good: console-perf risk is bounded by `interestCapacity` rather than
  open-ended, and Godot's editor/import tooling stays available under
  either plan.
- Bad: Plan A doesn't fix Godot's stock renderer being non-bindless and
  effectively non-threaded — it only bounds how many objects are exposed
  to it. Presentation-layer cost (VFX, UI, even interest-bounded live
  entities) still runs through that ceiling.
- Bad: no console shipping or certification data exists yet in this
  project to validate either plan against a real budget — this ADR is
  directional, not measured.
- Revisit trigger: once a real console target is profiled, if `ObjectDB`
  locking or the non-threaded renderer shows up as the actual bottleneck
  under interest-bounded load, move to Plan B and patch that specific
  subsystem before considering option 3. Escalate to option 3 only if
  Plan B's target subsystem proves structurally inseparable from the rest
  of the engine.
