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

## Host/DSP protocol v9

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 09` (`MX`, version 9) |
| `02 rr dd` | write YM2151 register `rr = dd`, including during either SSI mode | `00 00 00` |
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
| `10 00 00` | start experimental direct synthesis and SSI transmit | `00 00 00` before transmit starts |
| `11 00 00` + 2014 words | upload 1007 interleaved stereo PCM frames, mix with a new FM period, and start bounded SSI | `00 00 00` before transmit starts |
| `12 00 00` | query the first nonzero mixed stereo probe | signed left+right sample sum |
| anything else | unsupported command | `ff ff ff` |

The synchronous acknowledgement intentionally provides back-pressure and keeps
conformance replay deterministic. The emulated YM2151 busy flag remains set
until command `04` advances the 64 input clocks represented by one native
sample. Command `04` is a testable sample clock, not the eventual real-time
audio path. Command `0e` establishes the event transport needed by the future
SSI-driven synthesis loop: up to 32 writes are accepted in nondecreasing
modular order and applied before the exact native sample. The storage is a ring
FIFO, so the host can refill slots after earlier entries are consumed. The
16-bit clock wraps naturally; entries must be no more than 32,767 samples
ahead. Command `0f` exposes the current scheduling position to the host.

Commands `0a` and `11` are the exceptions to the single-word transaction
shape. Command `0a` consumes exactly 329 following host words before replying;
command `11` consumes 1007 interleaved signed left/right frame pairs, renders
the matching FM period, saturates PCM+FM to signed 16-bit, and then starts the
same bounded SSI loop used by command `0b`. Command `12` returns the sum of the
first nonzero mixed left/right pair as a conformance probe retained after the
stream stops. Moving
those initialized records into the host executable recovered about 1 KiB from
the TOS 4.02 converted-loader limit. All audio modes accept synchronous command
`02` writes, `0e` transactions, `0f` queries, and command `0c`. In bounded mode,
the repeated block was rendered before SSI starts, so later writes cannot alter
that block. In direct mode, the phase cache is refreshed immediately and queued
writes are consumed as fresh frames advance native time. The rolling clock is
not reset by any start command, so buffered and live sessions share one
continuous event timeline; only chip reset returns it to zero.

The constants are duplicated in `src/m68k/protocol.i` and
`src/dsp/protocol.inc` because the two assemblers do not share syntax. Keep the
protocol version in the ping reply whenever either side changes incompatibly.

## Stages

1. **Scaffold (done):** build both CPUs, load/ping/reset, mirror OPM registers,
   and expose the MXDRV `WriteOPM` seam.
2. **Driver API and MDX executor (in progress):** preserve the 32-call table and
   Trap #4 register convention, own bounded MDX/PDX copies, expose OPM/PCM work
   buffers, and implement reset/play/stop/pause/fade/mask state. Playback now
   validates the sequence, voice-table, and all 16 track offsets, then advances
   bounded waits and notes one explicit tick at a time. E0/E1 tempo and raw OPM
   writes, E2 FM voice loading/PCM bank selection, pan, PCM volume, note length,
   E9/EA/EB repeat control flow, FM pitch/key-on/off, PCM triggers, and track
   ends execute. Repeat targets and mutable work bytes are range checked. A
   guarded timer-service seam exposes the exact Timer-B period in native sample
   units. Public play now claims an otherwise-idle MFP Timer A at 1024 Hz; its
   interrupt performs exact 16.16 phase accumulation into pending ticks, while
   a foreground pump performs all XBIOS/DSP work. Stop restores timer/vector
   ownership. An application event loop still needs to call that pump regularly;
   modulation and full FM volume handling remain.
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
   synthesize at codec cadence. The first optimization pass now
   caches static phase increments, reduces the no-PM phase loop to parallel
   phase/cache fetch plus add/store, and bypasses terminal envelopes and fully
   silent channels without changing the exact sample vectors. The SSI loop also
   services synchronous writes through the real MXDRV `WriteOPM` seam and
   preserves them for the next render. Protocol v9 adds a checked, refillable
   32-entry ring FIFO, a queryable rolling native clock, and an experimental
   direct SSI mode that consumes exact sample-boundary writes while generating
   fresh frames. It also accepts one exact host-rendered PCM period, combines it
   with a newly rendered FM period on the DSP, and replays the saturated stereo
   result through SSI. The Hatari smoke run generated 5,679 fresh frames during its
   nominal one-second direct probe, about 11.5% of codec cadence. More operator
   specialization and cycle measurement are still required before this mode is
   underrun-free on hardware and can replace the pre-rendered transport proof.
   The converted DSP image is currently 8,148 of the 8,192-byte loader budget,
   so further DSP features also require reclaiming initialized image space.
6. **PCM/PDX (in progress):** standard raw PDX banks have checked lookup for all
   96 offset/length entries and eight independent streaming MSM6258 decoders. A
   codec-rate host mixer implements the five PCM8 playback clocks with exact
   rational phase accumulation, all 16 two-decibel volume steps, common PCM8
   pan, voice start/stop and active masks, and signed 16-bit saturation. A
   generated oracle checks low-nibble-first decoding, predictor and step state,
   sample exhaustion, malformed bank ranges, and deterministic two-voice mixer
   frames under Hatari. A protocol-v9 integration gate renders one 1007-frame
   PCM period on the host, uploads it, checks the DSP-mixed stereo sum, and sends
   the block through the Falcon SSI path. MDX PCM notes now bind tracks 8-15 to
   PDX voices 0-7 with encoded durations and default rate/gain/pan. Continuous
   mixed-block scheduling and compatibility tests with real MDX/PDX pairs
   remain.

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
