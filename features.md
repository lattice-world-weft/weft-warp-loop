## Determinism architecture: GDScript authoring on the godot-sandbox VM, taskweft as a compiled front-end

The four things named are not interchangeable, and conflating them is the
actual risk:

- **Native GDScript** (Godot's built-in `.gd` interpreter, shipped in
  every Godot binary) — dynamically typed, runs as trusted engine code,
  full Node/signal/engine access. No documented bit-identical-replay
  contract across hosts (host-native double float, hash-order-sensitive
  `Dictionary`, no fuel/instruction accounting). Fine for client-only
  rendering/UI, wrong for anything that must replay identically across
  peers.
- **Godot C++ modules / GDExtension** — fully native, compiled directly
  against the engine, zero sandbox. Same trust tier as native GDScript,
  just faster and unsafe in a different way (memory safety, not
  determinism). Also wrong for the replicated-simulation path.
- **The Variant API** — Godot's tagged-union value type (`int`, `float`,
  `String`, `Vector2`, `Array`, `Dictionary`, `Object`, …). This is not an
  execution model at all — it's the *data contract* every one of the
  other three marshals values through when crossing an engine/script/
  extension boundary. Determinism claims have to be scoped against this
  boundary specifically, since it's where host and guest actually
  exchange values.
- **godot-sandbox** (https://github.com/libriscv/godot-sandbox) —
  Godot's own upstream project embedding libriscv for sandboxed
  scripting, with C++/Rust/Zig backends and, per the linked repo, now a
  from-scratch GDScript-to-RISC-V compiler too. This is the same
  substrate this repo already vendors and has independently proven
  deterministic (`libriscv_vendor_test.cpp`: fuel metering bounds
  execution, repeated runs produce byte-identical instruction counts) —
  but it is Godot's own sanctioned sandbox, with its own Variant-ABI
  extern-call convention, not this repo's bespoke one.

**Preferred backend**: godot-sandbox's libriscv/Variant-ABI substrate
over this repo's own s7/shrubbery stack (ADR 0006), because it's the
Godot-blessed mechanism other backends (C++/Rust/Zig, and the linked
GDScript compiler) already target — maximizing interop with real engine
content (Nodes, scenes, exported properties) while keeping libriscv's
proven determinism. This doesn't touch `fanout-core`/`sketch-core`'s
Lean4 kernels; it's scoped to the scripted-content tier only.

**Caveat on the GDScript front-end specifically**: adopting
`godot-sandbox-gdscript-compiler` gets *a* GDScript-syntax language
executing deterministically in RISC-V — it is a separate reimplementation
of the language, not the same runtime as Godot's built-in `.gd`
interpreter. Semantic parity (coroutines/`await`, signal auto-connection,
duck-typed dynamic dispatch, the full class/inheritance model) is not
guaranteed just because the syntax matches; it needs verifying against
godot-sandbox's actual Variant-ABI/extern surface before scripts are
assumed portable between "runs in the editor" and "runs in the sandbox."

**taskweft's role — reuse `udonweft`'s shape, don't invent a new one**:
`taskweft/udonweft` already proves this exact pattern is buildable: a
Lean4-verified small-step VM (9 opcodes, proven `step`/`run` semantics —
`step_halted`, `run_mono`, etc.) plus a full extern-symbol taxonomy
(31,914 `VRC.Udon.Wrapper.dll` signatures), with taskweft's RECTGTN plan
output lowering into it. `taskweft/godotweft` is the Godot-side half of
the same precursor — it already carries the `extension_api-4-7-*.json`
GDExtension API dumps, exactly analogous to udonweft's `KnownExterns`
taxonomy, but has no VM formalization or lowering compiler yet. The
concrete, scoped next step is the missing half: a "godotweft-compiler"
that is to `godot-sandbox` what `udonweft` is to Udon — a Lean4-verified
opcode/step/run model (or a direct proof over godot-sandbox's actual
RISC-V/Variant-ABI boundary, skipping a bespoke opcode set if that's the
smaller increment) plus a taskweft-JSON-LD-to-RISC-V lowering. This is
genuinely new work, the same size class as `udonweft` itself — not a
small follow-up.

**Resulting division of labor**:
- Programmer-authored deterministic gameplay logic (combat math,
  movement, item effects): GDScript syntax via
  `godot-sandbox-gdscript-compiler`, targeting godot-sandbox directly —
  no Lisp in this path.
- Planner-driven AI/quest/NPC goal logic: taskweft's RECTGTN
  (`plan`/`replan`, JSON-LD domains — already in production use in this
  very repo as `plan/bootstrap-domain.json`), lowered into godot-sandbox's
  RISC-V/Variant ABI the way `udonweft` already does for Udon Assembly.
- This repo's own s7-in-libriscv tier (ADR 0006) either narrows to
  content godot-sandbox's backends don't cover well, or is retired in
  favor of standardizing on godot-sandbox outright — worth a follow-up
  ADR once the godotweft-compiler direction is scoped further, rather
  than deciding it here.

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

- [ ] s7, a Scheme interpreter as a typed gdscript compiler on libriscv https://github.com/v-sekai-multiplayer-fabric/godot-sandbox-gdscript-compiler see shrubbery
  - Reviewed: **no** — not as stated. `godot-sandbox-gdscript-compiler` is
    a from-scratch native compiler (its own lexer/parser/AST/IR/optimizer/
    register allocator/RISC-V codegen/ELF builder in `src/`) that compiles
    real GDScript source directly to RISC-V machine code for Godot
    Sandbox. Shrubbery (per ADR 0006/0007) is only an indentation-based
    *reader* layer in front of s7's s-expressions — it changes how text is
    grouped into syntax trees, not what semantics run underneath, and its
    own docs describe it as deliberately "leaving further parsing to
    another layer." It has no notion of GDScript's actual grammar
    (`func`/`var`/`class_name`/`extends`/`@export`/type hints), and real
    `.gd` source is not shrubbery notation — a shrubbery reader in front
    of s7 cannot parse existing GDScript files as-is.
  - What would actually be needed to call it "GDScript": not just a
    reader, but GDScript's semantics rebuilt on top of s7 — a Variant
    type system, class/inheritance dispatch, the Node-tree/signal model,
    typed properties — none of which s7 or shrubbery provide, and all of
    which the referenced compiler already implements natively and
    directly targets RISC-V/Godot Sandbox for.
  - Recommendation: don't reimplement GDScript via shrubbery+s7. If
    GDScript-in-sandbox is actually wanted, adopt/vendor
    `godot-sandbox-gdscript-compiler` directly — it already solves this
    exact problem, end to end, and duplicating it in s7 would be strictly
    more work for a worse-fitting result. Keep shrubbery scoped to what
    ADR 0006 actually chose it for: a friendlier surface syntax over s7's
    own s-expressions for this repo's fuel-bounded simulation-scripting
    tier (mission scripts, loot tables, NPC behavior, e.g. this doc's
    Sigil Fabric spell scripts) — a different, narrower, determinism-
    driven problem than general GDScript compatibility.
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
- [x] Sandboxed Lisp (s7-on-libriscv) scripting tier for simulation content, intended for mission scripts / loot tables / NPC behavior (ADR 0006)
- [ ] Cassie-style stroke "beautify" (dense PCG constraint solver, bit-identical across peers) — vendoring planned, not yet implemented (ADR 0003)
- [ ] Concrete scripted-content call shapes (mission scripts, loot tables, NPC behavior) on top of the s7 sandbox — mechanism exists, no content authored yet
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
