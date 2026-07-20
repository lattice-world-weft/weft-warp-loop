# Sketch graph intersects tessellated polylines, not exact Béziers

## Status

Accepted (shipped in sketch-core PR 1; exact arrangement deferred).

## Decision

Building the planar sketch graph requires intersecting strokes with each
other. Upstream cassie does exact cubic-Bézier/Bézier intersection,
Mathlib-backed; sketch-core is a fresh no-Mathlib rewrite, and
convergence only needs determinism, not exactness — every peer runs the
same code on the same packet set, so any deterministic approximation
converges, and fewer numerical layers made the plan's highest-risk item
(cross-platform FP determinism) verifiable early. Tessellate strokes at
a fixed `SAMPLES_PER_SEGMENT = 16` and intersect line segments, with eps
node interning (`NODE_EPS = 1e-3`), segment/segment crossing detection,
canonical parameter ordering, and integer micro-unit JSON output —
rather than porting the exact Bézier arrangement or using Q64.64
fixed-point arithmetic throughout. This proved byte-identical between
Windows clang-cl and Linux gcc builds on an FP-stress packet log, so the
fixed-point fallback wasn't needed. The exact arrangement stays open as
a later refinement — the Schneider fit already produces the Bézier
segments it would consume, natural once the beautify solver
([ADR 0003](0003-vendor-cassie-beautify-solver-plain-c-abi.md)) lands.

## Consequences

Good: a small, Mathlib-free, property-tested kernel with proven
determinism; the tessellation constants (`16`, `1e-3`) are documented as
part of the protocol in `Graph.lean`. Bad: intersection positions are
approximations — two strokes crossing at a glancing angle can miss or
double-count nodes near the eps threshold, acceptable at hand-drawn
sketch scales; changing any tessellation constant is a wire-protocol
break requiring all peers to upgrade together.
