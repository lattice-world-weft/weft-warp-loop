# fanout-core

The pure logic for the picoquic fanout bridge — a slot map (generational
index) tracking which connections are subscribed to which room, and the
publish-time dispatch-target computation. No I/O. This project's own
code, in Lean4 (`lean-toolchain` pins `leanprover/lean4:v4.30.0`), per
this repo's `lean-*` hexagon-core convention: a pure kernel core, with a
flat C host adapter (the Flow-driven bridge actor, not yet written)
owning all real I/O and calling into this core's exported functions.

`Fanoutcore/SlotMap.lean` — the slot map itself: `alloc`/`free`/`find`/
`update`, generational IDs, bounds-checked (never the panicking `[i]!`)
since every id a caller hands in is untrusted.

`Fanoutcore/FanoutCore.lean` — `Room` (a subscriber list) and `State`
(a `SlotMap Room`), plus `Id.pack`/`Id.unpack` to cross a slot-map `Id`
over FFI as a single `UInt64`.

`Fanoutcore/Ffi.lean` — the exported, C-callable surface
(`fanout_init`, `fanout_alloc_room`, `fanout_free_room`, `fanout_sub`,
`fanout_unsub`, `fanout_pub_targets`), backed by one process-wide
`IO.Ref State` — safe without a lock because the C++ host adapter is a
single Flow actor calling in sequentially, the same way Flow already
serializes any other actor's access to shared state.

`test_ffi.c` is not part of the build (`.gitignore`s its own compiled
output) — a standalone local harness proving the FFI boundary and the
slot map's generational-safety guarantee: `lake build`, then compile
`test_ffi.c` alongside `.lake/build/ir/Fanoutcore*.c` against
`libleanshared`/`libInit_shared` from the Lean toolchain
(`lean --print-prefix`), matching the standard Lean4 FFI-consumer
pattern (initialize the runtime, call `initialize_fanoutcore_Fanoutcore`,
then call the exported functions directly — Lean4 elides the `IO` world
token from these signatures at this optimization level, so there is no
explicit world argument to pass).
