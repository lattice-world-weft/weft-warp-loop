# Defer surface patches and the AVBD/Slang solver

## Status

Accepted (explicit scope cut from the cassie reproduction plan).

## Context and Problem Statement

Upstream cassie goes beyond the sketch graph: cycle faces get triangulated
surface patches (geogram CDT + PMP remeshing/smoothing), and there is an
AVBD solver with Lean-Slang GPU variants plus a mirror-constraints UI.
How much of that belongs in the current reproduction?

## Decision Drivers

- The demo's core claim — collaborative strokes converging to identical
  sketch graphs across peers, including late joiners — is complete
  without surfacing.
- Geogram and PMP are heavyweight external static libs (upstream builds
  them with dedicated scripts, `lean/build_{geogram,pmp}_static.sh`);
  vendoring them dwarfs the rest of the stack.
- GPU (Slang) code paths are per-vendor nondeterministic, which conflicts
  with the byte-identical re-simulation contract; upstream keeps them
  client-side-cosmetic for the same reason.

## Considered Options

1. Defer all three (surface patches, AVBD/Slang, mirror UI).
2. Vendor geogram + PMP now for surfaced cycles.
3. Reproduce the full upstream feature set in one push.

## Decision Outcome

Chosen option 1. The wire protocol and graph JSON already carry
everything a later surfacing stage consumes (cycles with node/segment
geometry), so deferral costs no rework: patches are a pure downstream
consumer of the converged graph and can even remain client-side-only
without touching the convergence contract.

### Consequences

- Good: PR 2 (WebTransport) and PR 3 (beautify) stay small and testable.
- Good: no heavyweight native deps enter the build yet.
- Bad: demo renders strokes and cycle counts, not filled surfaces — the
  most visually striking upstream feature is absent until revisited.
- Revisit trigger: after PR 3, if the demo needs filled faces, start
  with geogram CDT only (flat patches) before PMP smoothing.
