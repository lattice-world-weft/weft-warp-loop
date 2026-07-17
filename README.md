# weft-warp-loop

Bootstrap seed for the `lattice-world-weft` project: an original, PSO-style
(hub → instanced field missions → combo action combat → loot contention)
multiplayer game, with an Elixir/OTP platform layer and a Godot client/server.

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
   sent from an Elixir client to a standalone Godot-side process and back.
   No game state, no tick loop, no gameplay yet — just proof the wire works.

## Roadmap (each step must be proven working before the next begins)

1. Bare engine boots. — **done** (upstream `fabric-godot-core`)
2. One HTTP/3 message round-trips between an Elixir client and a standalone
   Godot-side process.
3. A server-side loop ticks on an interval and holds one piece of state
   (e.g. a player's position).
4. Client input updates that state; server pushes it back; client renders
   it. This is the first genuine "playing loop" — one entity moving in one
   empty room.
5. Everything else (combat combos, loot, hub/field structure, the full
   hexagon-core architecture) is layered on **after** step 4 is real,
   one proven increment at a time.

## Process/deployment model

`fabric-godot-core` runs as a **standalone OS process**, not an Elixir NIF
(a NIF can't safely host an indefinitely-running engine loop and would crash
the whole BEAM VM on an engine fault) and not an Erlang C-node (would
duplicate the wire protocol — real clients already need HTTP/3, so a second
protocol just for the Elixir↔Godot link is unnecessary structure per this
project's own YAGNI ADR). Process lifecycle (start/stop/restart-on-crash) is
owned by **systemd + systemd (Podman) quadlets**; Elixir's role is purely as
an HTTP/3 network peer — it connects, detects disconnection, and reconnects
with backoff, but does not spawn or own the Godot process.

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
- [FoundationDB `flow`](https://apple.github.io/foundationdb/flow.html)
  (Apache-2.0) — deterministic actor-based simulation model, relevant to
  this project's own deterministic-core design goals.

## License constraints

No GPL or AGPL (any version) dependencies or derived code. No Colobot.
All game content, assets, and design must be original work — genre
conventions may be studied from reference material above, but no data,
assets, or verbatim protocol/code may be copied from copyrighted or
copyleft sources.

## License

MIT — see `LICENSE`.
