import SketchCore.Vec3

/-! CSP1 stroke packet codec.

Wire format (all integers little-endian), reproduced exactly from cassie's
`cassie_stroke_packet.h`:

```
[magic u32 = 'CSP1' (0x31505343)][peer_id u32][stroke_id u32][seq u16]
[sample_count u16][closed_flag u8][reserved u8]          -- 18-byte header
then sample_count x (pos.x f32, pos.y f32, pos.z f32, pressure f32)
```

`creation_time` is deliberately NOT on the wire - the receiver reconstructs
it as `sample_index * sample_dt`, so wall-clock drift between peers cannot
leak into the deterministic pipeline. Pressure is f32 (not f16) so a single
bit-flip is bit-exactly reproducible in determinism tests. -/

namespace SketchCore

def CSP1_MAGIC : UInt32 := 0x31505343
def CSP1_HEADER_BYTES : Nat := 18
def CSP1_SAMPLE_BYTES : Nat := 16

structure Sample where
  pos      : Vec3
  pressure : Float
  deriving Repr, Inhabited

instance : BEq Sample where
  beq a b := a.pos == b.pos && a.pressure == b.pressure

structure StrokePacket where
  peerId   : UInt32
  strokeId : UInt32
  seq      : UInt16
  closed   : Bool
  samples  : Array Sample
  deriving Repr, Inhabited

instance : BEq StrokePacket where
  beq a b := a.peerId == b.peerId && a.strokeId == b.strokeId && a.seq == b.seq
    && a.closed == b.closed && a.samples == b.samples

namespace Codec

def readU16LE (b : ByteArray) (off : Nat) : UInt16 :=
  b[off]!.toUInt16 ||| (b[off+1]!.toUInt16 <<< 8)

def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  b[off]!.toUInt32 ||| (b[off+1]!.toUInt32 <<< 8)
    ||| (b[off+2]!.toUInt32 <<< 16) ||| (b[off+3]!.toUInt32 <<< 24)

def readF32LE (b : ByteArray) (off : Nat) : Float :=
  (Float32.ofBits (readU32LE b off)).toFloat

def pushU16LE (b : ByteArray) (v : UInt16) : ByteArray :=
  (b.push v.toUInt8).push (v >>> 8).toUInt8

def pushU32LE (b : ByteArray) (v : UInt32) : ByteArray :=
  ((((b.push v.toUInt8).push (v >>> 8).toUInt8).push (v >>> 16).toUInt8).push (v >>> 24).toUInt8)

def pushF32LE (b : ByteArray) (v : Float) : ByteArray :=
  pushU32LE b v.toFloat32.toBits

end Codec

open Codec in
def StrokePacket.encode (p : StrokePacket) : ByteArray := Id.run do
  let mut b := ByteArray.empty
  b := pushU32LE b CSP1_MAGIC
  b := pushU32LE b p.peerId
  b := pushU32LE b p.strokeId
  b := pushU16LE b p.seq
  b := pushU16LE b p.samples.size.toUInt16
  b := b.push (if p.closed then 1 else 0)
  b := b.push 0 -- reserved
  for s in p.samples do
    b := pushF32LE b s.pos.x
    b := pushF32LE b s.pos.y
    b := pushF32LE b s.pos.z
    b := pushF32LE b s.pressure
  return b

open Codec in
/-- Strict decode: `none` on bad magic, short buffer, size mismatch, or a
    nonzero reserved byte. The core treats every inbound byte as untrusted. -/
def StrokePacket.decode (b : ByteArray) : Option StrokePacket := Id.run do
  if b.size < CSP1_HEADER_BYTES then
    return none
  if readU32LE b 0 != CSP1_MAGIC then
    return none
  let sampleCount := (readU16LE b 14).toNat
  if b.size != CSP1_HEADER_BYTES + sampleCount * CSP1_SAMPLE_BYTES then
    return none
  let closedByte := b[16]!
  if closedByte != 0 && closedByte != 1 then
    return none
  if b[17]! != 0 then
    return none
  let mut samples : Array Sample := Array.mkEmpty sampleCount
  for i in [0:sampleCount] do
    let off := CSP1_HEADER_BYTES + i * CSP1_SAMPLE_BYTES
    samples := samples.push
      { pos := ⟨readF32LE b off, readF32LE b (off+4), readF32LE b (off+8)⟩
        pressure := readF32LE b (off+12) }
  return some
    { peerId := readU32LE b 4
      strokeId := readU32LE b 8
      seq := readU16LE b 12
      closed := closedByte == 1
      samples := samples }

end SketchCore
