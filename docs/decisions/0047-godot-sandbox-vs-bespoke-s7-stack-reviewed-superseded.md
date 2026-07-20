# Godot-sandbox as the scripted-content backend, and taskweft-as-compiled-front-end — reviewed, superseded in practice

## Status

Superseded by [ADR 0028](0028-interpret-first-compile-later-supersedes-0014.md)
and everything built since it. Recorded here because the analysis was
real and the "four things are not interchangeable" distinctions below
still apply whenever godot-sandbox integration is revisited - only the
"prefer it over this repo's own stack" conclusion didn't hold up.

## Decision

Four things this repo's docs had previously named in ways that risked
being conflated, distinguished explicitly:

- **Native GDScript** (Godot's built-in `.gd` interpreter) — dynamically
  typed, trusted engine code, full Node/signal access, no documented
  bit-identical-replay contract across hosts (host-native double float,
  hash-order-sensitive `Dictionary`, no fuel/instruction accounting).
  Fine for client-only rendering/UI, wrong for anything that must
  replay identically across peers.
- **Godot C++ modules / GDExtension** — fully native, zero sandbox,
  same trust tier as native GDScript. Also wrong for the replicated-
  simulation path.
- **The Variant API** — Godot's tagged-union value type. Not an
  execution model; it's the data contract every one of the other three
  marshals values through at an engine/script/extension boundary.
- **godot-sandbox** (https://github.com/libriscv/godot-sandbox) —
  Godot's own upstream project embedding libriscv for sandboxed
  scripting (C++/Rust/Zig backends, plus a from-scratch GDScript-to-
  RISC-V compiler). The same libriscv substrate this repo already
  vendors and has independently proven deterministic
  (`libriscv_vendor_test.cpp`), but Godot's own sanctioned sandbox with
  its own Variant-ABI extern-call convention, not this repo's bespoke
  one ([ADR 0006](0006-libriscv-sandboxed-s7-lisp-over-native-janet.md)).

**The recommendation this ADR originally made**: prefer godot-sandbox's
libriscv/Variant-ABI substrate over this repo's own s7/shrubbery stack,
since it's the Godot-blessed mechanism other backends already target -
maximizing interop with real engine content (Nodes, scenes, exported
properties) while keeping libriscv's proven determinism. The scoped
next step named was a "godotweft-compiler": reusing `taskweft/udonweft`
(a Lean4-verified 9-opcode small-step VM plus a full 31,914-signature
extern-symbol taxonomy for VRChat's Udon) as the structural template
for an equivalent godot-sandbox-side compiler, since
`taskweft/godotweft` already carries the matching GDExtension API dumps
but no VM formalization or lowering compiler yet.

**Why it didn't hold up**: no godotweft-compiler work ever happened.
ADR 0028, reasoning from Paul Graham's "Beating the Averages" and real
development velocity on real content
([0026](0026-closures-and-lists-are-required-not-deferred.md)/
[0027](0027-slotmap-shaped-fixed-capacity-collections-no-allocator.md)),
chose instead to keep this repo's own s7-in-libriscv interpreter as the
primary, sole scripted-content path. Everything built since then - a
shrubbery-notation reader
([0033](0033-shrubbery-lite-reader-offline-preprocessor.md), later
ported to s7 itself,
[0037](0037-shrubbery-reader-ported-to-s7-verified-against-python.md)),
`define-record`/`record-with` macros
([0034](0034-record-macros-for-immutable-update-boilerplate.md)), real
scripted content (loot/combat/progression,
[0030](0030-ported-content-lives-under-riscv-guests-content.md)/
[0031](0031-combat-and-progression-ported-filter-not-builtin.md)), and
the full `taskweft` HTN-planner/ReBAC/temporal/HRR port
([0035](0035-taskweft-lite-htn-forward-decomposition-ported-to-shrubbery.md)
through [0046](0046-taskweft-layer6-integration-complete.md)) - all
target this stack, not godot-sandbox's. The interop argument for
godot-sandbox is still real on its own terms; it simply lost to
development velocity on the actual content this repo needed to ship.

## Consequences

Good: the four-things distinction (native GDScript / C++ modules /
Variant API / godot-sandbox) stays useful documentation regardless of
which backend wins, and is preserved here rather than only living in a
now-stale features-list paragraph. Bad: none of `taskweft/udonweft`'s
proven pattern (a Lean4-verified opcode VM plus an extern-symbol
taxonomy) has been reused for anything godot-sandbox-side - if
GDScript-in-sandbox integration is ever revisited, that reuse
opportunity is exactly where it was, not built on top of.
