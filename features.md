## Determinism architecture: godot-sandbox vs. this repo's s7/shrubbery stack

Consolidated into ADRs (was prose here; see those for the full
analysis and history):
[0047](docs/decisions/0047-godot-sandbox-vs-bespoke-s7-stack-reviewed-superseded.md)
(native GDScript / GDExtension / Variant API / godot-sandbox aren't
interchangeable; godot-sandbox was recommended as the preferred
backend but that recommendation was superseded in practice — ADR 0028
and everything since built on this repo's own s7-in-libriscv stack
instead) and
[0048](docs/decisions/0048-dont-reimplement-gdscript-via-shrubbery-s7.md)
(shrubbery+s7 is not, and shouldn't try to become, a GDScript
implementation — adopt `godot-sandbox-gdscript-compiler` directly if
GDScript-in-sandbox is ever wanted).

## Game concept: Sigil Fabric (working title)

An end-to-end game that uses every subsystem already built, rather than
adding new pieces speculatively:

**Core loop**: players share a seamless open world (zone/world server,
already implemented). To cast a spell, a player draws a sigil with the
mouse/stylus. The stroke is captured and tessellated (`sketch-core`,
already implemented) into a deterministic polyline. Shape parameters
extracted from that polyline (loop count, corner count, aspect ratio,
stroke length — all deterministic functions of the raw tessellated
points, so no beautify solver is required for correctness, only for
prettier rendering) are passed into a per-spell-family s7 Lisp script
running in the libriscv sandbox (already implemented as a mechanism,
just needs content), which deterministically returns a spell effect
(damage bolt, heal, shield, summon). The effect becomes an entity in
the zone/world server, moving and fanning out to nearby players exactly
like a player entity does today (ZPB wire protocol, ghost-range
interest, zone-authority handoff — all already implemented), so combat
scales the same way player movement already does.

Why this combination and not a different one: it is the only game
concept that puts every non-infra subsystem in this repo on the game's
critical path instead of leaving one bolted on as a demo. The sandboxed
Lisp tier exists specifically so player-authored logic (the sigil ->
effect mapping) can run safely without trusting player input; the sketch
kernel's determinism requirement (ADR 0004) matters specifically because
a multiplayer spell result must be reproducible from the same stroke;
the zone/authority/interest work exists specifically to fan out combat
effects to only the players who'd actually see them.

**Gaps to reach a playable vertical slice** (2-8 players, one zone,
3 spell families: bolt / heal / shield):
- [ ] SIG wire verb carrying a captured stroke (or its extracted shape
  parameters) from client to server, alongside the existing ZPB verb
- [ ] Non-player entity kind in fanout-core for spell-effect entities
  (currently `EntityRecord` is implicitly player-shaped; needs either
  reuse as-is with a synthetic connId or an explicit entity-kind field)
- [ ] Three s7 Lisp spell scripts (bolt/heal/shield) mapping sigil shape
  parameters to effect + magnitude + duration — no scripted content
  exists yet, only the sandbox mechanism (ADR 0006)
- [ ] Godot client: stroke-capture input, sending SIG, and rendering
  both the player's own zone-server-driven movement and spell-effect
  entities — no client exists yet, this repo is server-only so far
- [ ] Deterministic shape-parameter extraction from `sketch-core`'s
  tessellated output (skip cassie's beautify solver for the vertical
  slice; ADR 0003's bit-identical-beautify requirement only matters once
  visual polish, not gameplay correctness, depends on it)
- [ ] Basic damage/health resolution in fanout-core or a new adjacent
  Lean module, since nothing currently models HP or spell resolution

- [ ] s7 as a typed GDScript compiler on libriscv, via shrubbery — reviewed
  and rejected, see [ADR 0048](docs/decisions/0048-dont-reimplement-gdscript-via-shrubbery-s7.md)
- [ ] using the flow actor model
- [ ] 1000 players and linear fanout scaling zones
- [ ] Elixir/OTP hub peer (HTTP/3 client that connects/reconnects to zone servers) — no Elixir code exists yet
- [ ] Process supervision via systemd/Podman quadlets
- [ ] Wire-level zone provisioning (currently FFI-only, no wire verb)
- [ ] Reserved witness zones for cross-machine zone-authority leases (ADR 0009, design-only)
- [ ] s7/shrubbery toolchain scope: actor-compiler, Boost.Asio, taskweft, Elixir NIF comparison (ADR 0007, design-only)

