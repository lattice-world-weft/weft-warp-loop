# Mechanize the Lean4-to-s7 port via a staged compiler, guided by godot-sandbox-gdscript-compiler's pipeline shape

## Status

Proposed.

## Decision

ADR 0012 left the Lean4-proved-function → s7 port manual. Build a small
staged compiler instead, using `godot-sandbox-gdscript-compiler`
(lexer → parser → AST → IR → optimizer → codegen → ELF) as the
structural reference, adapted to a source-to-source shape: read a proved
declaration's elaborated `Lean.Expr` directly via Lean4's own
metaprogramming API (no hand-written Lean4 lexer/parser needed, unlike
GDScript, which had no existing compiler to borrow from), lower to a
small IR restricted to plain data and total functions, reject anything
that doesn't erase cleanly (dependent types, proof terms) rather than
mistranslate it, and emit s7 source text. No RISC-V codegen, register
allocator, or ELF builder needed — s7 already reaches libriscv through
`s7_riscv_actor.actor.cpp`'s existing, proven path.

## Consequences

Good: reuses a proven pipeline shape instead of inventing one; smaller
scope than the GDScript compiler, since there's no backend codegen at
all. Bad: the erasure-safety check is new work with no analog in the
reference project — GDScript has no dependent types to reject in the
first place.
