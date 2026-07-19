# Scope the s7/shrubbery toolchain beyond ADR 0006: actor-compiler, Boost.Asio, taskweft, Elixir NIF

## Status

Proposed (design record only; no code changes accompany this ADR).

## Context and Problem Statement

ADR 0006 scopes s7 (with a shrubbery-notation front end) as the sandboxed
scripting tier for simulation content, plus a native-host build of the
same source for devtools. Four further, larger uses of the same s7/
shrubbery pair came up in the same session, each big enough to warrant
its own scoping rather than folding into ADR 0006's implementation
status notes:

1. Reimplementing `mcp__taskweft__plan`'s full feature set (temporal
   ISO8601 reasoning, ReBAC graph checks with a fuel-bounded traversal,
   HRR semantic-memory encoding — see `taskweft/nif`'s
   `lib/taskweft.ex`), not just the HTN forward-decomposition core
   `flow-toolchain/examples/taskweft-lite.scm` already implements and
   tests against `plan/bootstrap-domain.json`.
2. Exposing a bounded s7/libriscv call as an Elixir NIF via
   `elixir-nx/fine` (a C++17 header-only NIF helper, GCC/Clang/MSVC
   portable), for a side-by-side architecture comparison against
   `taskweft/nif`'s own C++20 NIF.
3. Porting `flow-toolchain/actorcompiler/` (FoundationDB's vendored
   Python actor-compiler — a CPS/state-machine transform turning
   `.actor.cpp`'s `wait`/`choose`/`when` syntax into plain C++ callback
   code, `actor_compiler.py` plus `parse_tree.py`) to s7/shrubbery, to
   remove the Python dependency from the build.
4. Replacing Boost and Boost.Asio in the Flow runtime's networking/
   coroutine layer with an event loop built on the already-vendored
   picoquic/HTTP3 code this repository has its own git history and
   ownership context for.

## Decision Drivers

- Items 1-2 sit inside ADR 0006's existing tiers (sandboxed guest /
  native devtool) and extend what content or integration surface those
  tiers carry — they don't change the repository's build pipeline.
- Items 3-4 are different in kind: they touch the build pipeline every
  other `flow-toolchain` component depends on (CMake's Python+Jinja2
  codegen step, the vendored `flow/` runtime's networking primitives).
  A mistake here doesn't cost one feature, it risks the whole toolchain.
- This repo's own working style (Gall's Law, cited in the README):
  evolve the smallest proven increment, don't build an unproven
  replacement for something that currently works, wholesale, before its
  narrower pieces are proven.
- The user asked for these to be recorded, not implemented, in this pass.

## Considered Options

For items 3-4 specifically:

1. Implement the actor-compiler port and Boost.Asio replacement now, in
   the same session as ADR 0006's scripting-tier work.
2. Record the intent and rough shape here; implement later, incrementally,
   each as its own proven step (matching how ADR 0003's solver vendoring
   was accepted before being implemented).

## Decision Outcome

Chosen option 2. Nothing in items 3-4 is implemented in this pass.

**Taskweft, full feature set (item 1):** `taskweft-lite.scm`'s forward-
decomposition core is the foundation; temporal reasoning, ReBAC+fuel, and
HRR encoding are each their own substantial subsystem in the existing
C++20 implementation and are not started in s7. Follow-up work, sequenced
after item 1's core is exercised against more than the one bootstrap
domain this repository currently has.

**Elixir NIF comparison (item 2):** `elixir-nx/fine` is a real,
actively-used option (the `elixir-nx`/`Nx`/`EXLA` ecosystem already
depends on it) for wrapping a single bounded, fuel-limited call — a
`vmcall` into the sandboxed s7 guest, or a call into `fanout-core`'s FFI —
as an Elixir NIF. This is compatible with the constraint the README
already states for this repository ("not an Elixir NIF... an
indefinitely-running loop can't safely live inside the BEAM VM"): a NIF
must return quickly, and one fuel-bounded VMCALL is exactly that shape,
unlike the whole Flow event loop, which stays out of the BEAM VM as
already decided. Not implemented; recorded as a comparison worth doing
once item 2's target call (from ADR 0006, still unbuilt) exists to wrap.

**Actor-compiler port (item 3):** `flow-toolchain/actorcompiler/`
transforms `wait`/`choose`/`when`/state-declaration syntax
(`parse_tree.py`'s statement types) into a continuation-passing-style
state machine in plain C++ — this is a real compiler, not a text
substitution tool. Porting it to s7/shrubbery removes the one Python
dependency the CMake build has, at the cost of re-proving a
transform this repository currently gets for free from FoundationDB's
own already-proven implementation (the same "don't invent an unproven
new configuration" reasoning the `flow/` vendoring commit already used).
Not started.

**Boost/Boost.Asio replacement (item 4):** the Flow runtime's networking
primitives currently come from vendored FoundationDB `flow/` code built
against Boost (`flow-toolchain/CMakeLists.txt`'s `Boost::` targets).
Replacing this with an event loop over the already-vendored picoquic/
HTTP3 stack is plausible in principle — this repository already runs
picoquic's core protocol functions with no hidden I/O, driven entirely
through Flow's own socket/timer primitives (README's "Architecture"
section) — but Boost.Asio and Boost.Context underpin more of `flow/`
than just networking (coroutine/fiber support, the actor scheduler
itself), so this is a deeper change than swapping one networking
backend for another. Not started; the size of this change means it
needs its own follow-up investigation into exactly what `flow/` uses
Boost.Asio/Context for, before a redesign is scoped further than this
paragraph.

### Consequences

- Good: nothing about the working build (Python actor-compiler, Boost,
  vcpkg) changes as a result of this ADR — zero regression risk from
  recording intent.
- Good: items 1-2 have a clear relationship to ADR 0006's already-decided
  tiers, so they can be picked up independently of items 3-4.
- Bad: items 3-4 remain unscoped past this paragraph — an actual
  implementation plan (which `flow/` symbols depend on Boost.Asio
  specifically, what the actor-compiler's CPS transform needs from
  s7/shrubbery to be expressive enough) is still to be done.
- Bad: four more pieces of work are now on record without committed
  timelines, on top of ADR 0006's own unstarted items (libc completion,
  shrubbery reader, VMCALL wiring, fuel-budget sizing).
