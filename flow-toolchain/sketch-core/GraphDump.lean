-- Replays a file of length-prefixed CSP1 packets through the core and
-- prints the canonical sketch-graph JSON. The convergence test runs this
-- over each client's received log and byte-compares the outputs.
--
-- Input format: repeated [len u32 LE][len bytes of CSP1 packet].
import SketchCore

open SketchCore

def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  b[off]!.toUInt32 ||| (b[off+1]!.toUInt32 <<< 8)
    ||| (b[off+2]!.toUInt32 <<< 16) ||| (b[off+3]!.toUInt32 <<< 24)

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let bytes ← IO.FS.readBinFile path
    let mut h := RoomHistory.empty
    let mut off := 0
    while off + 4 <= bytes.size do
      let len := (readU32LE bytes off).toNat
      if off + 4 + len > bytes.size then
        IO.eprintln s!"truncated frame at offset {off}"
        return 1
      let packet := bytes.extract (off + 4) (off + 4 + len)
      h := (h.apply packet).1
      off := off + 4 + len
    if off != bytes.size then
      IO.eprintln s!"trailing garbage at offset {off}"
      return 1
    IO.println h.graphJson
    return 0
  | _ =>
    IO.eprintln "usage: sketch_graph_dump <packets.bin>"
    return 2
