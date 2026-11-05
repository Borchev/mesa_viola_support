# Viola ML instructions

Viola (PCI device ID 13DA/13DC, see [README.md](README.md)) adds an instruction class that GFX1013
doesn't have. There is no public documentation for it; this description is unofficial and may be
incomplete. The instructions work in any wave32 compute shader; no special mode is needed.

## Encoding

Two dwords, plus a 32-bit literal when L = 1:

```
dword0  [31:26] 111001  [25:19] op  [18] L  [17] h  [16] 0  [15:8] SSRC  [7:0] VDST
dword1  [7:0] S0  [15:8] S1  [23:16] C  [31:24] D1
```

- VDST (D0) and D1 are the destination VGPRs, S0 and S1 the source VGPRs, C the accumulator or
  addend VGPR. Ops that use two accumulators read C and C+1.
- SSRC is an SGPR base n. The int8 ops read their weights from s[n], s[n+1] and s[n+2]. With a
  literal and no scalar operand, SSRC is 0x7d.
- Each VGPR holds four int8 values (bytes 0-3) or two fp16 values (low and high halves).

## Arithmetic

The int8 ops work in fixed point with 14 fractional bits:

1. The fp16 accumulator, bias or addend is truncated toward zero to a multiple of 2^-14.
2. The int8 products are added to it exactly.
3. The sum `acc` is converted once:
   - to fp16: `acc * 2^-14` rounded toward zero. Results beyond ±65504 give ±65504, not infinity.
   - to int8: `clamp(floor(acc / 2^(14 - shift)), lo, 127)`, with lo = 0 when ReLU is set and -128
     otherwise. A shift above 13 acts as 13.

An infinite or NaN accumulator gives the same infinity or NaN. Long sums lose a little toward zero.

The fp16 ops 0x40, 0x41 and 0x42 are fused multiply-adds rounded to nearest even.

## int8 matrix-vector ops (used by the patch)

dot4(x, w) is the sum of the four signed int8 products of two dwords.

| op | Operation |
|---|---|
| 0x23 | D0.lo = C.lo + (dot4(S0, s[n]) + dot4(S1, s[n+1])) * 2^-14<br>D1.lo = (C+1).lo + (dot4(S0, s[n+2]) + dot4(S1, literal)) * 2^-14<br>The high halves are copied from the accumulators. |
| 0x24 | The same into the high fp16 halves; the low halves are copied. |

Each op does 16 int8 multiply-adds per lane: a 2x8 weight matrix from scalar registers (plus the
literal) times an 8-element int8 vector per lane, accumulated as described under Arithmetic. In the
8-byte form (L = 0) the literal weight is 0, so D1 only gets the S0 product. The patch uses the ops
with D0 and D1 as a tied accumulator pair and reads the weights directly from where they were loaded.

## Quantize op (used by the patch)

| op | Operation |
|---|---|
| 0x28 | D0 byte k = clamp(floor(x_k * 2^shift), lo, 127) for x = S0.lo, S0.hi, S1.lo, S1.hi.<br>Literal byte 1: bits 3:0 = shift, bit 4 = ReLU (lo = 0 instead of -128). NaN gives 0, -inf gives -128 even with ReLU. Only D0 is written. |

## Other ops (not used by the patch)

| op | Operation |
|---|---|
| 0x22 | D0.lo = bias + dot4(S0, s[n]) + dot4(S1, s[n+1]), D0.hi = bias + dot4(C, s[n]) + dot4(C+1, s[n+1]), each times 2^-14. bias = fp16 in literal bits 31:16. Only D0 is written. |
| 0x20 / 0x21 | int8 matrix-vector with int8 output, quantized like the convolution ops below. |
| 0x04-0x0b, 0x0c-0x0e, 0x10, 0x11, 0x14-0x16, 0x00, 0x01 | int8 3x3 convolution. Rows y-1, y, y+1 come from S0, S1 and C, four horizontally adjacent pixels per lane, with neighbors taken from the adjacent lanes. At the ends of the wave, lane 0 repeats its own byte 0 and lane 31 its own byte 3. Weights w0-w8: s[n], s[n+1], literal byte 0. Literal byte 1 = ReLU and shift, bits 31:16 = fp16 bias. Output: v = sum * 2^-14 + bias, written as int8 or fp16 for pixels 0-1 or 2-3 (0x0d and 0x15: stride 2). 0x10, 0x11, 0x14, 0x15 and 0x16 add the fp16 pair in the D1 register instead of the bias. |
| 0x29 / 0x2a | Quantize two fp16 pairs into int8 pairs in the low / high 16 bits. |
| 0x2c | Quantize as 0x28, then add byte-wise to C. |
| 0x2d | int8 dequantize-add: D = S + int8(C byte) * 2^-shift. |
| 0x2e / 0x2f | Per-byte signed int8 max / min of S and C. |
| 0x30 / 0x31 | fp16 max / min of S and C. |
| 0x32 | Move: D0 = S0, D1 = S1. |
| 0x33 | Select: D = VCC ? C : S. |
| 0x34 / 0x35, 0x36 / 0x37 | Move one int8 / fp16 value between lane 0 and lane 31 (edge exchange for convolutions). |
| 0x40 | D0 = S0 * K.lo + literal, D1 = S1 * K.hi + literal (packed fp16, K = SGPR). |
| 0x41 | D0 = S0 * C0 + K.lo, D1 = S1 * C1 + K.hi. |
| 0x42 | D0 = S0 * K.lo + C0, D1 = S1 * K.hi + C1 (K = SGPR or literal): 4 fp16 FMAs per lane. |
| 0x43 | 0x42 followed by ReLU. |
| 0x44 / 0x45 | 0x42 with S shifted by one fp16 element across lanes (3-tap row filter). |

