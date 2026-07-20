# Standardize the sandboxed deterministic-content language on s7 Scheme (Lisp-1), over GDScript, taskweft's own DSL, or a freestanding Lean4 port

## Status

Proposed (design record only; no code changes accompany this ADR).

## Context and Problem Statement

This stack now touches four languages with some claim to determinism:
Lean4 (`fanout-core`, `sketch-core` — ahead-of-time compiled, formally
verified, native, trusted, linked into the host binary via `@[export]`
FFI), s7 Scheme running as a libriscv guest (ADR 0006 — sandboxed,
fuel-metered, proven byte-identical instruction counts across
independent `Machine` instances), GDScript compiled to RISC-V via the
third-party `godot-sandbox-gdscript-compiler` (same libriscv substrate,
not yet vendored or verified in this repo), and taskweft's own RECTGTN
JSON-LD domain language (a declarative HTN planning DSL, already in
production use here as `plan/bootstrap-domain.json`). Maintaining more
than one general-purpose language on the determinism-critical path
multiplies the verification burden ADR 0004's byte-compare precedent
already establishes for every such addition. This project supports
exactly one going forward. The deciding axis is code power — expressive
capability, not developer familiarity or engine interop, which is the
axis ADR 0010 already used for a different question (the client
rendering/engine-boundary architecture, not this one).

Scope note: this question is about the **sandboxed, frequently-changing
content tier** ADR 0006 defined (mission scripts, loot tables, NPC
behavior, and the game-features doc's spell-resolution scripts) — not
about `fanout-core`/`sketch-core`'s ahead-of-time-compiled kernel, which
plays a structurally different role (trusted, static, proof-verified,
recompiled and relinked on every change) and is addressed separately
below.

## Decision Drivers

- Code power, as asked: macro/metaprogramming facilities, closures,
  homoiconicity, and what a script author can actually express, not
  which syntax is most familiar.
- What's already proven in this exact repository beats what's merely
  claimed by a third-party project: s7 has a real Flow actor
  (`s7_riscv_actor.actor.cpp`) calling into it through the actor-compiler,
  with two independently-initialized libriscv `Machine`s confirmed to
  produce identical total fuel cost. `godot-sandbox-gdscript-compiler` is
  unvendored and unverified against this repo's own determinism-proof
  methodology.
- A freestanding, sandboxable runtime is a hard requirement for this
  tier (ADR 0006's whole reason for existing) — a language with no
  embeddable single-file-or-small-footprint runtime cannot fill this
  role regardless of how much code power it has in its normal, full,
  host-native form.
- Gall's Law (already cited repo-wide): don't build an unproven
  replacement for a working system before its narrower pieces are
  proven.

## Considered Options

1. **s7 Scheme (Lisp-1) on libriscv**, already ADR 0006's choice for
   this tier — real macros, closures, quasiquote-based metaprogramming,
   a Lisp-1's single namespace, proven running sandboxed in this repo.
2. **GDScript on libriscv**, via `godot-sandbox-gdscript-compiler` — a
   deliberately minimal, accessibility-first scripting language: no
   macro system, no closures as a first-class metaprogramming tool, by
   design (it optimizes for approachability, not expressive power).
3. **taskweft's RECTGTN/JSON-LD** as the single language — a declarative
   planning DSL, not general-purpose; it can express task decompositions
   and goals but has no way to express arbitrary imperative logic
   (combat math, movement, spell resolution) at all.
4. **Port Lean4 itself into a freestanding, libriscv-sandboxed runtime**,
   collapsing the kernel and content tiers into one language and
   claiming the strictly highest code power available (dependent types,
   tactics, typeclasses, proof automation — a strictly larger expressive
   envelope than any Lisp).

## Decision Outcome

Chosen option 1: s7 Scheme (Lisp-1) on libriscv, as the single language
for this repository's sandboxed, frequently-changing content tier.

On code power specifically, option 1 beats option 2 outright: a Lisp-1's
macro system and closures let script authors build their own abstractions
(a DSL for loot tables, a combinator library for NPC behavior trees)
inside the language itself, while GDScript's syntax is deliberately
closed to that kind of extension — its advantage, familiarity to Godot
developers and tight Variant/engine interop, is real but is ADR 0010's
axis, not this one. Option 3 is disqualified outright on code power: it
cannot express general imperative logic at all, only task
decomposition — valuable for what taskweft already does, but not a
candidate for "the one language" this repo's scripted content runs in.

Option 4 has the honest answer to "greatest code power" — Lean4's
dependent types and proof automation are strictly more expressive than
anything a Lisp offers — but it is disqualified by the freestanding-
runtime requirement, not by code power. No embeddable Lean4 runtime
exists anywhere in this ecosystem or upstream; s7 and the GDScript
compiler both already have proven freestanding RISC-V builds, Lean4 has
none. Building one would mean porting Lean4's own GC and runtime to a
freestanding target from scratch, a categorically larger and entirely
unproven undertaking compared to either alternative, and directly
against Gall's Law. Lean4 stays exactly where ADR 0006 already put it:
the ahead-of-time-compiled, trusted, formally verified kernel — a
separate tier by necessity, not a fourth competitor for this tier's
single-language slot.

This narrows, and where it conflicts, supersedes, this session's earlier
lean toward GDScript for programmer-authored gameplay logic: that
recommendation was scoped to engine interop and developer familiarity
(ADR 0010's concern), not to this repo's determinism-critical sandboxed-
content tier, where code power is the stated criterion and s7 wins it.
GDScript-via-godot-sandbox remains a live option for client-side,
non-replicated gameplay code under ADR 0010, unaffected by this decision.

### Consequences

- Good: no new vendoring, no new build target — s7-on-libriscv is
  already vendored, built, and proven in this repo.
- Good: one language for all sandboxed content (mission scripts, loot
  tables, NPC behavior, spell resolution) instead of a split surface,
  reducing the byte-compare/determinism-verification burden ADR 0004
  already established as the cost of each additional language.
- Bad: script authors need Scheme, not GDScript — a real cost against
  Godot-developer familiarity, accepted here because the deciding axis
  is code power, not onboarding ease.
- Bad: s7 has no static type system or formal verification of its own;
  content that would benefit from a stronger correctness guarantee than
  runtime testing gets no help from this tier.
- Revisit trigger: if a specific content class turns out to need a
  correctness guarantee runtime testing can't provide (the concrete
  failure mode a fallback needs to answer), promote that narrow slice
  into the Lean4 kernel tier and compile it ahead-of-time, rather than
  introducing a second general-purpose scripting language. This mirrors
  the split ADR 0006 already drew between kernel and content — the
  fallback is shrinking what's dynamic, not switching languages.
