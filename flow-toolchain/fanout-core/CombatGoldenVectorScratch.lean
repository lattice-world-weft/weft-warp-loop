-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
--
-- Reference-value computation for the combat.scm port, using the EXACT
-- definitions fetched from v-sekai-multiplayer-fabric/combat's
-- core/CombatCore/Core.lean, copied here verbatim. Not part of the
-- build/test suite - run via `lake env lean --run CombatGoldenVectorScratch.lean`.

namespace CombatCore

def comboMinGap : UInt32 := 6
def comboMaxGap : UInt32 := 18
def invulnTicks : UInt32 := 30
def enemyMaxHp  : UInt32 := 100

def damageOf : UInt32 → UInt32
  | 0 => 10
  | 1 => 15
  | _ => 25

structure State where
  tick       : UInt32 := 0
  comboStage : UInt32 := 0
  lastAttack : UInt32 := 0
  enemyHp    : UInt32 := 0
  enemySpawn : UInt32 := 0
  enemyAlive : Bool   := false
  deriving DecidableEq, Repr, Inhabited

inductive Event
  | tick
  | attack
  | spawn
  deriving DecidableEq, Repr

inductive Effect
  | swing (stage : UInt32)
  | hit (damage : UInt32)
  | blocked
  | whiff
  | comboDrop
  | death
  deriving DecidableEq, Repr

def resolveSwing (s : State) (stage : UInt32) : State × List Effect :=
  if !s.enemyAlive then (s, [.swing stage])
  else if s.tick < s.enemySpawn + invulnTicks then (s, [.swing stage, .blocked])
  else
    let dmg := damageOf stage
    if s.enemyHp ≤ dmg then
      ({ s with enemyHp := 0, enemyAlive := false }, [.swing stage, .hit dmg, .death])
    else
      ({ s with enemyHp := s.enemyHp - dmg }, [.swing stage, .hit dmg])

def step (s : State) : Event → State × List Effect
  | .tick =>
    let s := { s with tick := s.tick + 1 }
    if s.comboStage > 0 && s.tick > s.lastAttack + comboMaxGap then
      ({ s with comboStage := 0 }, [.comboDrop])
    else (s, [])
  | .spawn =>
    ({ s with enemyAlive := true, enemyHp := enemyMaxHp, enemySpawn := s.tick }, [])
  | .attack =>
    if s.comboStage == 0 then
      let (s', fx) := resolveSwing { s with comboStage := 1, lastAttack := s.tick } 0
      (s', fx)
    else
      let gap := s.tick - s.lastAttack
      if comboMinGap ≤ gap && gap ≤ comboMaxGap then
        let stage := s.comboStage
        let next := if stage ≥ 2 then 0 else stage + 1
        let (s', fx) := resolveSwing { s with comboStage := next, lastAttack := s.tick } stage
        (s', fx)
      else
        ({ s with comboStage := 0 }, [.whiff])

def replay (events : List Event) : State × List Effect :=
  events.foldl (fun (acc : State × List Effect) e =>
    let (s, fx) := step acc.1 e
    (s, acc.2 ++ fx)) ({}, [])

end CombatCore

open CombatCore

-- spawn, then 30 ticks (clears the invuln window), then one opener attack.
def goldenEvents : List Event :=
  .spawn :: (List.replicate 30 Event.tick) ++ [.attack]

#eval s!"final enemyHp = {(replay goldenEvents).1.enemyHp}"
#eval s!"final tick = {(replay goldenEvents).1.tick}"

-- Measured (2026-07-20): spawn, then 30 ticks, then one opener attack ->
-- final enemyHp = 90 (tick=30 lands exactly at the invuln boundary,
-- s.tick < s.enemySpawn + invulnTicks is 30 < 30 = false, so the swing
-- connects: damageOf(stage=0)=10, 100-10=90), final tick = 30. This is
-- the reference flow-toolchain/examples/s7_riscv_combat_golden_test.cpp
-- checks the ported combat.scm against.
def main : IO Unit := pure ()
