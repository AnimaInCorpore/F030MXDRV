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

## Host/DSP protocol v10

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 0a` (`MX`, version 10) |
| `02 rr dd` | write YM2151 register `rr = dd`, including during SSI playback | `00 00 00` |
| `03 00 00` | reset YM2151 state | `00 00 00` |
| `04 00 00` | clock one native 62.5 kHz sample | signed left sample |
| `05 cc oo` | query phase step for channel `cc`, logical operator `oo` | 20-bit phase step |
| `06 00 00` | query the last generated right sample | signed right sample |
| `07 00 ii` | query logical operator `ii` | 10-bit envelope attenuation |
| `08 00 00` | query chip status | timer flags plus busy in bit 7 |
| `09 00 00` | query LFO state | packed phase, AM, signed PM bytes |
| `0a 00 00` + 329 words | upload packed immutable ymfm tables | `00 00 00` after expansion/reset |
| `0b 00 00` | pre-render FM and start interrupt-fed SSI on buffer A | `00 00 00` before transmit starts |
| `0c 00 00` | stop and disable DSP SSI transmit | `00 00 00` |
| `0d 00 00` | query prepared SSI stereo frames | unsigned 24-bit frame count |
| `0e tt tt` + `02 rr dd` | queue `rr = dd` at absolute rolling native time `tttt` | `00 00 00`, or error if invalid/full/out of order |
| `0f 00 00` | query the rolling 16-bit native-sample clock | unsigned 16-bit time |
| `11 00 00` + 2014 words | upload 1007 interleaved stereo PCM frames, mix with a new FM period, and start interrupt-fed SSI | `00 00 00` before transmit starts |
| `12 00 00` | query the first nonzero mixed stereo probe | signed left+right sample sum |
| `13 00 00` + 2014 words | upload PCM to the inactive buffer, render FM in place, and switch at a stereo boundary | `00 00 00` after the switch |
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

Commands `0a`, `11`, and `13` are the exceptions to the single-word transaction
shape. Command `0a` consumes exactly 329 following host words before replying.
Command `11` consumes 1007 interleaved signed left/right frame pairs, renders
the matching FM period, saturates PCM+FM to signed 16-bit, and starts SSI on
buffer A. While SSI's fast transmit interrupt repeats that complete block,
command `13` receives the next PCM period into the inactive buffer, renders FM
there, and switches only after completing the current stereo pair. Buffer A is
at external `X:$1000`, buffer B at `X:$1800`; each uses modulo addressing over
2014 interleaved words. Command `12` returns the sum of the first nonzero mixed
left/right pair as a conformance probe retained after the stream stops.

Active buffered audio accepts synchronous command `02` writes, `0e`
transactions, `0f` queries, `13` refills, and command `0c`. A direct write
refreshes the phase cache for the next render; queued writes are consumed as a
refill advances fresh native samples. The rolling clock is not reset by start
or refill, so every completed block adds exactly 1280 native samples to one
continuous event timeline; only chip reset returns it to zero. Command `0d`
counts prepared frames, not the number replayed by SSI. This distinction keeps
the result deterministic when the same completed block repeats during a slow
refill.

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
   ownership. The TTP player loads one MDX and optional PDX through GEMDOS and
   drains that pump after each VBL until the tracks end or a key is pressed.
   Command-tail parsing has a Hatari-covered boundary self-test. E4/E5/E6 now
   use the original algorithm carrier masks and normal/raw attenuation rules,
   with active PDX gain updated in place. Modulation remains.
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
5. **Falcon audio (in progress):** the DSP converts 1280 native 62.5 kHz
   samples into 1007 frames at the Falcon's 25.175 MHz / 4 / 128 codec rate.
   Protocol v10 feeds 16-bit, two-word SSI network frames from a fast transmit
   interrupt using two aligned external-X buffers. The normal interrupt mutates
   only its dedicated `r6/m6` pair; a separate long exception path reads SSISR
   and writes TX to clear a transmit underrun. The 68030 can fill the inactive
   buffer while the previous complete period continues to loop, and the DSP
   disables the transmit interrupt briefly to switch at a stereo boundary.
   The Hatari gate exercises A-to-B and B-to-A refills, queued writes at exact
   boundaries, clock progression from 1280 through 3840 native samples, a
   three-second no-refill interval, and clean stop/tristate/unlock.

   The current scalar YM kernel still cannot synthesize at codec cadence. The
   earlier direct-mode measurement generated 5,679 fresh frames per nominal
   second, about 11.5% of the required rate; that mode was removed to recover
   program space for the interrupt vectors and second-buffer control. Rendering
   one 1007-frame block therefore still takes about 177 ms while the codec
   consumes it in 20.48 ms. Protocol v10 makes that miss safe by repeating the
   last complete block, but it does not make playback temporally accurate. The
   converted DSP image is currently 8,082 of the 8,192-byte loader budget, so
   only 110 bytes remain for further DSP features. More operator specialization
   and hardware cycle measurement are required to close the roughly 8.6x gap.
6. **PCM/PDX (in progress):** standard raw PDX banks have checked lookup for all
   96 offset/length entries and eight independent streaming MSM6258 decoders. A
   codec-rate host mixer implements the five PCM8 playback clocks with exact
   rational phase accumulation, all 16 two-decibel volume steps, common PCM8
   pan, voice start/stop and active masks, and signed 16-bit saturation. A
   generated oracle checks low-nibble-first decoding, predictor and step state,
   sample exhaustion, malformed bank ranges, and deterministic two-voice mixer
   frames under Hatari. A protocol-v10 integration gate renders one 1007-frame
   PCM period on the host, uploads it, checks the DSP-mixed stereo sum, and sends
   the block through the Falcon SSI path. MDX PCM notes now bind tracks 8-15 to
   PDX voices 0-7 with encoded durations and default rate/gain/pan. Continuous
   mixed-block scheduling and compatibility tests with real MDX/PDX pairs
   remain. The TTP player accepts and validates a PDX file and includes its
   decoded PCM in every inactive-buffer refill. Transport is continuous because
   the previous block repeats, but fresh PDX time advances only when the next
   block is prepared; real-time cadence therefore remains tied to the DSP FM
   optimization work above.

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
