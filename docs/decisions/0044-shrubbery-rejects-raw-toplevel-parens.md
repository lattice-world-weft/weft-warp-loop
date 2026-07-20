# Shrubbery source rejects raw parenthesized top-level statements

## Status

Accepted; implemented in both reader ports
(`shrubbery_to_scheme.py`'s `check_no_avoidable_raw_toplevel`,
`shrubbery-to-scheme.scm`'s `check-no-avoidable-raw-toplevel`).

## Decision

Every `.shrub` file so far that needed a `define-record`/`record-with`
declaration wrote it as a raw parenthesized escape-hatch line -
`(define-record level idx walk-steps fin-bound num-inst)` - copying
the reader's documented "opaque raw Scheme text" fallback meant for
things the grammar genuinely can't express (a `lambda`'s own parameter
list, `quote`/`quasiquote` sugar, vector/char literals). That fallback
was never actually necessary here: `define-record(level, idx,
walk-steps, fin-bound, num-inst)` already parses through the reader's
ordinary `name(a, b, c)` call syntax with an identical result - a
top-level statement in this codebase is always either a `define`
block or a one-off call like this, never something that needs raw
parens, since real logic only ever lives inside a block body. Grepping
every already-committed `.shrub` file confirmed every single raw
top-level parenthesized line, with no exception, was exactly this
avoidable pattern.

Per the user's own framing: shrubbery notation exists so this content
reads like a normal programming language, not Lisp - a standalone
`(name a b c)` line is precisely the shape that goal rules out, even
though it's semantically identical to the call-syntax form. Added a
check, run before conversion, that rejects any top-level (non-block)
line starting with `(` and names the call-syntax rewrite in the error.
Scoped deliberately narrow - only top-level statements, not every raw
`(and ...)`/`(list ...)`/`(lambda ...)` used inline inside a `cond`
clause or `let*` binding elsewhere in a file, which remains the
documented, still-necessary escape hatch for forms the three-block-
keyword grammar can't express.

Retrofitted all six already-committed files with a raw
`define-record` line (capabilities, floydwarshall, iso8601duration,
rebacgoal, reentrantplanner, types) to call syntax and regenerated
every `-generated.scm` output - byte-for-byte identical to what was
already committed, confirming this is a pure surface-syntax cleanup
with zero behavior change; no re-verification of the underlying logic
was needed as a result.

## Consequences

Good: shrubbery source can no longer regress into the exact Lisp-
shaped pattern that prompted this - a real check, not just a
convention documented in a comment. Ported to both reader
implementations in the same commit, keeping the "one source of truth,
proven equivalent" discipline this session has held for the reader
itself ([ADR 0037](0037-shrubbery-reader-ported-to-s7-verified-against-python.md))
from drifting the moment one gets a feature the other doesn't. Bad:
the check is pattern-matched on "starts with `(`, not a block header"
- if a future top-level statement genuinely needs a raw parenthesized
form (unlikely given every real case seen so far is `define` or a
call), it will hit this error and need the grammar extended
properly, not just the check relaxed.
