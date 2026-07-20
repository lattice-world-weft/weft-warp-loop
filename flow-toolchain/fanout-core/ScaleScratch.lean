-- Empirical O(N+k) scaling check (not part of the build/test suite - a
-- growth-rate measurement, not a formal pointwise property, so it doesn't
-- belong in TestProps.lean's Plausible-based invariant checks). Run with:
--   lake env lean --run ScaleScratch.lean
--
-- Checks whether targetsForIndex's real cost grows linearly or
-- quadratically with population, now that AV1-style split/merge
-- (Partition.lean) bounds each zone's population and ghost-range
-- filtering (withinGhostRange) replaces blanket adjacent-zone visibility.
-- This is the concrete answer to the question "does the actual behavior
-- honestly reflect O(N+k)", not just the cost *model* used to decide
-- splits (Partition.lean's leafCost) - a cost model can be internally
-- consistent while the real per-publish target-list size still grows with
-- total population if nothing actually bounds it.
--
-- Measured result (n = 100..4000 uniformly-random entities placed one at
-- a time, split-checked after every placement, bits = 21):
--   n=100  zones=78   maxZonePop=3 totalTargets=376   avgTargetsPerPublish=3
--   n=500  zones=508  maxZonePop=5 totalTargets=1288  avgTargetsPerPublish=2
--   n=1000 zones=960  maxZonePop=4 totalTargets=3370  avgTargetsPerPublish=3
--   n=2000 zones=2008 maxZonePop=5 totalTargets=4914  avgTargetsPerPublish=2
--   n=4000 zones=4008 maxZonePop=5 totalTargets=10040 avgTargetsPerPublish=2
--
-- avgTargetsPerPublish stays flat (2-3) across a 40x population increase,
-- and zone count scales linearly with population (maxZonePop stays
-- bounded near-constant, as Partition.lean's cost model - leafCost(k) =
-- k^2 vs zoneOverhead = 1 - predicts: splitting becomes cost-favourable
-- at a very small population, so each zone's own population stays small
-- and roughly constant regardless of total N). Total fanout cost across
-- the whole world is therefore O(N * const) = O(N), not O(N^2) - the
-- real behavior already matches the O(N+k) goal (`k` here bounded by the
-- small, roughly-constant per-zone population, not the crowd size).
-- Porting the real prior art's HilbertBroadphase (radix sort + clz30
-- grouping + BucketDir) - a mechanism built for a different problem
-- (broadphase collision pairs over an unstructured entity set with no
-- existing spatial partition) - is not needed on top of this: this
-- system already has a spatial partition (zones), and cost-driven
-- split/merge already keeps each partition's own population, and hence
-- its own O(population^2) local cost, small and roughly constant as the
-- crowd grows.
import Fanoutcore.FanoutCore
import Fanoutcore.Zone
import Fanoutcore.Partition
import Fanoutcore.ZoneDispatch

open Fanoutcore

-- A small deterministic PRNG (xorshift64) - no external randomness source
-- needed, just spread-out pseudo-random curve indices for placement.
def xorshift64 (x : UInt64) : UInt64 :=
  let x := x ^^^ (x <<< 13)
  let x := x ^^^ (x >>> 7)
  let x := x ^^^ (x <<< 17)
  x

def bits : Nat := 21
def span : UInt64 := (1 : UInt64) <<< (3 * bits).toUInt64

def rebalance (w : ZoneWorld) (idx : UInt64) : ZoneWorld :=
  match w.authorityForIndex idx with
  | none => w
  | some zid => w.maybeSplitZone zid

def placeN (n : Nat) : ZoneWorld := Id.run do
  let mut w := ZoneWorld.empty (n + 8) bits
  match w.allocZone { start := 0, stop := span } with
  | none => return w
  | some (w', _) =>
    w := w'
    let mut seed : UInt64 := 88172645463325252
    for i in List.range n do
      seed := xorshift64 seed
      let idx := seed % span
      w := w.moveEntityToIndex i.toUInt64 idx
      w := rebalance w idx
    return w

/-- Total target-list size summed over every entity's own publish, plus the
    number of live zones and the largest live zone's population - the
    numbers that answer "is this growing linearly or quadratically with
    n". -/
def measureFanout (n : Nat) : (Nat × Nat × Nat) := Id.run do
  let w := placeN n
  let live := w.liveZones
  let zoneCount := live.size
  let maxPop := (live.map fun (_, z) => z.entities.size).foldl max 0
  let mut totalTargets := 0
  for (_, z) in live do
    for rec in z.entities do
      totalTargets := totalTargets + (w.targetsForIndex rec.connId rec.idx).size
  return (zoneCount, maxPop, totalTargets)

def main : IO Unit := do
  for n in ([100, 500, 1000, 2000, 4000] : List Nat) do
    let (zones, maxPop, totalTargets) := measureFanout n
    let avgTargets := totalTargets / n.max 1
    IO.println s!"n={n} zones={zones} maxZonePop={maxPop} totalTargets={totalTargets} avgTargetsPerPublish={avgTargets}"
