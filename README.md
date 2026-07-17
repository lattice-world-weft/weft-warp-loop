# weft-warp-loop

Bootstrap seed for `lattice-world-weft`: an original, PSO-style (hub →
instanced field missions → combo action combat → loot contention)
multiplayer game, with an Elixir/OTP platform layer, a Flow-based C++
zone/world server, and a Godot client.

The broader [v-sekai-multiplayer-fabric](https://github.com/v-sekai-multiplayer-fabric)
stack has architecture decision records describing an intended design, but
its gameplay and networking layers do not run; the only proven-working
piece there is a bare `fabric-godot-core` engine boot. This repo evolves
from the smallest real increment instead of assuming that documented
architecture exists (Gall's Law: a complex system that works evolves from
a simple system that worked).

The roadmap lives as data, not prose, in `plan/bootstrap-domain.json` /
`plan/bootstrap-plan.json` (a `taskweft` HTN plan) — each step there is
proven working before the next begins.

## Architecture

- The zone/world server is a standalone Flow-based C++ process. Godot is
  the client only (rendering, input, XR) — it is not the server here.
- Flow (Apache-2.0, `apple/foundationdb`) provides ~15 years of
  production-proven byte-for-byte deterministic whole-program replay
  (simulated network/clock/RNG interception). This is the property this
  project builds on; an equivalent property built from scratch on another
  engine would itself be new and unproven.
- The server process is supervised by systemd (Podman quadlets), not an
  Elixir NIF (an indefinitely-running loop can't safely live inside the
  BEAM VM) and not an Erlang C-node (a second wire protocol alongside
  HTTP/3 is unneeded structure). Elixir is an HTTP/3 network peer that
  connects, detects disconnection, and reconnects — it does not spawn or
  own the server process.
- Flow terminates QUIC/HTTP-3/WebTransport itself, via a vendored
  `picoquic`+`picotls`+`mbedtls` stack (`flow-toolchain/thirdparty/`) —
  one process, no local-IPC bridge to a separate sidecar. This puts
  QUIC/TLS parsing of arbitrary internet input in the same process as the
  game simulation; the alternative (a separate sidecar process bridging
  framed bytes over local IPC) costs more complexity than this tradeoff
  does, once cross-platform parity for that bridge is factored in.
  [`webtransportd`](https://github.com/fire/webtransportd) (BSD-2-Clause)
  is a real, independent project on its own and is where this vendored
  stack's build recipe comes from — it is not part of this project's
  runtime.
- picoquic's own socket-loop files (`sockloop.c`, `winsockloop.c`) are
  never linked in, on any platform. picoquic's core protocol functions
  (`picoquic_incoming_packet` / `picoquic_prepare_packet`) take explicit
  byte buffers and an explicit `current_time` — no hidden I/O. All real
  socket I/O and clock reads route through Flow's own `IUDPSocket`/`now()`,
  so picoquic is exactly as simulatable as any of Flow's own networking
  code — Flow's simulator needs no picoquic-specific handling, because it
  only ever sees Flow's own primitives being called. The actor that
  drives picoquic this way does not exist yet.

## Server toolchain

`flow-toolchain/actorcompiler/` vendors FoundationDB's own Python
actor-compiler (`flow/actorcompiler_py/`) — its actual current default
(`cmake/CompileActorCompiler.cmake`: `ACTORCOMPILER_COMMAND = python -m
flow.actorcompiler_py`), not the legacy C#/.NET fallback path
(`FDB_USE_CSHARP_TOOLS`). Zero external pip dependencies, and Python3 is
already needed for `ProtocolVersion.h` codegen — one toolchain, not two.
See `flow-toolchain/NOTICE.md` for commit/license provenance.

`flow-toolchain/flow/` vendors all of FoundationDB's `flow/` directory
plus its sibling `contrib/{crc32,stacktrace,folly_memcpy,SimpleOpt,libb64}`
dependencies. Upstream's own `flow/CMakeLists.txt` compiles the entire
directory as one library with no networking/non-networking split, so
there is no officially-sanctioned minimal subset to vendor instead —
hand-picking one would itself be an unproven new configuration.
`flow-toolchain/CMakeLists.txt` (original, not copied from upstream's
monorepo-wide root) wires Boost 1.86/fmt 11.1.4/OpenSSL (`vcpkg.json`),
Python3+Jinja2 codegen, and `hello_actor_test`, which runs one real actor
(`asyncAdd`) through the real flow runtime with `g_network` initialized
but its event loop never run — the input `Future` is fulfilled before the
actor observes it, so it completes via the actor-compiler's synchronous
already-ready path.

`flow-toolchain/thirdparty/{picoquic,picotls,mbedtls}` vendors the same
QUIC/TLS stack `webtransportd` uses, from `webtransportd`'s own
already-proven vendoring/build recipe. `picoquic_vendor_test`
(`flow-toolchain/examples/picoquic_vendor_test.c`) creates and frees a
client-only `picoquic_quic_t` — no networking, proving only that the
vendored stack compiles, links, and its core create/free API works.

## Reference material (study only — not adopted as code)

- [`newserv`](https://github.com/fuzziqersoftware/newserv) (MIT) —
  production Phantasy Star Online server logic/protocol design. Requires
  the original proprietary Sega client and embeds Sega-derived
  reverse-engineered game data — reference for genre mechanics and
  protocol design only.
- [Carbon Engine](https://github.com/carbonengine) (`destiny`, `io`,
  `scheduler` — MIT) — CCP Games' EVE Online world-simulation engine and
  networking layer, studied for design ideas only.

## License constraints

No GPL or AGPL (any version) dependencies or derived code. No Colobot.
Game content, assets, and design are original work — genre conventions
may be studied from the reference material above, but no data, assets,
or verbatim protocol/code come from copyrighted or copyleft sources.

## License

MIT — see `LICENSE`.
