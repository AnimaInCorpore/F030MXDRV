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

## Host/DSP protocol v4

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 04` (`MX`, version 4) |
| `02 rr dd` | write YM2151 register `rr = dd` | `00 00 00` |
| `03 00 00` | reset YM2151 state | `00 00 00` |
| `04 00 00` | clock one native 62.5 kHz sample | signed left sample |
| `05 cc oo` | query phase step for channel `cc`, logical operator `oo` | 20-bit phase step |
| `06 00 00` | query the last generated right sample | signed right sample |
| `07 00 ii` | query logical operator `ii` | 10-bit envelope attenuation |
| `08 00 00` | query chip status | timer flags plus busy in bit 7 |
| `09 00 00` | query LFO state | packed phase, AM, signed PM bytes |
| anything else | unsupported command | `ff ff ff` |

The synchronous acknowledgement intentionally provides back-pressure and keeps
conformance replay deterministic. The emulated YM2151 busy flag remains set
until command `04` advances the 64 input clocks represented by one native
sample. Command `04` is a testable sample clock, not the eventual real-time
audio path. A bounded write FIFO plus an SSI-driven synthesis loop should
replace per-write/per-sample exchanges once playback is running.

The constants are duplicated in `src/m68k/protocol.i` and
`src/dsp/protocol.inc` because the two assemblers do not share syntax. Keep the
protocol version in the ping reply whenever either side changes incompatibly.

## Stages

1. **Scaffold (done):** build both CPUs, load/ping/reset, mirror OPM registers,
   and expose the MXDRV `WriteOPM` seam.
2. **Driver API foundation (present):** preserve the 32-call table and Trap #4
   register convention, own bounded MDX/PDX copies, expose OPM/PCM work buffers,
   and implement basic reset/play/stop/pause/fade/mask state. MDX track parsing,
   command execution, and timer service are still pending.
3. **Operator kernel (present):** KC/KF, DT1, DT2, octave, multiplier, phase
   accumulation, log-sine/power conversion, ADSR, operator mapping, feedback,
   all eight algorithms, panning, and stereo sample generation now run on the
   DSP. The checked attack trace is bit-exact with ymfm at the phase, envelope,
   and rounded-output boundaries; a second sweep covers all eight algorithms
   with operator feedback enabled.
4. **Chip globals (partial):** register reset, key edges, pan, YM3012
   10.3-float round-trip behavior, all LFO waveforms, AM/PM modulation,
   channel-7 noise, and the write-busy status bit are implemented. Timer A/B
   flags and CSM remain.
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

Exact equality is expected for integer state and pre-resampling native samples.
Only the future resampling stage may introduce explicitly documented error.
