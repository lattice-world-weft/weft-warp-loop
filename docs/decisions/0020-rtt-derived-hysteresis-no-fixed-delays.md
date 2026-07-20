# RTT-derived lookahead and hysteresis, never a fixed timing constant

## Status

Accepted; implemented (`Zone.lean`'s `hysteresisTicksFor`,
`ZoneDispatch.lean`'s `moveEntityToIndexHysteresisV`).

## Decision

Two fixed timing constants were proposed and rejected during
implementation: `interestLookahead := 6` and `hysteresisThreshold := 3`.
Both were corrected to be computed from each connection's real measured
RTT instead — explicit user correction: "these are calculated not
constants," "you must use math and not constant delays which are
wrong," "this is a systemic error." Adopted instead: each
`EntityRecord`'s ghost-expansion lookahead comes from its own
connection's RTT (`picoquic_get_rtt`, converted to ticks at the FFI
boundary), falling back to `defaultLookaheadTicks := 6` only when no RTT
sample exists yet — a legitimate floor for a not-yet-measured
connection, not a violation of the same rule. The hysteresis threshold
for authority transfer is derived from that same per-entity lookahead,
not a second independent constant: `hysteresisTicksFor lookaheadTicks :=
max 1 (lookaheadTicks / 2)`. `moveEntityToIndexHysteresisV` requires a
zone-boundary crossing to persist for that many ticks before authority
actually transfers, absorbing boundary jitter proportional to each
connection's own real latency rather than one guessed number for every
connection.

## Consequences

Good: slow connections get proportionally more hysteresis (matching
their larger prediction uncertainty) and fast connections transfer
authority sooner, both without hand-tuning; the rule generalizes — any
future timing threshold in this codebase should derive from measured
RTT the same way, not introduce a new fixed constant. Bad: behavior
depends on `picoquic_get_rtt`'s measurement quality; a connection with
no samples yet runs on the `defaultLookaheadTicks := 6` floor until its
first RTT sample lands, a real (currently unmeasured) startup-window
gap.
