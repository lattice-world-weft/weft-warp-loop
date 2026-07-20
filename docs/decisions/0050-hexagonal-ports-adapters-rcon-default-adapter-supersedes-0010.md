# Adopt hexagonal core/ports/adapters; Godot demoted to one adapter among several; RCON-compatible terminal is the default adapter

## Status

Accepted. Supersedes
[ADR 0010](0010-godot-thin-client-interest-bounded-over-in-place-patches.md)'s
premise that Godot is "the" client — Godot stays a valid adapter, just
no longer a privileged or required one.

## Decision

Corrected via user feedback: this repo already has a hexagon-shaped
core (`fanout-core`, Lean4, FFI'd into the Flow/C++ zone server, a pure
reducer over byte-serialized state — the same "bytes to bytes" shape
`v-sekai-multiplayer-fabric`'s own
`20260611-lean4-kernel-cores-flat-c-host-adapters.md` ADR describes
for its parallel stack) and an already-narrow binary contract (the ZPB
wire protocol) that functions as its port, without this repo ever
naming the pattern. ADR 0010 nonetheless treated Godot as *the* client
— a privileged, singular choice, "Plan A/Plan B" both assuming Godot
specifically — which the hexagonal ports-and-adapters pattern (Alistair
Cockburn's, applied org-wide by `v-sekai-multiplayer-fabric` per
`20260610-hexagonal-core-ports-adapters.md`: "A port is a narrow
interface the core defines and an adapter implements... One port
admits many adapters, so a single core output fans out to several
destinations from one pass, and a recorded-fixture adapter stands in
for live hardware under CI") rules out. Godot is one possible adapter,
not the port itself, and the port shouldn't be designed around any one
adapter's needs.

Checked `v-sekai-multiplayer-fabric/fabric-flow-adapters` directly
before writing this, since it was cited as the reference — it turned
out to be the wrong artifact to cite (a Godot/Unity/CLI USD-import
plugin, unrelated to game networking or `weft-warp-loop`), but the
org-wide ADRs it points to (`hexagonal-core-ports-adapters`,
`hexagon-combat-core`, `lean4-kernel-cores-flat-c-host-adapters`) are
real, concrete precedent worth citing directly: `hexagon-combat-core`
names its own adapters as "an HTTP3 module feeds `input_source`, the
`zone-server` hosts the core and drives `tick_source`, a fixture
adapter replays recorded inputs for CI" — the exact "one core, several
non-privileged adapters including a CI-fixture one" shape this ADR
adopts.

**Reframed under this pattern**:
- **Core**: `fanout-core` (unchanged) — the zone/authority/interest
  Lean4 kernel, compiled and FFI'd into the Flow/C++ zone server.
- **Port**: the ZPB wire protocol (unchanged) — already the narrow,
  binary, engine-neutral contract between the core and any client;
  this repo arrived at the right shape independently, without naming
  it.
- **`fanout_load_client`** (already built, already committed) is,
  retroactively, this repo's own fixture adapter — it drives scripted,
  fixed-tick synthetic connections against the real ZPB port for load
  testing, matching `hexagon-combat-core`'s named fixture-adapter role
  exactly, just never labeled that way before.
- **Godot** (ADR 0010): demoted from required to optional — one
  possible rendering adapter, built later if and when a real graphical
  client is wanted, never blocking on the vertical slice below.
- **New: the default adapter** — a headless, RCON-protocol-compatible
  terminal client. Not a fixture (it drives real interactive input,
  not scripted replay) and not a rendering client (no graphics at
  all) — closer to Source engine's RCON console: a small TCP server
  speaking the real RCON wire protocol (length-prefixed packets,
  request id, `SERVERDATA_AUTH`/`EXECCOMMAND`/`RESPONSE_VALUE` types),
  that internally acts as a ZPB client to the real zone server
  (reusing `fanout_load_client`'s proven QUIC/ZPB connection code, not
  rebuilding it). Its purpose is explicitly diagnostic-first ("show
  our tick rate at full fidelity," full entity/RTT/authority-handoff
  visibility as text) with real play as a secondary, genuinely-
  supported capability (movement/action commands over the same RCON
  `EXECCOMMAND` channel) — a tool that happens to be playable, not a
  game client that happens to have a debug console.

  **The terminal UI itself is hand-built, not adopted off the shelf**
  — an initial "use an existing RCON client so this repo writes zero
  terminal-UI code" direction was tried and reversed. Two real
  candidates were checked directly (not assumed): `radj307/ARRCON`
  (GPL-3.0, genuine Source RCON protocol compliance, cross-platform,
  interactive shell mode — no release since April 2023, and its
  license alone would rule it out for anything beyond an external
  demo tool: this repo is MIT-licensed throughout, GPL-3.0 code can't
  be vendored or linked into it) and `OpenRcon/OpenRcon` (GPL-3.0,
  C++, cross-platform — **archived** as of April 2026, repository now
  read-only, same license incompatibility). Neither is a foundation
  worth building a demo on, or one this repo could legally absorb
  even if it were. Given the terminal needed building anyway, built
  with **Textual** (Python's TUI framework, MIT-licensed — verified,
  not assumed, since the license constraint is exactly why the two
  GPL-3.0 candidates above were rejected) — the same stack (confirmed
  via the repo's own topics: `textual`, `tui`) behind the user's own
  well-received prior work, `fire/jobs-lazy-onboarding` ("offline
  terminal app... using an on-device ONNX model over a normalized
  SQLite database"), reused here for its proven visual/UX quality
  rather than reinvented from a blank terminal.

## Consequences

Good: the vertical slice ("Sigil Fabric," `features.md`) no longer
depends on a from-scratch Godot project — by far the largest, least-
calibrated item in this repo's own critical-path estimate for that
milestone — since the default adapter reuses already-proven connection
code and a well-specified, compact external protocol (RCON) instead of
building a rendering pipeline from nothing. `fanout_load_client`
gaining a retroactive architectural label costs nothing and clarifies
its role going forward. Bad: RCON's real protocol (auth handshake,
packet framing, multi-packet response handling) is new code this repo
hasn't built before, even if smaller in scope than a Godot client;
`fabric-flow-adapters` itself turned out not to be reusable code or
even directly-reusable design (different org, different core, no
integration point) — everything here is precedent to reason from, not
something to vendor or link against. Godot, if built later, still
needs its own real design work (ADR 0010's Plan A/B reasoning about
`ObjectDB`/renderer costs stays valid and unclaimed by this decision).
