-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- Checkpoint 3 of the "real content through the interpreted s7 path"
-- plan: computes the Lean4 reference value for a concrete golden
-- vector, using the EXACT definitions fetched from
-- v-sekai-multiplayer-fabric/loot's core/LootCore/{Rng,Loot}.lean
-- (copied here verbatim rather than added as a lake dependency, since
-- this is a one-shot reference computation, not an ongoing dependency).
-- Not part of the build/test suite - run via
-- `lake env lean --run LootGoldenVectorScratch.lean`.

def next32 (s : UInt32) : UInt32 :=
  let s := s ^^^ (s <<< 13)
  let s := s ^^^ (s >>> 17)
  let s := s ^^^ (s <<< 5)
  s

def range (seed : UInt32) (bound : Nat) : Nat :=
  if bound == 0 then 0 else (next32 seed).toNat % bound

abbrev Item := Nat
abbrev Weight := Nat
abbrev LootTable := List (Item × Weight)

def totalWeight (t : LootTable) : Nat := t.foldl (fun acc e => acc + e.2) 0

def pick : LootTable → Nat → Nat → Item
  | [], _, _ => 0
  | (item, w) :: rest, r, acc => if r < acc + w then item else pick rest r (acc + w)

def roll (seed : UInt32) (t : LootTable) : Item :=
  let tot := totalWeight t
  if tot == 0 then 0 else pick t (range seed tot) 0

def goldenTable : LootTable := [(1, 10), (2, 20), (3, 5)]
def goldenSeed : UInt32 := 42

#eval s!"next32(42) = {next32 goldenSeed}"
#eval s!"totalWeight = {totalWeight goldenTable}"
#eval s!"range(42, 35) = {range goldenSeed (totalWeight goldenTable)}"
#eval s!"roll(42, table) = {roll goldenSeed goldenTable}"

-- Measured (2026-07-20): next32(42) = 11355432, totalWeight = 35,
-- range(42, 35) = 32, roll(42, table) = 3. This is the reference value
-- flow-toolchain/examples/s7_riscv_loot_golden_test.cpp checks the
-- ported s7 Scheme against.
def main : IO Unit := pure ()
