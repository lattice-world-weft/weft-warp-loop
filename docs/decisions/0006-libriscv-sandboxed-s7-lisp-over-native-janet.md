# Sandbox a Lisp-1 in libriscv for scripted simulation content, over a native Janet layer

## Status

Accepted; large parts have since shipped — see "Implementation status"
below, current as of this rewrite.

## Decision

No embedded scripting language existed anywhere in this stack —
everything non-Lean4 was external-process orchestration. Flow's
determinism contract (every peer replays byte-for-byte identically) is
why `fanout-core`/`sketch-core` live in Lean4 rather than hand-written
C++. Janet, a single-file-embeddable Lisp-1, was the first candidate for
a native scripting layer beside Flow, but its execution model (native
floats, dynamic hashtables, no bit-identity guarantee) sits outside the
replay contract the way any native runtime would — confining it to
non-replicated work (dev/debug REPL tooling), not the
determinism-critical path. libriscv, an embeddable RISC-V CPU emulator,
changes this: it runs compiled RISC-V ELF binaries against a fixed,
software-float instruction set, so the same guest binary produces the
same execution trace regardless of host CPU/OS — a property that
matches Flow's replay needs and puts a *sandboxed guest* language on the
determinism-critical path itself, not just beside it.

Chosen: libriscv embeds in Flow as the execution substrate, and s7
Scheme (a Lisp-1, single portable C file, proven in real-time embedding
contexts like Snd/CLM) compiles to RISC-V as the guest language,
authored in shrubbery notation (an indentation-based reader in front of
s7's s-expressions — no visible parentheses to the script author, still
a Lisp-1 underneath). A Flow actor calls guest functions via libriscv's
VMCALL pattern, under `machine.simulate(max_instructions)` fuel metering
and an explicit per-syscall allowlist — the same call shape
`fanout-core`'s exported FFI already uses. Lean4's scope is unchanged:
`fanout-core`/`sketch-core`/the beautify solver stay the proof-verified
kernel; s7-on-libriscv is an additional tier underneath it for content
that changes too often to prove every time (mission scripts, loot
tables, NPC behavior).

Rejected: Janet-as-guest (its fibers/event-loop/socket-I/O assume
language-owned scheduling, needing stripping for a freestanding build —
s7 carries none of that to remove); AtomVM/BEAM-Lisp (BEAM's
scheduler/GC/float carry no bit-identical-replay guarantee, so it
wouldn't move any workload onto the determinism-critical path);
Racket/Rhombus-as-guest (Rhombus is a surface syntax on the full
Racket/Chez runtime, no static-linking-into-a-minimal-freestanding-binary
story the way s7 and Janet both have). Shrubbery notation itself is
separable from Rhombus/Racket — its own docs describe it as "leaving
further parsing to another layer" — so adopting it as s7's surface
syntax costs nothing against the freestanding-build goal that ruled
Racket out.

### Implementation status

- Done: libriscv v1.18 vendored and wired into CMake, with a host-side
  smoke test proving fuel metering bounds execution and repeated runs
  produce identical instruction counts.
- Done: s7 vendored; a real newlib toolchain (xPack `riscv-none-elf-gcc`)
  compiles it cleanly for RISC-V — no hand-built libc, no musl.
- Done: s7 actually runs inside libriscv, verified against real
  evaluated values, not just "it linked."
- Done: the VMCALL boundary and fuel metering are proven deterministic —
  two independent `Machine` instances given the same call sequence
  produce byte-identical instruction counts, repeatably.
- Done: called from a real Flow actor (`s7_riscv_actor.actor.cpp`),
  transformed by the vendored actor-compiler, linked against the real
  `flow.lib` — confirms libriscv's sandbox model is compatible with
  Flow's deterministic replay.
- Reversed: a separate native-host s7 devtool tier was built, then
  deleted once the sandboxed path was proven — s7 now has exactly one
  execution path, inside libriscv.
- Open: the fuel budget per call site has no sizing basis yet (Flow has
  no fixed-tick concept to size against) — a 2,000,000-instruction
  ceiling is a placeholder, not a sized answer.
- Not started: the shrubbery-style reader (the guest still takes plain
  s7 s-expression text), narrowing the syscall table to default-deny
  (the guest currently gets the full Linux syscall surface, not an
  `exit`-only allowlist), and FP-stress byte-compare re-verification
  against real scripted content once any exists beyond arithmetic/string
  smoke tests.

## Consequences

Good: scripted content gets a path onto the determinism-critical side of
the codebase without a Lean4 proof per change, while staying
replay-identical across peers; fuel metering bounds worst-case cost
identically on every peer; s7's freestanding-build surface is smaller
than Janet's (no networking/event loop to strip). Bad: this vendors a
second C runtime and a new RISC-V cross-compilation step; the shrubbery
reader, syscall narrowing, and FP-stress re-verification remain
unstarted work; a devtool-only native scripting layer stays a separate,
unresolved question.
