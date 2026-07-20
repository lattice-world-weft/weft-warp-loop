# Don't reimplement GDScript via shrubbery+s7 - adopt godot-sandbox-gdscript-compiler directly if GDScript-in-sandbox is wanted

## Status

Accepted.

## Decision

Reviewed the claim that "s7, a Scheme interpreter, as a typed GDScript
compiler on libriscv" (referencing
https://github.com/v-sekai-multiplayer-fabric/godot-sandbox-gdscript-compiler,
via shrubbery) — **no, not as stated**.
`godot-sandbox-gdscript-compiler` is a from-scratch native compiler
(its own lexer/parser/AST/IR/optimizer/register allocator/RISC-V
codegen/ELF builder) that compiles real GDScript source directly to
RISC-V machine code for Godot Sandbox. Shrubbery
([ADR 0006](0006-libriscv-sandboxed-s7-lisp-over-native-janet.md)/
[0007](0007-s7-shrubbery-toolchain-scope-and-elixir-nif-comparison.md))
is only an indentation-based *reader* layer in front of s7's own
s-expressions — it changes how text is grouped into syntax trees, not
what semantics run underneath, and its own docs describe it as
deliberately "leaving further parsing to another layer." It has no
notion of GDScript's actual grammar
(`func`/`var`/`class_name`/`extends`/`@export`/type hints), and real
`.gd` source is not shrubbery notation — a shrubbery reader in front of
s7 cannot parse existing GDScript files as-is.

What would actually be needed to call it "GDScript": not just a reader,
but GDScript's semantics rebuilt on top of s7 — a Variant type system,
class/inheritance dispatch, the Node-tree/signal model, typed
properties — none of which s7 or shrubbery provide, and all of which
the referenced compiler already implements natively, targeting
RISC-V/Godot Sandbox directly.

## Consequences

Good: avoids reimplementing GDScript's full semantics in s7 for a
worse-fitting result than the compiler that already solves this exact
problem end to end. If GDScript-in-sandbox is genuinely wanted later,
adopt/vendor `godot-sandbox-gdscript-compiler` directly instead (see
[ADR 0047](0047-godot-sandbox-vs-bespoke-s7-stack-reviewed-superseded.md)
for that broader tradeoff). Bad: none - this closes an option that
looked plausible from the names alone (shrubbery/s7 could look
GDScript-adjacent) but wasn't real once checked against what each side
actually implements. Shrubbery stays scoped to what ADR 0006 chose it
for: a friendlier surface syntax over s7's own s-expressions for this
repo's fuel-bounded simulation-scripting tier (mission scripts, loot
tables, NPC behavior, taskweft's ported planner) — a narrower,
determinism-driven problem than general GDScript compatibility.
