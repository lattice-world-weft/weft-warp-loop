# Console-grade guest/host data structures, referencing godot-sandbox's actual ABI

## Status

Accepted; `guest_eval_int`'s plain register return already complies.
Bound-checking on expression length and a tagged-value type for
multi-field results are not yet implemented.

## Decision

Per ADR 0010's console-shipping concerns, the guest/host boundary should
follow "console grade" data-structure discipline: fixed size, bounded,
no unchecked pointer-chasing across the boundary — not invented from
scratch, referenced against `godot-sandbox`'s real, shipping
implementation (`src/guest_datatypes.h`, `src/guest_variant.cpp`).
Concretely: `GDNativeVariant` is a fixed-size (`__attribute__((packed))`)
tagged union — a 1-byte type tag plus a union of fixed-size payloads
(double, uint64, vec2/3/4, ivec2/3/4, color, object handle) — the fast
path for scalar/vector values never touches guest memory at all, it's
just register/stack bytes. Variable-length data (`GuestStdU32String`)
uses an explicit `{ptr, size, capacity}` descriptor into guest memory,
with a hard `max_len` check (throwing, not truncating silently) before
the host ever reads past it.

Checkpoint 1 of the "real content through the interpreted s7 path" plan
(`guest_eval_int`) already complies with the fast-path half of this
without any redesign needed: a plain `int64_t` returned via the RISC-V
return register is the best case of this pattern — no memory crossing
at all, nothing to bound-check, verified working (`(+ 1 2)` → `3`).
What's not yet done: the *expression string* argument (`const char*`)
crossing into the guest has no explicit length bound today, unlike
`GuestStdU32String`'s `max_len` check — this was already true before
this checkpoint (it's `guest_eval`'s existing, proven mechanism from
ADR 0006), not a new gap introduced here, but it should gain an explicit
bound before real content authoring leans on it. If future content needs
to return more than one scalar (a loot roll returning both an item id
and a quantity, say), the reference is `GDNativeVariant`'s shape — a
fixed-size tagged union — not an ad-hoc struct invented per call site.

## Consequences

Good: the ABI question for scalar returns is already answered and
already correct, by construction, not by luck — a bare register value
is the strongest form of "console grade" (nothing to bound-check because
nothing crosses memory). Reusing a real, shipping reference (godot-
sandbox) instead of inventing our own tagged-union layout avoids
re-deriving a design real console ports have already validated. Bad: the
expression-string argument's lack of an explicit length bound is a real,
outstanding gap, now named rather than implicit; it should close before
checkpoint 2 authors real content against this path, matching
`GuestStdU32String`'s own discipline of checking before touching guest
memory, not after.
