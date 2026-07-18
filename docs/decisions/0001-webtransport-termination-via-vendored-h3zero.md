# Terminate WebTransport with the vendored h3zero/picowt stack

## Status

Accepted (planned as PR 2 of the cassie reproduction; not yet implemented).

## Context and Problem Statement

The sketch relay currently speaks raw QUIC with a custom ALPN
(`fanout-demo`), which browsers cannot open. Browsers and the Godot fork's
`modules/http3` `WebTransportPeer` both speak WebTransport (HTTP/3). How do
we let those clients join a sketch room?

## Decision Drivers

- Browser demo is the audience-facing goal; raw QUIC excludes it.
- The Godot engine fork already ships a picoquic-backed `WebTransportPeer`
  (native) that falls back to browser-native WebTransport in web exports.
- `flow-toolchain/thirdparty/picoquic/picohttp/` already vendors AND
  compiles the full h3zero HTTP/3 stack plus the `picowt_*` API; the
  reference callback `wt_baton.c` and the recipe doc
  `doc/pico_webtransport.md` are in-tree.
- Repo rule: no exceptions in Flow actor code; keep the Lean core the
  single owner of sketch semantics.

## Considered Options

1. Wire up the vendored h3zero/picowt server (new Flow actor).
2. Vendor a separate WebTransport library (e.g. webtransportd, quiche).
3. Keep raw QUIC only and require native clients.

## Decision Outcome

Chosen option 1. The code is already vendored, compiled, and documented
in-tree; the 3-step recipe in `doc/pico_webtransport.md` is
`picoquic_set_callback(h3zero_callback)` +
`picowt_set_default_transport_parameters` + a
`picohttp_server_path_item_t` path-table entry (`/sketch`) whose callback
is modeled on `wt_baton_callback()`. WT streams carry the same
length-prefixed CSP1 frames into the same sketch-core history, so the
convergence contract is unchanged. Optionally multiplex raw QUIC and WT on
one port via `picoquic_demo_server_callback_select_alpn`.

### Consequences

- Good: zero new third-party code; one deterministic Lean core serves
  raw-QUIC and WT clients identically.
- Good: aioquic speaks H3/WebTransport, so the existing convergence test
  ports directly.
- Bad: h3zero's callback surface is larger than the raw fanout loop;
  the actor must map its stream lifecycle onto Flow without exceptions.
- Follow-up: certificate strategy is a separate decision
  ([0002](0002-certs-servercertificatehashes-ecdsa-p256.md)).
