# Scope the s7/shrubbery toolchain beyond ADR 0006: actor-compiler, Boost.Asio, taskweft, Elixir NIF

## Status

Proposed (design record only; no code changes accompany this ADR).

## Decision

Four further uses of the s7/shrubbery pair came up in the same session
as [ADR 0006](0006-libriscv-sandboxed-s7-lisp-over-native-janet.md), each
scoped here rather than implemented: (1) reimplementing `taskweft`'s
full feature set (temporal reasoning, ReBAC+fuel graph checks, HRR
semantic-memory encoding) beyond what `taskweft-lite.scm`'s HTN
forward-decomposition core already covers; (2) exposing a bounded
s7/libriscv VMCALL as an Elixir NIF via `elixir-nx/fine`, for comparison
against `taskweft/nif`'s own C++20 NIF — compatible with this repo's
existing "no indefinitely-running loop inside the BEAM VM" constraint,
since one fuel-bounded VMCALL is exactly the quick-return shape a NIF
needs; (3) porting `flow-toolchain/actorcompiler/` (FoundationDB's
vendored Python actor-compiler) to s7/shrubbery, removing the one Python
build dependency; (4) replacing Boost/Boost.Asio in the Flow runtime's
networking/coroutine layer with an event loop over the already-vendored
picoquic/HTTP3 stack.

Items 1-2 extend ADR 0006's existing tiers (sandboxed guest / native
devtool) without touching the build pipeline, so they can proceed
independently. Items 3-4 are different in kind — they touch the build
pipeline every other `flow-toolchain` component depends on, so a mistake
risks the whole toolchain, not one feature — and Gall's Law (evolve the
smallest proven increment) argues against attempting either in the same
pass as ADR 0006's own unfinished work. Nothing in items 3-4 is
implemented here: the actor-compiler port would re-prove a
CPS/state-machine transform this repo currently gets free from
FoundationDB's own proven implementation; the Boost.Asio replacement is
plausible in principle (this repo already runs picoquic's protocol
functions through Flow's own socket/timer primitives with no hidden I/O)
but Boost.Asio/Context underpin more of `flow/` than networking alone
(coroutine/fiber support, the actor scheduler itself), making this a
deeper change than swapping one networking backend.

## Consequences

Good: nothing about the working build (Python actor-compiler, Boost,
vcpkg) changes as a result of this ADR — zero regression risk from
recording intent; items 1-2 can be picked up independently of items 3-4.
Bad: items 3-4 remain unscoped past this paragraph — an actual
implementation plan (which `flow/` symbols depend on Boost.Asio, what
the actor-compiler's transform needs from s7/shrubbery) is still to be
done; four more pieces of work are now on record without committed
timelines.
