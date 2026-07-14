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

## Host/DSP protocol v7

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 07` (`MX`, version 7) |
| `02 rr dd` | write YM2151 register `rr = dd`, including during bounded SSI playback | `00 00 00` |
| `03 00 00` | reset YM2151 state | `00 00 00` |
| `04 00 00` | clock one native 62.5 kHz sample | signed left sample |
| `05 cc oo` | query phase step for channel `cc`, logical operator `oo` | 20-bit phase step |
| `06 00 00` | query the last generated right sample | signed right sample |
| `07 00 ii` | query logical operator `ii` | 10-bit envelope attenuation |
| `08 00 00` | query chip status | timer flags plus busy in bit 7 |
| `09 00 00` | query LFO state | packed phase, AM, signed PM bytes |
| `0a 00 00` + 329 words | upload packed immutable ymfm tables | `00 00 00` after expansion/reset |
| `0b 00 00` | pre-render and start the bounded SSI block | `00 00 00` before transmit starts |
| `0c 00 00` | stop and disable DSP SSI transmit | `00 00 00` |
| `0d 00 00` | query completed SSI stereo frames | unsigned 24-bit frame count |
| `0e tt tt` + `02 rr dd` | queue `rr = dd` at absolute rolling native time `tttt` | `00 00 00`, or error if invalid/full/out of order |
| `0f 00 00` | query the rolling 16-bit native-sample clock | unsigned 16-bit time |
| anything else | unsupported command | `ff ff ff` |

The synchronous acknowledgement intentionally provides back-pressure and keeps
conformance replay deterministic. The emulated YM2151 busy flag remains set
until command `04` advances the 64 input clocks represented by one native
sample. Command `04` is a testable sample clock, not the eventual real-time
audio path. Command `0e` establishes the event transport needed by the future
SSI-driven synthesis loop: up to 32 writes are accepted in nondecreasing
modular order and applied before the exact native sample. The 16-bit clock
wraps naturally; entries must be no more than 32,767 samples ahead. Command
`0f` exposes the current scheduling position to the host.

Command `0a` is the one bootstrap exception to the single-word transaction
shape: it consumes exactly 329 following host words before replying. Moving
those initialized records into the host executable recovered about 1 KiB from
the TOS 4.02 converted-loader limit. During the bounded audio session, the
stream loop accepts synchronous command `02` writes and command `0c`. Because
the repeated block was rendered before SSI starts, writes update chip state for
the next render and the static phase cache is rebuilt after SSI stops; they do
not retroactively change the active block. It also accepts `0e` transactions,
which remain queued for the next render. The rolling clock is not reset by
`0b`, so consecutive renders consume one continuous event timeline; only chip
reset returns it to zero.

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
4. **Chip globals (present):** register reset, key edges, pan, YM3012
   10.3-float round-trip behavior, all LFO waveforms, AM/PM modulation,
   channel-7 noise, Timer A/B load/reload/reset/status behavior, CSM keying,
   and the write-busy status bit are implemented.
5. **Falcon audio (in progress):** the DSP now converts 1280 native 62.5 kHz
   samples into 1007 frames at the Falcon's 25.175 MHz / 4 / 128 codec rate,
   then a bounded probe loops that exact stereo block through 16-bit, two-word
   SSI network frames. The 68030 locks the sound system, connects DSP transmit
   to the DAC without handshaking, validates the transmitted frame count, stops
   and tristates SSI, and unlocks sound. The current scalar YM kernel cannot
   synthesize at codec cadence (Hatari measured only 3,241 fresh frames in a
   three-second direct-stream experiment). The first optimization pass now
   caches static phase increments, reduces the no-PM phase loop to parallel
   phase/cache fetch plus add/store, and bypasses terminal envelopes and fully
   silent channels without changing the exact sample vectors. The SSI loop also
   services synchronous writes through the real MXDRV `WriteOPM` seam and
   preserves them for the next render. Protocol v7 adds a checked 32-entry FIFO,
   a queryable rolling native clock, and exact sample-boundary writes across
   consecutive renders. More operator specialization and cycle measurement are
   still required before the pre-rendered block can be replaced by continuous
   live synthesis.
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
- timer/status events in source-clock units and timer-driven CSM output.

Exact equality is expected for integer state and pre-resampling native samples.
Only the future resampling stage may introduce explicitly documented error.
