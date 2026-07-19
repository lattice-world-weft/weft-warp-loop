# Sandbox a Lisp-1 in libriscv for scripted simulation content, over a native Janet layer

## Status

Accepted (a future PR; not yet implemented).

## Context and Problem Statement

No embedded scripting language exists anywhere in this stack. Everything
non-Lean4 is external-process orchestration: `scripts/test_local.sh`
(bash), the Python E2E tests (`pixi` + `aioquic`), and the vendored
FoundationDB Python actor-compiler (build-time codegen). Flow's
determinism contract — every peer replays byte-for-byte identically from
the same simulated network/clock/RNG input — is why `fanout-core`'s
dispatch and `sketch-core`'s convergence graph live in Lean4 rather than
hand-written C++, and why ADR 0003 flags the vendored beautify solver as
a determinism-sensitive addition requiring its own byte-compare gate.

A first framing of this question asked whether Janet
(https://github.com/janet-lang/janet), a Lisp-1 distributed as a single
amalgamated `janet.c`/`janet.h`, fits as a scripting layer running
natively alongside the Flow process, with Lean4 kept for verification.
Janet's own execution model — a native-code interpreter with host
floating point, dynamic hashtables, and no documented cross-platform
bit-identity guarantee — sits outside Flow's replay-determinism
contract the same way any other native scripting runtime would. That
framing confines Janet to work that never touches replicated game state:
dev/debug REPL tooling against the fanout/sketch FFI, and the
cert-minting script ADR 0002 calls for.

libriscv (https://github.com/libriscv/libriscv), an embeddable RISC-V
CPU emulator, changes the shape of the question. It runs compiled RISC-V
ELF binaries inside a host process through a C++17 API
(`Machine<RISCV64>`), and because it emulates a fixed instruction set —
including software floating point per the RISC-V spec — instead of
running host-native machine code, the same guest binary produces the
same execution trace regardless of host CPU or OS. That property matches
what Flow's replay already needs. A scripting language running as a
libriscv guest, rather than natively, becomes a candidate for the
determinism-critical path itself, not only for dev tooling beside it —
provided the guest language is a Lisp-1 with a small enough footprint to
fit a sandboxed, fuel-bounded call boundary well.

## Decision Drivers

- Reproducibility: any scripted content that touches replicated
  simulation state needs the same bit-identical-replay guarantee
  `fanout-core`/`sketch-core` already carry, matching ADR 0004's stance
  that determinism only needs the approximation to be identical across
  peers, not exact.
- Performance and a bounded, predictable cost per call — libriscv's
  `machine.simulate(max_instructions)` fuel metering caps worst-case
  compute per call with an instruction-count ceiling that produces the
  same count on every peer.
- Sandbox isolation matching the repo's existing "the C++ host owns all
  I/O" rule: a libriscv guest has no syscalls unless the host installs a
  handler for that specific syscall number, a stricter boundary than
  `fanout-core`'s plain FFI draws today.
- A Lisp-1 specifically (single namespace for functions and values, as
  opposed to a Lisp-2 like Common Lisp or Emacs Lisp).
- License compatibility with the repo's no-GPL/AGPL constraint.

## Considered Options

1. Janet running natively beside Flow, Lean4 unchanged.
2. libriscv embedded in Flow, Janet compiled to RISC-V as the guest
   language.
3. libriscv embedded in Flow, s7 Scheme compiled to RISC-V as the guest
   language.
4. AtomVM (https://github.com/atomvm/atomvm), a from-scratch minimal BEAM
   implementation for constrained hardware, paired with a Lisp-1 BEAM
   language.
5. libriscv embedded in Flow, Racket compiled to RISC-V as the guest
   language, authored in Rhombus (https://docs.racket-lang.org/rhombus-guide/index.html),
   Racket's non-parenthesized surface syntax.
6. Status quo: no embedded scripting language.

## Decision Outcome

Chosen option 3: libriscv embeds in the Flow server as the execution
substrate, and s7 Scheme (a Lisp-1, also distributed as a single portable
C file, built for embedding, with a track record in real-time/low-latency
embedding contexts such as the Snd and CLM audio tools) compiles to
RISC-V as the guest language. A Flow actor calls into guest functions
through libriscv's documented VMCALL pattern, under a
`machine.simulate(max_instructions)` fuel limit and an explicit
per-syscall allowlist — the same call shape `fanout-core`'s exported FFI
functions already use from the Flow side. Lean4's scope stays exactly
where it is: `fanout-core`'s dispatch, `sketch-core`'s convergence graph,
and the beautify solver's boundary (ADR 0003) remain the formally
verified, property-tested kernel. The sandboxed s7 guest is an additional
tier underneath that kernel, for simulation content — mission scripts,
loot tables, NPC behavior — that changes often enough that a Lean4 proof
per change is expensive, while still needing to replay identically on
every peer.

Option 2 (Janet-as-guest) loses to option 3 on footprint: Janet's
built-in fibers, event loop, and socket I/O assume the language owns its
own scheduling and I/O, all of which need stripping or stubbing for a
freestanding RISC-V build where the guest is supposed to have none of
those things by construction. s7 carries no such subsystems to remove.
Janet stays available as a fallback guest language if ecosystem size or
existing familiarity outweighs footprint later.

Option 1 answers a narrower, still-real question — a native Janet layer
for dev/debug REPL tooling against the fanout/sketch FFI, and for the
not-yet-written cert-mint script from ADR 0002 — but it does not put any
scripted logic on the determinism-critical path, which option 3 does.
That devtool-only role is not decided in this ADR and stays open as
separate future work, independent of whichever guest language option 3
uses.

Option 4 is investigated and rejected on two independent grounds. First,
the Lisp-1/Lisp-2 landscape on BEAM is narrow: LFE (Lisp Flavoured
Erlang) is the mature, actively maintained option, and it is a Lisp-2;
the one Lisp-1 BEAM dialect, Joxa, is Clojure-inspired but has shown no
sign of active maintenance since its docs settled on a `v0.1.0`
readthedocs page. Second, and independent of that gap, neither AtomVM nor
any BEAM Lisp addresses this ADR's actual problem: BEAM's scheduler,
garbage collector, and floating point carry no bit-identical-replay
guarantee across hosts the way libriscv's RISC-V instruction emulation
does, so adopting AtomVM moves no workload onto Flow's
determinism-critical path — it only duplicates the boundary the README
already draws for Elixir/OTP, a peer process connecting to Flow over
HTTP/3, never something spawned by or embedded in the Flow process.

Option 5 is investigated and rejected on the same footprint grounds as
option 2, more severely. Rhombus is a surface syntax built on Racket —
"Rhombus is built on Racket, and it is extensible in the same way as
Racket, but Rhombus uses a more conventional expression syntax" — not an
independent implementation; it carries the full Racket/Chez Scheme
runtime underneath (its own GC, JIT/AOT compilation pipeline, module and
bytecode loader), the same way Rhombus code still runs on Racket's `raco`
toolchain. Nothing in Racket's or Rhombus's documentation describes
static-linking into a minimal freestanding binary the way s7 and Janet
both do; Racket's own embedding guide assumes a full Racket runtime
environment (`scheme_dynamic_require`, `.zo` bytecode loading) present at
the embedding site, not a self-contained guest with no OS underneath.
Racket is a Lisp-1 like s7 and Janet, but weight, not namespace
discipline, is what rules it out here.

Shrubbery notation (https://docs.racket-lang.org/shrubbery/index.html),
the indentation-based grouping layer Rhombus itself is built from, is a
narrower and separable idea from option 5: its own documentation
describes it as text-level conventions that "partially group input" and
"leave further parsing to another layer," independent of Racket's macro
expander or runtime. A from-scratch shrubbery-style reader sitting in
front of s7 — translating indentation-based grouping into s7's ordinary
s-expressions before evaluation — stays compatible with option 3's
freestanding-build goal, since it touches only how source text is parsed,
not what runs in the guest. No such reader exists today, for s7 or
anywhere outside Racket's own reference implementation, so this is
recorded as a possible follow-up to option 3's surface syntax, not a
decision this ADR makes.

Option 6 remains the shipping state until this tier is actually built.

### Consequences

- Good: scripted simulation content gets a path onto the
  determinism-critical side of the codebase without requiring a Lean4
  proof for every change, while keeping replay bit-identical across
  peers.
- Good: fuel metering gives every scripted call a bounded, identical
  worst-case cost on every peer; the syscall allowlist keeps the guest's
  I/O surface at zero unless Flow explicitly grants specific syscalls.
- Good: s7's freestanding-build surface is smaller than Janet's, since it
  carries no built-in networking or event loop to disable.
- Bad: this vendors a second C runtime and a new cross-compilation-to-
  RISC-V build step, on top of the existing Lean4/CMake/vcpkg/Python
  toolchain.
- Bad: the VMCALL wiring into a Flow actor and re-running the existing
  FP-stress byte-compare gate (ADR 0004's precedent) against s7's
  execution are unstarted work — this ADR records the direction, not a
  finished design.
- Bad: a devtool-only native scripting layer (REPL, cert-mint script)
  stays an open, separate question this ADR does not resolve.
