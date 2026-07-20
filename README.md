# weft-warp-loop

Bootstrap seed for `lattice-world-weft`: an original, PSO-style (hub →
instanced field missions → combo action combat → loot contention)
multiplayer game, with an Elixir/OTP platform layer, a Flow-based C++
zone/world server, and a Godot client.

The roadmap lives as data, not prose, in `plan/bootstrap-domain.json` /
`plan/bootstrap-plan.json` (a `taskweft` HTN plan) — each step is proven
working before the next begins.

## Architecture

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

## Reference material (study only — not adopted as code)

- [`newserv`](https://github.com/fuzziqersoftware/newserv) (MIT) — PSO
  server logic/protocol reference.
- [Carbon Engine](https://github.com/carbonengine) (MIT) — EVE Online
  world-simulation/networking reference.

## License

MIT — see `LICENSE`. No GPL/AGPL dependencies or derived code, no
Colobot; no copyrighted or copyleft game data/assets.
