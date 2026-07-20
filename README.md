# weft-warp-loop

- **Zone/world server**: a standalone Flow-based C++ process. Godot is
  client-only (rendering, input, XR).
- **Networking**: Flow terminates QUIC/HTTP-3/WebTransport itself, via a
  vendored `picoquic`+`picotls`+`mbedtls` stack
  (`flow-toolchain/thirdparty/`) — one process, no sidecar.
- **Process supervision**: systemd (Podman quadlets). Elixir is an
  HTTP/3 peer that connects/reconnects — it does not spawn or own the
  server process.
- **Game logic**: authored in Lean4 (`flow-toolchain/fanout-core/`,
  `flow-toolchain/sketch-core/`) — Hilbert-curve zone authority/interest
  dispatch, property-verified with Plausible — compiled via `@[export]`
  FFI into a linkable static library. The C++ actor
  (`picoquic_fanout_server`) is a thin host adapter: it owns all I/O and
  calls synchronously into the Lean4 core for every fanout decision.

## Server toolchain

- `flow-toolchain/flow/` — vendored FoundationDB `flow/` + its
  `contrib/` dependencies.
- `flow-toolchain/actorcompiler/` — vendored FDB actor-compiler (Python,
  zero extra pip deps).
- `flow-toolchain/thirdparty/{picoquic,picotls,mbedtls}` — vendored
  QUIC/TLS stack, from [`webtransportd`](https://github.com/fire/webtransportd)'s
  (BSD-2-Clause) build recipe.

See `flow-toolchain/NOTICE.md` for commit/license provenance and
`docs/decisions/` for architecture decision records.
