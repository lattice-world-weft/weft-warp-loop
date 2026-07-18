# Vendor the cassie beautify solver behind a plain-C ABI

## Status

Accepted (planned as PR 3 of the cassie reproduction; not yet implemented).

## Context and Problem Statement

Cassie's stroke "beautify" step (dense PCG constraint solver with
fidelity/G1/tangent/planarity/mirror energies) is what turns raw fitted
strokes into clean, intentional-looking curves. It lives in the upstream
Godot module (`modules/cassie` `src/solver/`, `src/constraints/`,
`src/curves/`) and depends on Godot core types (`Curve3D`, `Vector3`,
`Ref`). How do we get it into this stack?

## Decision Drivers

- Rewriting a numerical constraint solver in Lean is high-effort and
  high-risk compared to the graph kernel (which was small and
  property-testable).
- Determinism contract: every peer must run bit-identical beautify, since
  the sketch graph is re-simulated locally from raw CSP1 packets.
- Repo precedent: heavy C/C++ is vendored (picoquic, picotls, mbedtls);
  Lean owns protocol semantics.

## Considered Options

1. Vendor the C++ solver, strip the Godot dependencies, expose
   `beautify(samples[]) -> ctrl_pts[]` as a plain-C ABI.
2. Port the solver to Lean like the graph kernel.
3. Skip beautify; ship raw Schneider-fit strokes.

## Decision Outcome

Chosen option 1, into `flow-toolchain/thirdparty/cassie-solver/`. The
cost to flag: de-Godot-ification is real work (replace `Curve3D`/`Ref`
plumbing with plain structs). Beautify runs identically on every peer
before arrangement; CSP1 keeps raw samples on the wire (cassie's own
design), so the wire format and history/dedup layers are untouched.
Cross-platform determinism must be re-verified with the existing
FP-stress byte-compare once C++ float code enters the re-simulation
path — same compiler flags on all platforms are part of the contract.
Option 3 remains the shipping state until PR 3 lands (the pipeline
works without beautify, it just looks rougher).

### Consequences

- Good: proven solver, exact visual parity with upstream cassie.
- Good: plain-C ABI keeps it callable from the C++ host or, later, Lean.
- Bad: a C++ float-heavy component joins the determinism-critical path;
  the byte-compare gate becomes mandatory for every solver change.
- Bad: vendored diff from upstream must be tracked for future syncs.
