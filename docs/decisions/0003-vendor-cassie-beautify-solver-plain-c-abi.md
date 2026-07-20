# Vendor the cassie beautify solver behind a plain-C ABI

## Status

Accepted (planned as PR 3 of the cassie reproduction; not yet implemented).

## Decision

Cassie's stroke "beautify" step (a dense PCG constraint solver with
fidelity/G1/tangent/planarity/mirror energies) turns raw fitted strokes
into clean, intentional-looking curves, and lives in the upstream Godot
module tied to `Curve3D`/`Vector3`/`Ref`. Rewriting a numerical
constraint solver in Lean is high-effort and high-risk compared to the
small, property-testable graph kernel, and this repo already vendors
heavy C/C++ (picoquic, picotls, mbedtls) while keeping Lean as the
protocol-semantics owner — so vendor the C++ solver into
`flow-toolchain/thirdparty/cassie-solver/`, stripped of its Godot
dependencies, behind a plain-C `beautify(samples[]) -> ctrl_pts[]` ABI,
rather than porting it to Lean or skipping it outright. Every peer must
run bit-identical beautify (the sketch graph re-simulates locally from
raw CSP1 packets), so the existing FP-stress byte-compare gate becomes
mandatory once this C++ float code enters the re-simulation path — same
compiler flags on all platforms, part of the contract. Raw Schneider-fit
strokes (no beautify) remain the shipping state until this lands; the
pipeline works without it, just rougher-looking.

## Consequences

Good: proven solver, exact visual parity with upstream cassie; the
plain-C ABI stays callable from the C++ host or, later, Lean. Bad: a
C++ float-heavy component joins the determinism-critical path, making
the byte-compare gate mandatory for every solver change; the vendored
diff from upstream must be tracked for future syncs.