## Game features

- [x] Real-time multiplayer position + velocity sync (SUB/PUB over QUIC, ZPB wire verb)
- [x] Seamless open world via zone-to-zone authority handoff (hysteresis-gated, no visible teleport/loading-zone seam)
- [x] Interest management: players only receive updates for entities within a kinematically-expanded visibility range, not the whole zone
- [x] Client-side rendering only (Godot) — all authoritative game logic runs server-side in fanout-core
- [x] Sketch/stroke-based drawing subsystem (`sketch-core`): polyline tessellation + intersection graph, reproducing cassie's stroke pipeline minus the beautify solver (raw Schneider-fit strokes for now, rougher but functional)
- [x] Sandboxed Lisp (s7-on-libriscv) scripting tier for simulation content, intended for mission scripts / loot tables / NPC behavior (ADR 0006), reaffirmed as the primary interpreted path over AOT-compilation (ADR 0028)
- [x] Shrubbery-notation surface reader over s7's s-expressions (ADR 0033), ported to s7 itself and verified byte-for-byte against the Python version (ADR 0037); rejects raw Lisp-shaped top-level statements by construction (ADR 0044)
- [x] `define-record`/`record-with` macros for immutable-update boilerplate (ADR 0034)
- [x] Real scripted content authored on the s7 sandbox: loot tables, combat, progression (ADR 0030/0031)
- [x] `taskweft`'s full HTN-planner/ReBAC/temporal-reasoning/HRR core ported to shrubbery and verified layer-by-layer against real domains and the Lean source's own proven values, through full integration (ADR 0035-0046)
- [ ] Cassie-style stroke "beautify" (dense PCG constraint solver, bit-identical across peers) — vendoring planned, not yet implemented (ADR 0003)
- [ ] Integration/reference against Artifacts MMO's live game API (`artifacts_mmo_h3_client`) — HTTP/3 client exists, no gameplay wired to it yet

- [x] Flow-based C++ zone/world server (`picoquic_fanout_server`), terminating QUIC/HTTP-3/WebTransport itself via a vendored picoquic+picotls+mbedtls stack, no sidecar
- [x] Lean4 `fanout-core` kernel: Hilbert-curve zone authority/interest dispatch, compiled via `@[export]` FFI into a linkable static library the C++ actor calls synchronously
- [x] Property-based verification of fanout-core with Plausible (33/33 tests passing)
- [x] Ghost-range interest expansion: k-tick kinematic expansion (`v*k + aHalf*k²`) filtering adjacent-zone visibility by real per-axis distance, not blanket zone membership
- [x] RTT-derived lookahead window per entity (falls back to a fixed default only when no RTT sample exists yet)
- [x] Hysteresis-gated zone-authority transfer, with the hysteresis threshold itself computed from RTT-derived lookahead (no fixed timing constants)
- [x] AV1-style cost-driven zone split/merge (population² cost model, `maybeSplitZone`/`maybeMergeSiblings`)
- [x] Capacity-separated authority/interest budgets (`authorityCapacity`, `interestCapacity`) as hard resource ceilings independent of cost-driven splitting
- [x] ZPB wire protocol carrying position, velocity, and RTT-derived lookahead ticks
- [x] Empirically validated O(N+k) fanout scaling (flat avg targets/publish from population 100 to 4000, `ScaleScratch.lean`)
- [x] `fanout_load_client`: Flow-actor QUIC load-testing tool for the zone server
- [x] `sketch-core`: Lean4 sketch/constraint-solver kernel, polyline-tessellation-based curve intersection (ADR 0004)
- [x] s7 Lisp sandboxed in libriscv as a scripted-content runtime (ADR 0006; `s7_riscv_actor`, `riscv-guests/`)
- [x] ArtifactsMMO HTTP/3 client (`artifacts_mmo_h3_client`)
- [x] Vendored FoundationDB `flow/` actor runtime + actor-compiler toolchain
- [x] Architecture decision records (MADR) for major design choices (`docs/decisions/`)
