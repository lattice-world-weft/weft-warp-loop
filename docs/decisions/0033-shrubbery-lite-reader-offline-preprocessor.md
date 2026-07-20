# A minimal shrubbery-lite reader, as an offline preprocessor, closes ADR 0006's unstarted item

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/shrubbery/shrubbery_to_scheme.py`).

## Decision

ADR 0006 named a shrubbery-style reader as s7's intended surface syntax
from the start but never built it ("Not started"). Built now, scoped
explicitly as a documented subset of real Racket shrubbery
(https://docs.racket-lang.org/shrubbery/), not a reimplementation of its
full grammar: indentation-based blocks (Python's off-side rule),
`name(a, b, c)` call syntax, and exactly three block-opening forms
(`define name(...):`, `let`/`let*` with a `name: value` binding list,
`cond:` with `| test: result` clauses). Anything else ending in `:` is a
hard parse error naming what's unsupported — the same
explicit-rejection-over-silent-guessing discipline already established
for the RISC-V compiler's restricted IR ([ADR 0016](0016-restricted-ir-mirrors-lcnf-pure-phase-with-rejection.md)).

Runs as an offline preprocessor (shrubbery text → s-expression text),
not embedded in the s7 guest — matching ADR 0028's interpret-first
direction, this keeps the guest itself unchanged (still just parsing
plain s-expressions) while giving content authors indentation-based
syntax at the file-authoring layer. Verified against real content, not
a toy example: `loot.shrub` (the shrubbery-lite source for `loot.scm`'s
actual logic) converts to s-expressions that, run through the
already-proven golden-vector test unchanged, produce the identical
result (`3`) deterministically.

Two real bugs found while verifying, not while designing: `#` collides
with Scheme's own `#x.../#t/#f` literal syntax as a comment marker (this
reader's own non-call terms pass through as opaque raw Scheme text, so a
`#`-comment silently truncated every such literal) — fixed by switching
to `//`. A cond clause whose result opens its own nested block (`| else:
let*(...):`) was being handled by discarding the result text entirely
and only processing the nested block as a generic body, silently
dropping the `let*` wrapper — fixed by recursing through the same
header-dispatch every other block form uses, plus a depth-aware colon
splitter (naive `.partition(':')` would otherwise split inside a nested
binding list's own colons).

## Consequences

Good: ADR 0006's oldest unstarted item is closed, verified against real
content rather than a synthetic example; the explicit-subset scoping
means growing the grammar later (more block forms, infix operators) is
additive, not a rewrite. Bad: this is Python, a new toolchain dependency
for content authoring specifically (separate from the C++/Lean4/s7
toolchain this repo otherwise needs) - per the user's own follow-up,
this reader itself is slated to be ported to s7, removing that
dependency, once proven (this ADR is that proof). No infix operators,
no full Racket shrubbery operator/precedence handling, no multi-line
continuation beyond simple indentation - real gaps against the full
spec, acceptable for the content shapes ported so far
(loot/combat/progression), not yet tested against anything requiring
more.
