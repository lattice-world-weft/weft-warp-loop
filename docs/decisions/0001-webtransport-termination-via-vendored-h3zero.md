# Terminate WebTransport with the vendored h3zero/picowt stack

## Status

Accepted (planned as PR 2 of the cassie reproduction; not yet implemented).

## Decision

Browsers and the Godot fork's `WebTransportPeer` speak WebTransport
(HTTP/3), not raw QUIC — the sketch relay's current custom ALPN
(`fanout-demo`) excludes both. `flow-toolchain/thirdparty/picoquic/picohttp/`
already vendors and compiles the full h3zero stack plus the `picowt_*`
API, with a reference callback (`wt_baton.c`) and recipe
(`doc/pico_webtransport.md`) in-tree, so wire it up as a new Flow actor
rather than vendoring a second WebTransport library or staying
raw-QUIC-only: `picoquic_set_callback(h3zero_callback)` +
`picowt_set_default_transport_parameters` + a `picohttp_server_path_item_t`
path-table entry (`/sketch`) modeled on `wt_baton_callback()`. WT streams
carry the same length-prefixed CSP1 frames into the same sketch-core
history, so the convergence contract is unchanged; raw QUIC and WT can
multiplex on one port via `picoquic_demo_server_callback_select_alpn`.

## Consequences

Good: zero new third-party code; one deterministic Lean core serves
raw-QUIC and WT clients identically; aioquic already speaks
H3/WebTransport, so the existing convergence test ports directly. Bad:
h3zero's callback surface is larger than the raw fanout loop — the actor
must map its stream lifecycle onto Flow without exceptions. Follow-up:
certificate strategy is [ADR 0002](0002-certs-servercertificatehashes-ecdsa-p256.md).
