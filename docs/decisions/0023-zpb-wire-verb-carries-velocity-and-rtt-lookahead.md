# Extend the ZPB wire verb to carry velocity and RTT-derived lookahead

## Status

Accepted; implemented (`picoquic_fanout_server.actor.cpp`'s `ZPB`
handler, verified live up to 128 concurrent connections).

## Decision

Ghost-range interest ([ADR 0021](0021-ghost-range-interest-real-distance.md))
and RTT-derived hysteresis ([ADR 0020](0020-rtt-derived-hysteresis-no-fixed-delays.md))
both need real per-entity velocity and RTT on the simulation side, not
just position. Extended the wire verb from `ZPB x y z` to
`ZPB x y z vx vy vz` (velocity: micrometres/tick, magnitude per axis,
direction discarded, matching `EntityRecord`'s existing convention), and
added `rttToTicks(cnx)` converting `picoquic_get_rtt` to ticks at the
FFI boundary for every `fanout_entity_move_v` call. `kSimTickMicros :=
50000` is documented as a first assumption for tick-rate conversion, not
a value derived from any existing measured tick rate.

## Consequences

Good: velocity and RTT reach the simulation core on every publish,
closing the gap between what ADR 0020/0021 assume is available and what
the wire protocol actually carries; verified against a live server, not
just unit-tested. Bad: `fanout_load_client`'s own `ZPB` sends still
report zero velocity (a load-generation limitation, not a claim about
real player motion) — load-test traffic doesn't yet exercise the
velocity-dependent ghost-expansion path realistically.
