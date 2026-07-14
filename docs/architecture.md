# Architecture and staged port plan

## Ownership

The 68030 side owns MXDRV-compatible calls, MDX/PDX parsing, track state,
tempo/timer scheduling, and ADPCM coordination. The DSP side owns the complete
YM2151 state machine and stereo FM sample generation. A small command transport
is the only coupling between them.

This matches the natural porting seam in the reference MXDRV. Its `WriteOPM`
routine receives the register in `d1.b` and data in `d2.b`, mirrors the byte in
`OPMBuf`, then writes the X68000 OPM ports. `src/m68k/mxdrv_port.s` preserves
those input conventions and replaces the hardware write with one DSP word.

## Host/DSP protocol v2

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 02` (`MX`, version 2) |
| `02 rr dd` | write YM2151 register `rr = dd` | `00 00 00` |
| `03 00 00` | reset YM2151 state | `00 00 00` |
| `05 cc oo` | query phase step for channel `cc`, logical operator `oo` | 20-bit phase step |
| anything else | unsupported command | `ff ff ff` |

The synchronous acknowledgement intentionally provides back-pressure. It makes
the first integration deterministic and avoids reproducing the physical
YM2151's busy pin in the transport. A bounded write FIFO/batch command should
replace per-write acknowledgements once the replay loop is running.

The constants are duplicated in `src/m68k/protocol.i` and
`src/dsp/protocol.inc` because the two assemblers do not share syntax. Keep the
protocol version in the ping reply whenever either side changes incompatibly.

## Stages

1. **Scaffold (present):** build both CPUs, load/ping/reset, mirror OPM
   registers, expose the MXDRV `WriteOPM` seam, and compare a DSP phase step
   exactly against the native ymfm oracle under Hatari.
2. **Driver core:** lift the resident/trap-independent portions of MXDRV into
   the new 68030 build, keep its 32-call API shape, and redirect all OPM writes.
3. **Operator kernel (phase started):** extend the present KC/KF, DT1, DT2,
   octave, and multiplier kernel with phase accumulation, log-sine/attenuation,
   envelope, operator mapping, feedback, and eight algorithms in 24-bit DSP
   fixed point. Validate every boundary against the native ymfm oracle.
4. **Chip globals:** add key-on semantics, LFO waveforms, AM/PM, timers, CSM,
   channel 7 noise, pan, and YM3012 10.3-float round-trip behavior.
5. **Falcon audio:** clock the DSP synthesis kernel, resample the X68000's
   62.5 kHz OPM stream for a supported Falcon codec rate, and transmit stereo
   through SSI/crossbar. Restore all locked audio/DSP resources on exit.
6. **PCM/PDX:** add the X68000 ADPCM path and mixer, then compatibility tests
   for real MDX/PDX material.

## Validation strategy

Do not judge the DSP core only by ear. `tools/ym2151_oracle.cpp` now drives the
vendored `third_party/mame/3rdparty/ymfm` YM2151 with timestamped register traces
and emits per-sample state/output vectors. Falcon DSP captures of the same
traces can be compared at these boundaries:

- decoded channel/operator parameters after writes;
- phase step and envelope attenuation per operator;
- per-algorithm channel output before panning;
- stereo output before and after YM3012 rounding;
- timer/status events in source-clock units.

Exact equality is expected for integer state. Audio comparisons should allow
only the explicitly documented fixed-point/resampling error.
