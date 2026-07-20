# Closures and list/array operations are required scope, not deferred

## Status

Accepted; supersedes checkpoint 3/4's "closures deferred, likely
unneeded" framing.

## Decision

Checkpoints 1-4 ([ADR 0015](0015-target-lcnf-phase-mono-not-impure.md)-[0025](0025-compiled-content-elf-entry-point-is-the-function-itself.md))
verified the compiler end-to-end against one function,
`hysteresisTicksFor`, and on that basis assumed closures could stay
deferred since no tested content needed them. That assumption was
checked directly against this org's actual gameplay-logic repos -
`combat`, `progression`, `loot` (the real target content this compiler
exists to serve, not incidental examples) - and is false: every one of
them uses closures pervasively in their core reducers (`combat/core/
CombatCore/Core.lean`'s `events.foldl (fun acc e => ...)`,
`progression/core/ProgressionCore/Core.lean`'s `.find?`/`.map`/`.filter`
with `fun e => ...`, `loot/core/LootCore/Loot.lean`'s `foldl`/`findIdx?`
with lambda arguments), all over `List`/`Array`. The restricted IR
([ADR 0016](0016-restricted-ir-mirrors-lcnf-pure-phase-with-rejection.md))
rejects both closures and list/array operations outright, so as it
stands it cannot compile a single real function from any of these three
repos - the gap is not an edge case, it's the whole target content
class.

## Consequences

Bad: checkpoint 5 (closures) and list/array support are both required
scope, not optional follow-ups - the compiler as built (checkpoints 1-4)
only handles scalar arithmetic, a real but narrow slice of what "compile
this org's gameplay logic" actually means. Both are substantial new
engineering: closures need a real representation (captured-environment
struct or lambda-lifting) and calling convention in the RISC-V backend;
list/array support needs either a fixed-capacity array representation
with bounds-checked access or a real allocator, either of which is a
bigger step than anything checkpoints 1-4 built. Good: this was caught
by checking real target content before committing to "closures probably
aren't needed" as a scoping decision, rather than discovering it only
once someone tried to compile a real `combat`/`loot`/`progression`
function and it failed.

Revisit trigger for scope: before resuming checkpoint 5, re-scope it
against `foldl`/`map`/`filter`/`find?` specifically (the concrete
patterns actually observed), not closures in the abstract - a narrower
"closures applied to a fixed-capacity array, non-escaping, non-stored"
subset may cover all three repos' actual usage without needing a full
general closure representation, but that needs checking against the
real files, not assumed.