## Other new instructions

These are outside the class above. The ops above don't need any of them.

- DS 0xb4 / 0xb5: store / load one dword per lane, like `ds_write_addtid_b32` /
  `ds_read_addtid_b32`, at LDS address `m0[31:23] * 128 + offset + lane * 4`. The standard addtid
  instructions take their base from m0[15:0], so one m0 value can hold both bases. They need
  allocated LDS.
- SMEM 0x2b: prefetches code at s[base] + offset. It writes no register.
- SOPP 0x2a / 0x2b: no operand, used in pairs around blocks of these instructions: 0x2a before the
  block, 0x2b after it. They don't change results or give a wave exclusive use of the SIMD. In short
  loops with several waves per SIMD, a block between them ran about 15% faster. A 0x2b with no 0x2a
  before it, followed by an op of this class, hung the GPU, and the GPU reset didn't recover.
- Hardware register 26: bits 1:0 are writable, default 0. Values other than 0 turn off some of the
  hardware's dependency checks. Leave it at 0.

| Value | Effect |
|---|---|
| 0 | All checks on. |
| 2, 3 | A memory instruction (DS, buffer or global) that stores the result of the previous ML op doesn't wait for it: it needs 2 wait states (`s_nop 1`) first, or it stores the old value. Some VALU results need 1. |
| 1 | As 2, and branches no longer wait for the instruction that sets SCC or VCC, so loops can run the wrong number of times. |

## Rules and hazards

- h = 1 must be followed immediately by an h = 0 instruction of this class, or the GPU can hang. h
  has no effect on results or speed, so use h = 0.
- The weight SGPRs are read early, without waiting for earlier writes to them. After writing them
  with SALU, wait with `s_waitcnt_depctr sa_sdst(0)` (or 2 wait states), and after a VALU write
  (`v_readfirstlane`) with `va_sdst(0)` (more than 8 wait states). Otherwise the op can read the old
  values.
- s[n+2] must be at or below s105.
- Ops with a D1 result always write it: 0 in the D1 field means v0, not "none". C+1 is always read,
  so C must not be the last allocated VGPR, or the wave dies without an error.
- Use wave32. In wave64, D0 is correct, but the second half of the wave (lanes 32-63) uses lanes
  0-31 of D1, so D1 is wrong in all lanes.
- VGPR writes don't wait for older memory instructions that still have to read those VGPRs, such as
  a store's data. Wait with `s_waitcnt_depctr vm_vsrc(0)` before overwriting them. The quantize op
  (0x28) is an exception: it does wait for a buffer store's data.
- An op that uses the previous op's accumulator stalls the SIMD for about 5 cycles, and other waves
  don't fill the gap. Interleave at least 4 independent accumulators.

## Throughput

Measured at 2.2-2.35 GHz with 16 waves per SIMD:

| Instruction | Rate per SIMD | Whole GPU |
|---|---|---|
| 0x23 with independent accumulators | ~0.97 per clock | ~280 TOPS int8 |
| 0x22 | ~0.97 per clock | ~280 TOPS int8 |
| 0x42 | ~0.95 per clock | ~68 TFLOPS fp16 |
| 0x23, 4 dependent ops per accumulator in a row | ~0.25 per clock | |
| 0x23 with new weights from a scalar load for every op | ~0.5 per clock | ~144 TOPS int8 |
| v_fmac_f32 (for comparison) | 0.99 per clock | 17.8 TFLOPS fp32 |

Weights read with scalar loads come through the scalar cache, which delivers about 32 bytes per
clock per WGP (4 SIMDs). That is enough for 0.5 ops per clock per SIMD when each op needs 16 new
bytes. Ops that share loaded weights, such as the same layer for two pixels, get past that limit.

## What's missing

There is no op that multiplies two VGPR operands as matrices: weights always come from scalar
registers or the literal. RDNA3 WMMA encodings don't work. In the class's opcode space, 0x02, 0x03,
0x0f, 0x12, 0x13, 0x17-0x1f, 0x25-0x27, 0x2b, 0x38-0x3f and 0x46-0x4f write 0. 0x5c and 0x70-0x72
hang the GPU, and 0x73-0x7f are unknown.

0x50-0x5b and 0x5d-0x6f (all the same) pop one entry from a FIFO of recent VGPR writes and write it
to D0. There are two FIFOs, for even and odd destination registers, each holding the last 4 values
written; D0's parity picks the FIFO. The FIFOs belong to the SIMD, not the wave, so these ops return
values written by other waves, including other programs' shaders. Running them has been followed by
GPU hangs in later graphics work. Don't use them.

MODE register bit 24 and COMPUTE_PGM_RSRC2 bit 31 can also be set on Viola. No effect of either has
been found.
