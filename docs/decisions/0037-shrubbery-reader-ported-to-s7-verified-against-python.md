# The shrubbery reader itself ported to s7, verified against the Python version's own output

## Status

Accepted; implemented and verified
(`flow-toolchain/riscv-guests/shrubbery/shrubbery-to-scheme.scm`).

## Decision

Per explicit user direction, `shrubbery_to_scheme.py` (ADR 0033) moves
to s7 itself — closing the remaining Python toolchain dependency for
content authoring, once proven. Ported as a faithful, line-for-line
structural translation (same functions, same grammar, same
explicit-subset scope), using `open-input-string`/`read-line` for line
splitting and manual character-scanning loops (mirroring the Python
version's own depth-tracking loops) for comment-stripping, call-syntax
parsing, and depth-aware comma/colon splitting.

Verified two ways, not just "it runs": byte-for-byte output equality
against `shrubbery_to_scheme.py`'s own known-good output, on both a
synthetic snippet and `loot.shrub`'s real content.

Two real bugs found during verification, both from mechanical
translation slips, not design flaws: (1) `term->sexpr`'s string-append
chain was missing its closing paren entirely — every call-syntax
expansion produced unbalanced output. (2) The `let`/`let*` block-header
branch merged Python's two structurally different cases (named-let,
where the prefix is stripped before parsing the name; plain-let, where
the `let`/`let*` prefix *is* the name `parse-call` extracts) into one
branch, breaking the plain `let*(...)` case specifically — the exact
form `loot.shrub`'s `xorshift32-next32` depends on. Both caught by the
Python-output comparison, not by inspection.

A third, non-bug finding: this reader's own hand-written tree-walk
(`build-block-tree`'s repeated `list-ref`/`length` calls) is O(n²) and
genuinely expensive — `2,000,000` instructions (this tier's usual
default) is not enough even for a two-function snippet (measured:
`1,271,788`); `loot.shrub` costs `5,082,828`. This is real and
documented, not hidden: offline preprocessing tooling gets a generous
fuel budget (`200,000,000`, one-time, not a per-call runtime cost),
distinct from actual game-content calls which stay under the default.

## Consequences

Good: content authoring no longer needs Python at all — the full
pipeline (write `.shrub` → convert → run) can live entirely inside this
project's own s7/libriscv toolchain. The Python version stays as the
reference implementation for now (both exist, checked against each
other), not immediately deleted — matching this session's "prove
first, retire what's now redundant" pattern rather than a same-commit
swap. Bad: the O(n²) tree walk is a real performance cost that would
matter if this reader were ever moved onto a hot path (it currently
isn't — offline preprocessing only); optimizing it (vectors instead of
lists, a single-pass tokenizer) is legitimate future work, not
addressed here since correctness came first.
