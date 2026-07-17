# weft-warp-loop

Bootstrap seed for the `lattice-world-weft` project: an original, PSO-style
(hub → instanced field missions → combo action combat → loot contention)
multiplayer game, with an Elixir/OTP platform layer, a Flow-based C++
zone/world server, and a Godot client.

## Why this repo exists

The broader [v-sekai-multiplayer-fabric](https://github.com/v-sekai-multiplayer-fabric)
stack has an extensive set of architecture decision records describing an
intended design (WebTransport/HTTP-3 transport, hexagon-core game logic,
Elixir platform/updater), but as of 2026-07-17 **none of the gameplay or
networking layer actually runs yet** — the only proven-working piece is a
bare `fabric-godot-core` engine boot. The ADR-described `godot-loop-slice`
vertical slice does not run despite documentation claiming otherwise.

Per [Gall's Law](https://en.wikipedia.org/wiki/John_Gall_(author)#Gall's_law) —
a complex system that works is invariably found to have evolved from a simple
system that worked — this repo starts over from the smallest real increment
instead of assuming the documented architecture already exists.

## Scope

1. **Plan** — a `taskweft` HTN plan artifact (`plan/bootstrap.jsonld`)
   encoding the increments below as an explicit, machine-checkable roadmap.
2. **First working increment** — a minimal HTTP/3 round-trip: one message
   sent from an Elixir client to a standalone Flow-based C++ server process
   and back. No game state, no tick loop, no gameplay yet — just proof the
   wire works.

## Roadmap (each step must be proven working before the next begins)

1. Flow's actor-compiler builds and a minimal Flow program runs standalone
   (outside FoundationDB) as this project's server toolchain.
2. One HTTP/3 message round-trips between an Elixir client and that
   Flow-based C++ server process.
3. A server-side loop ticks on an interval and holds one piece of state
   (e.g. a player's position).
4. Client (Godot) input updates that state; server pushes it back; client
   renders it. This is the first genuine "playing loop" — one entity moving
   in one empty room.
5. Everything else (combat combos, loot, hub/field structure, the full
   hexagon-core architecture) is layered on **after** step 4 is real,
   one proven increment at a time.

## Process/deployment model

**Architecture pivot (2026-07-17):** the zone/world server is a **standalone
Flow-based C++ process**, not headless Godot. This reverses the
v-sekai-multiplayer-fabric ADR assumption that a headless `fabric-godot-core`
instance is the zone server — that assumption is stale for this repo.
**Godot is client-rendering only** here.

Rationale: Flow (Apache-2.0, part of `apple/foundationdb`) already has
~15 years of production-proven byte-for-byte deterministic whole-program
replay (simulated network/clock/RNG interception, for exhaustive
deterministic testing of distributed-system behavior). Building an
equivalent property ourselves — e.g. a bespoke "simulated adapter" bolted
onto Godot's loop — would mean designing and proving something new and
unproven at that rigor. Per Gall's Law, starting from the system that
already has this specific property working (Flow) is the more reliable
move, even though it's a different base than Godot's engine loop.

The server process runs standalone (not an Elixir NIF — can't safely host
an indefinitely-running loop, would crash the whole BEAM VM on a fault; not
an Erlang C-node — would duplicate the wire protocol, since real clients
already need HTTP/3). Process lifecycle (start/stop/restart-on-crash) is
owned by **systemd + systemd (Podman) quadlets**; Elixir's role is purely
as an HTTP/3 network peer — it connects, detects disconnection, and
reconnects with backoff, but does not spawn or own the server process.

**Known integration cost, not yet resolved:** Flow's actor-compiler is a
Python-based preprocessor tightly wired into FoundationDB's own CMake
build, not a drop-in library — standing it up as this project's own build
toolchain is itself a prerequisite step (roadmap step 1) before any
HTTP/3 round-trip code can be written. The existing hexagon-core ADRs
(Lean4 kernel cores + flat C host adapters, deterministic-cores-integer-
seeded-rng) likely map onto Flow's C++ host-adapter layer directly — the
"flat C host adapters" become Flow actors.

## Reference material (study only — not adopted as code)

- [`newserv`](https://github.com/fuzziqersoftware/newserv) (MIT) — real,
  production-proven Phantasy Star Online server logic/protocol design.
  Server-only; requires the original proprietary Sega client to run, and
  embeds Sega-derived reverse-engineered game data — reference for genre
  mechanics and protocol design only, never for code, data, or assets.
- [Carbon Engine](https://github.com/carbonengine) (`destiny`, `io`,
  `scheduler` — MIT) — CCP Games' real, production EVE Online world-simulation
  engine and networking layer. Studied for real-MMO simulation/networking
  design ideas only, not adopted as code.

## Server toolchain

[FoundationDB `flow`](https://apple.github.io/foundationdb/flow.html)
(Apache-2.0) is adopted directly as the server's base — not just a design
reference. See "Process/deployment model" above for rationale and known
integration cost.

`setup_flow_toolchain` (roadmap step 0) is split into two proven
sub-increments, in order:

1. **The actor-compiler builds and runs standalone, cross-platform.**
   `flow-toolchain/actorcompiler/` vendors the **official upstream Python
   actor-compiler** (`flow/actorcompiler_py/` — see `flow-toolchain/NOTICE.md`
   for exact commit and license provenance), not the legacy C#/.NET one.
   Per `cmake/CompileActorCompiler.cmake`, the Python implementation is
   FoundationDB's own **current default** (`ACTORCOMPILER_COMMAND = python
   -m flow.actorcompiler_py`); C#/.NET is only a fallback path
   (`FDB_USE_CSHARP_TOOLS`). We deliberately chose the Python version:
   zero external dependencies (stdlib only), and this project already
   needs Python3 for the next increment's `ProtocolVersion.h` codegen
   (Jinja2-templated) — one toolchain instead of two. (An earlier revision
   of this PR vendored the C# implementation with a `dotnet`-based
   self-contained-publish build; that was reverted once the Python default
   was discovered — see git history on this branch.) CI
   (`.github/workflows/flow-toolchain.yml`, matrix: `ubuntu-latest` +
   `windows-latest` + `macos-latest`) runs it against
   `flow-toolchain/examples/hello_actor.actor.cpp`, asserting the output
   is transformed plain C++ (no leftover `ACTOR` declaration). **Status:
   in progress, this PR.**
2. **A minimal flow C++ runtime links and actually runs one actor.**
   In progress. `flow/`'s upstream `CMakeLists.txt` compiles the *entire*
   `flow/` directory as a single library (no networking/non-networking
   split), depending on sibling monorepo directories
   (`contrib/{crc32,stacktrace,folly_memcpy,SimpleOpt,libb64}`), Boost,
   OpenSSL, and Python3+Jinja2 for `ProtocolVersion.h` codegen. Per Gall's
   Law, this is being vendored as the whole faithful configuration rather
   than a hand-picked subset, since there's no officially-sanctioned
   minimal build to evolve from — a hand-picked subset would itself be an
   unproven new system. This is a substantial, multi-commit extraction,
   not a quick follow-up.

## WebTransport/HTTP-3: Flow terminates QUIC directly

**Superseded design, kept here for the record:** an earlier version of
this plan had a separate sidecar process,
[`webtransportd`](https://github.com/fire/webtransportd) (BSD-2-Clause),
terminate QUIC/HTTP-3 and bridge framed bytes to the Flow server over a
local IPC channel (first stdio, then an attempted duplex-socket
redesign for cross-platform parity). That local-IPC design grew real
complexity (a security handshake to authenticate the child's connection,
a from-scratch Windows Winsock implementation) trying to solve a problem
— cross-platform parity for a bridge — that turned out not to be worth
solving, once we asked whether the bridge needed to exist at all.

**Current decision (2026-07-17): Flow terminates QUIC/HTTP-3/WebTransport
itself, in one process.** Flow's own `IUDPSocket` becomes the transport;
`picoquic` + `picotls` + `mbedtls` (the same real, proven QUIC/TLS stack
`webtransportd` itself uses — not a from-scratch protocol
implementation) get vendored directly into this project alongside the
rest of the flow runtime. This eliminates the local-IPC bridge problem
entirely — no pipes, no sockets, no handshake, no second process to
supervise.

**The tradeoff, explicit, not an oversight:** `picoquic`/`picotls`/
`mbedtls` parse genuinely untrusted, attacker-controlled input — real
QUIC packets and TLS handshakes from arbitrary internet clients. Running
that in the *same process* as the trusted game simulation (rather than
an isolated sidecar) means a memory-corruption bug in QUIC/TLS parsing
now directly threatens live game state and crashes the whole server
instead of an independently-restarted sidecar. This is the same
tradeoff considered (and rejected) earlier for an in-process/`dlopen`
approach to `webtransportd` — accepted here deliberately, in exchange
for a real, significant reduction in moving parts, after the
alternative (a clean two-process bridge) proved to cost more complexity
than expected to get right across all three platforms.

`webtransportd` remains a real, independent, useful project on its own
— its `child_socket` adapter (POSIX duplex-socket alternative to its
stdio pipes) is still merged there
([fire/webtransportd#12](https://github.com/fire/webtransportd/pull/12))
— it's just no longer part of *this* project's runtime architecture.

**Status: decided, not yet implemented.** `flow-toolchain/webtransportd_frame/`
(the vendored frame codec for the old bridge design) has been removed —
it's not needed when Flow terminates QUIC itself. Vendoring
`picoquic`/`picotls`/`mbedtls` into `flow-toolchain/` and wiring them
against flow's `IUDPSocket` is the next milestone
(`vendor_picoquic_into_flow` in the plan), before `prove_http3_roundtrip`.

## Client engine loop

Godot's existing C++ main loop is used for the **client only** (rendering,
input capture, XR). It is not the zone/world server in this repo.

## License constraints

No GPL or AGPL (any version) dependencies or derived code. No Colobot.
All game content, assets, and design must be original work — genre
conventions may be studied from reference material above, but no data,
assets, or verbatim protocol/code may be copied from copyrighted or
copyleft sources.

## License

MIT — see `LICENSE`.
