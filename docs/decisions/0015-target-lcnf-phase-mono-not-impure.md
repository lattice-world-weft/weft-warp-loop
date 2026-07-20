# Target Lean.Compiler.LCNF's Phase.mono as the compiler's IR source, not Phase.impure

## Status

Accepted; implemented (`flow-toolchain/fanout-core/IrDumpScratch.lean`,
checkpoint 1 of the ADR 0013/0014 compiler).

## Decision

ADR 0013 proposed reading a declaration's elaborated form via Lean4's
own metaprogramming API rather than writing a Lean4 parser, without
fixing which internal representation to query. Verified directly against
this toolchain (v4.30.0): `Lean.Compiler.LCNF.main #[declName]` followed
by `getDeclAt? declName phase` retrieves a real declaration's compiler
IR with zero hand-written frontend. `Phase.impure` — the final,
closest-to-codegen phase — is not queryable this way; it throws
`"Internal compiler error: getDecl? on impure is unuspported for now"`
(upstream's own typo), an actual toolchain limitation, not a bug in this
project's code. `Phase.mono` is queryable and returns exactly the shape
needed: already erased, already monomorphized (verified against
`Fanoutcore.hysteresisTicksFor` — `max 1 (lookaheadTicks / 2)` lowers to
plain `UInt64.shiftRight`/`UInt64.decLe` primitive calls and a `Bool`
cases split, no dependent types or typeclass dictionaries visible).

## Consequences

Good: no need to hand-write erasure or monomorphization — Lean4's own
compiler already did both by the time `Phase.mono` is reachable. Bad:
`Phase.mono` is one step short of `Phase.impure`'s fully codegen-ready
form (explicit boxing/reference-counting insertion happens after
`Phase.mono`), so checkpoint 3's codegen has to handle a slightly higher-
level IR than the compiler's own C/LLVM backend does — traded for
`Phase.impure` simply not being queryable at all in this toolchain
version.
