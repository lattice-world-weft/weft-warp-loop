# Defer surface patches and the AVBD/Slang solver

## Status

Accepted (explicit scope cut from the cassie reproduction plan).

## Decision

Upstream cassie goes beyond the sketch graph: cycle faces get
triangulated surface patches (geogram CDT + PMP remeshing/smoothing),
and there's an AVBD solver with Lean-Slang GPU variants plus a
mirror-constraints UI. Defer all three, rather than vendor geogram+PMP
now for surfaced cycles or reproduce the full upstream feature set in
one push — the demo's core claim (collaborative strokes converging to
identical sketch graphs across peers, including late joiners) is
complete without surfacing; geogram and PMP are heavyweight external
static libs that would dwarf the rest of the stack; and GPU/Slang code
paths are per-vendor nondeterministic, conflicting with the
byte-identical re-simulation contract (upstream itself keeps them
client-side-cosmetic for the same reason). The wire protocol and graph
JSON already carry everything a later surfacing stage would consume, so
deferral costs no rework — patches are a pure downstream consumer of the
converged graph, and can even stay client-side-only.

## Consequences

Good: PR 2 (WebTransport) and PR 3 (beautify) stay small and testable;
no heavyweight native deps enter the build yet. Bad: the demo renders
strokes and cycle counts, not filled surfaces — the most visually
striking upstream feature is absent until revisited. Revisit trigger:
after PR 3, if the demo needs filled faces, start with geogram CDT only
(flat patches) before PMP smoothing.
