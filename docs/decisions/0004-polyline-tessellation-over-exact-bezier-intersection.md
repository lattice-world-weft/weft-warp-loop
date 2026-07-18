# Sketch graph intersects tessellated polylines, not exact Béziers

## Status

Accepted (shipped in sketch-core PR 1; exact arrangement deferred).

## Context and Problem Statement

Building the planar sketch graph requires intersecting strokes with each
other. Upstream cassie's Lean kernel does exact cubic-Bézier/Bézier
intersection (`CycleDetect/BezierIntersect.lean`, Mathlib-backed). Our
sketch-core is a fresh no-Mathlib rewrite — what intersection primitive
does the graph use?

## Decision Drivers

- Convergence only needs determinism, not exactness: every peer runs the
  same code on the same packet set, so any deterministic approximation
  converges.
- Exact Bézier clipping is the hardest part of the upstream kernel and
  the main reason it pulls Mathlib.
- Cross-platform FP determinism was the plan's highest-risk item; fewer
  numerical layers made it verifiable early.

## Considered Options

1. Tessellate strokes at a fixed rate and intersect line segments.
2. Port the exact Bézier/Bézier arrangement.
3. Q64.64 fixed-point arithmetic throughout.

## Decision Outcome

Chosen option 1: fixed `SAMPLES_PER_SEGMENT = 16` tessellation, eps node
interning (`NODE_EPS = 1e-3`), segment/segment crossing detection,
canonical parameter ordering, and integer micro-unit JSON output. This
proved byte-identical between Windows clang-cl and Linux gcc builds on
an FP-stress packet log, so option 3 (the planned fallback, specced in
upstream `lean/CyclePatch.lean`) was not needed. Option 2 stays open as
a later refinement — the Schneider fit already produces the Bézier
segments an exact arrangement would consume, and the fitted curves are
the natural graph geometry once the beautify solver
([0003](0003-vendor-cassie-beautify-solver-plain-c-abi.md)) lands.

### Consequences

- Good: small, Mathlib-free, property-tested kernel; determinism proven.
- Good: constants (`16`, `1e-3`) are part of the protocol — documented
  as such in `Graph.lean`.
- Bad: intersection positions are approximations; two strokes crossing
  at a glancing angle can miss or double-count nodes near the eps
  threshold. Acceptable for hand-drawn sketch scales.
- Bad: changing any tessellation constant is a wire-protocol break —
  all peers must upgrade together.
