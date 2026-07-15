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

## Host/DSP protocol v18

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 12` (`MX`, version 18) |
| `02 rr dd` | write YM2151 register `rr = dd`, including during SSI playback | `00 00 00` |
| `03 00 00` | reset YM2151 state | `00 00 00` |
| `04 00 00` | clock one native 62.5 kHz sample | signed left sample |
| `05 cc oo` | query phase step for channel `cc`, logical operator `oo` | 20-bit phase step |
| `06 00 00` | query the last generated right sample | signed right sample |
| `07 00 ii` | query logical operator `ii` | 10-bit envelope attenuation |
| `08 00 00` | query chip status | timer flags plus busy in bit 7 |
| `09 00 00` | query LFO state | packed phase, AM, signed PM bytes |
| `0a 00 00`, then 329 words after `52 44 59` | upload packed immutable ymfm tables | ready token, then `00 00 00` after expansion/reset |
| `0b 00 00` | pre-render FM and start interrupt-fed SSI on buffer A | `00 00 00` before transmit starts |
| `0c 00 00` | stop and disable DSP SSI transmit | `00 00 00` |
| `0d 00 00` | query prepared SSI stereo frames | unsigned 24-bit frame count |
| `0e tt tt` + `02 rr dd` | queue `rr = dd` at absolute rolling native time `tttt` | `00 00 00`, or error if invalid/full/out of order |
| `0f 00 00` | query the rolling 16-bit native-sample clock | unsigned 16-bit time |
| `10 00 00` | run the 2048-frame codec-rate four-operator feasibility kernel | deterministic checksum `6c 67 9b` |
| `11 00 00`, then 2014 words after `52 44 59` | upload 1007 interleaved stereo PCM frames, mix with a new FM period, and start interrupt-fed SSI | ready token, then `00 00 00` before transmit starts |
| `12 00 00` | query the first nonzero mixed stereo probe | signed left+right sample sum |
| `13 00 00`, then 2014 words after `52 44 59` | upload PCM to the inactive buffer, render FM in place, and switch at a stereo boundary | ready token, then `00 00 00` after the switch |
| `14 00 00` | run the 2048-frame block-oriented algorithm-0 channel spike | deterministic checksum `0f 26 66` |
| `15 00 00` | run the 2048-frame block-oriented algorithm-7 carrier spike | deterministic checksum `89 eb 00` |
| `16 00 aa` | run the 2048-frame mixed-topology spike for algorithm `aa = 1..6` | per-algorithm deterministic checksum |
| `17 00 00` | run the 128-block live-SSI decoded-control and envelope engine | deterministic checksum `ab 5f 30` |
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

Command `10` is a conformance and cycle-measurement spike, not an audio command.
It owns `r0-r5`, `m0-m5`, and `n0-n3` while SSI is stopped, restores linear
addressing and the external Y map before returning, and lets Hatari bracket
only its hot loop through listing-resolved symbols. Like the block spikes, it
uses the DSP56001's factory sine ROM and rebuilds the exact-renderer phase cache
after unmapping it. Its checksum is gated so address-ring or parallel-move
regressions cannot silently invalidate the timing result.

Command `14` is the block-oriented successor spike. It renders one serial
M1(feedback)->C1->M2->C2 channel for 2048 codec frames in operator-major
64-frame blocks, with per-frame feedback/modulation, block-held gains, and
interleaved stereo output. It owns `r0-r7`, `m0/m3/m5-m7`, and `n0/n6` while
SSI is stopped, reuses both audio buffers as its stereo output block, and
temporarily maps the DSP56001's on-chip 256-step sine ROM over external
`Y:$0100-$01ff`. Its 48-bit phase/residual words also overlay exact-renderer
cache locations at `Y:$0054-$0058`. Command `$14` restores the external map
and rebuilds those caches before replying with the block's deterministic
checksum, which the smoke suite gates like command `10`'s.

Command `15` reuses command `14`'s state, ROM mapping, DDA, output buffers, and
cleanup but exercises an algorithm-7-shaped four-carrier topology. Operator 1
keeps per-frame feedback and writes a half-amplitude carrier to the internal
ring. Operators 2-4 preload that accumulation in parallel with their phase
masks and use `MAC` rather than a separate multiply/add pair; operator 4 emits
the interleaved stereo result. Its independent checksum and profile gate the
carrier-specialized stage shape without weakening the serial-path test.

Command `16` completes the topology feasibility matrix for algorithms 1-6.
Its low byte selects the algorithm, and six specialized outer loops compose a
shared set of 64-frame operator stages. Algorithms 4 and 5 keep their reusable
modulation ring in internal Y and their carrier accumulation in internal X;
the phase `MAC` preloads the X accumulation before the indexed Y sine-ROM read,
avoiding a competing Y-memory access.
Operator-1 feedback is stored at its already-divided 1/8 depth, avoiding three
hot-loop shifts while retaining non-zero downstream modulation. The replies
for algorithms 1-6 are respectively `1e 36 26`, `50 e7 18`, `18 4e af`,
`19 05 4b`, `ff c6 a7`, and `66 25 49`. The command owns `r0-r7`,
`m2/m3/m5-m7`, and `n6`, reuses the audio buffers for output, and restores
linear addressing, the external Y map, and exact-renderer caches before reply.

Command `17` is the first integrated codec-rate all-topology mixed-output stress
profile. It keeps the real SSI fast transmit interrupt active on buffer A,
reserves `r6/m6` for that interrupt, and begins with algorithms 0-7 on eight
channels in 64-frame blocks from 32 overlaid internal long phases. Decoded
channel-control writes change algorithm and pan during the run. All four
both/left/right/mute modes route audible carriers into an internal common ring
or host-prepared planar PDX streams. The final pass adds the common group,
interleaves left/right into buffer B, and moves full accumulators so the
DSP56001 limiter supplies signed 24-bit saturation. The 2,048-frame planar
fixture represents successively refilled inactive blocks and wraps every 32
blocks across the 128-block profile; its preparation is outside the measured
DSP bracket, as it would be on the 68030. Every profile array stays within
Falcon's 8,192-word X/Y reservations. The right stream temporarily overlays
external-Y table storage, so the packed table is backed up in X and
re-expanded after the measurement.

The measured window also advances the complete decoded control state: a
drift-free 1280:1007 native clock, a decoded-rate LFO, both decoded timers
under their control bits, a maximum-length one-step-per-frame noise LFSR, and
a profile-local 32-entry FIFO whose boundary service drains every due event:
one write at each of the first 25 block boundaries, a seven-event burst —
the shape of a real MXDRV voice load — at boundary 24, and a late key-off
at boundary 90, leaving the remaining boundaries on the empty fast path.
One two-instruction, 32-iteration support loop rebuilds every PM-adjusted
per-operator phase increment from its decoded base, then tail-calls the
internal-P envelope pass that advances every envelope-active operator by
its composed full-block affine step, applies the boundary ADSR
transitions, and rebuilds moved gains through the 2^(-x/64) decomposition. Pitch state
is operator-major, so the algorithm bodies preload each stage's increment
through the channel's feedback pointer while the channel-control read rides
the parallel Y-bank pointer; the DSP56001 only pairs same-numbered index and
address registers, which fixed this layout. The 32 fixture events cover
every decoded register class: `$20-$27` algorithm/pan, four-band total
level, KC/KF pitch rebuilds from the exact expanded phase-step table with
octave shift and doubled per-operator multipliers, key edges that restart
real attacks with zeroed phases or move operators to release, all four
envelope-rate groups translated through the raw M1/M2/C1/C2 slot map into
live affine-constant reloads when the class matches the operator's ADSR
state, LFO rate/depth/waveform, and Timer B plus timer control
load/run/status behavior. The scaled `$19` depth turns the low
eight control bits into this block's signed PM offset, bit 16 still selects
full or 0.75 AM gain, and the exact 64-step noise transform runs through
6/6/5-bit slice tables the command derives from the LFSR step function at
setup, keeping every table word out of the bounded P image. The common ring
is write-first: the block's first both-panned carrier stores instead of
accumulating, replacing the former per-block ring clear, and the rare block
whose dynamic pan leaves the ring unwritten clears it once at emission.
Both write variants keep the full-accumulator limiter moves, so the stereo
output — and the command checksum — are bit-identical to the cleared-ring
ordering. Algorithms 6/7 route their already-summed
carrier rings through a separate decoded-pan path. The command explicitly
clears a latched SSI underrun before restoring the external Y map and exact
phase cache. Its checksum is `ab 5f 30`.

Hatari measures 319.97 cycles per codec frame over the 8,192-frame,
128-block profile against the 326.27-cycle budget, leaving 6.30 cycles
(1.9%). Dynamic topology/pan routing, planar PDX accumulation, final
saturation, live SSI, the full decoded register control path, and decoded
envelope curvature therefore fit the budget together. Envelope-active
operators advance once per block by a composed full-block affine step from
generated per-rate tables — exponential attacks toward zero attenuation,
linear decay/sustain/release with exact mean tick rates, block-boundary
ADSR transitions, and total-level gains rebuilt through a 2^(-x/64)
decomposition only when the 10-bit attenuation moved. The pass runs from
internal P RAM and its cost is proportional to envelope activity: operators
whose envelope can no longer move retire from the active list, and the
fixture's eight-operator key-on transient, sustained D2R decay tail, and
late release all retire inside the measured window. The 128-block window
amortizes the 32-event fixture at a realistic MXDRV write density instead of
the previous 4x-dense 32-block window. Noise-frequency decode stays outside
this gate.

Multi-word block uploads are gated by the `52 44 59` ready token because
TOS 4.02's `Dsp_BlkUnpacked` polls the host-port TXDE flag only before its
first word and then writes the remaining block blind. A third back-to-back
word overwrites the one-deep transmit latch whenever the DSP has not yet
parked in its tight receive loop, so the host now transfers the bare command,
waits for the token the DSP sends from immediately before that loop, and only
then releases the block. The race cost one PCM word and deadlocked both sides
under Hatari, and real hardware shares the blind-write behavior.

The constants are duplicated in `src/m68k/protocol.i` and
`src/dsp/protocol.inc` because the two assemblers do not share syntax. Keep the
protocol version in the ping reply whenever either side changes incompatibly.

## Stages

1. **Scaffold (done):** build both CPUs, load/ping/reset, mirror OPM registers,
   and expose the MXDRV `WriteOPM` seam.
2. **Driver API and MDX executor (in progress):** preserve the 32-call table and
   Trap #4 register convention, own bounded MDX/PDX copies, expose OPM/PCM work
   buffers, and implement reset/play/stop/pause/fade/mask state. Playback now
   parses standard raw MDX title/PDX headers, accepts both 9- and 16-track
   tables, validates the sequence, voice table, and every track offset, then
   advances bounded waits and notes one explicit tick at a time. FF/FE tempo
   and raw OPM writes, FD FM voice loading/PCM bank selection, pan, PCM volume,
   note length, F6/F5/F4 repeat control flow, FM pitch/key-on/off, PCM triggers,
   and track ends execute. Repeat targets and mutable work bytes are range
   checked. A
   guarded timer-service seam exposes the exact Timer-B period in native sample
   units. Public play now claims an otherwise-idle MFP Timer A at 1024 Hz; its
   interrupt performs exact 16.16 phase accumulation into pending ticks, while
   a foreground pump performs all XBIOS/DSP work. Stop restores timer/vector
   ownership. The TTP player loads one MDX and optional PDX through GEMDOS and
   drains that pump after each VBL until the tracks end or a key is pressed.
   Command-tail parsing has a Hatari-covered boundary self-test. FB/FA/F9 now
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
   Protocol v18 feeds 16-bit, two-word SSI network frames from a fast transmit
   interrupt using two aligned external-X buffers. The normal interrupt mutates
   only its dedicated `r6/m6` pair; a separate long exception path reads SSISR
   and writes TX to clear a transmit underrun. The 68030 can fill the inactive
   buffer while the previous complete period continues to loop, and the DSP
   disables the transmit interrupt briefly to switch at a stereo boundary.
   The Hatari gate exercises A-to-B and B-to-A refills, queued writes at exact
   boundaries, clock progression from 1280 through 3840 native samples, a
   three-second no-refill interval, and clean stop/tristate/unlock.

   A reproducible Hatari DSP-cycle gate now supersedes the earlier VBL-derived
   throughput estimate. With four operators active on all eight channels and
   the cached no-PM path selected, rendering one 1280-sample period consumes
   15,391,151 instruction cycles, or 12,024.34 per native sample. The Falcon
   budget is 256.68 cycles per sample, so the exact scalar kernel misses real
   time by 46.85x before steady SSI and host-port overhead. Protocol v18 makes
   that miss safe by repeating the last complete block, but it does not make
   playback temporally accurate. The exact kernel is retained as the
   conformance reference; the real-time output contract now requires an
   explicit accuracy/rate/workload compromise rather than another scalar
   optimization pass. An embedded second-stage P-memory loader now removes the
   former 8 KiB converted-LOD ceiling: a 111-word `Dsp_ExecBoot` program at
   `P:$0040` receives all sparse P sections, acknowledges completion, and enters
   the final program at its replaced reset vector.
6. **PCM/PDX (in progress):** standard raw PDX banks have checked lookup for all
   96 offset/length entries and eight independent streaming MSM6258 decoders. A
   codec-rate host mixer implements the five PCM8 playback clocks with exact
   rational phase accumulation, all 16 two-decibel volume steps, common PCM8
   pan, voice start/stop and active masks, and signed 16-bit saturation. A
   generated oracle checks low-nibble-first decoding, predictor and step state,
   sample exhaustion, malformed bank ranges, and deterministic two-voice mixer
   frames under Hatari. A protocol-v18 integration gate renders one 1007-frame
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
and emits both per-native-sample conformance vectors and exact codec-cadence
reference vectors. Falcon DSP captures of the same traces can be compared at
these boundaries:

- decoded channel/operator parameters after writes;
- phase step and envelope attenuation per operator;
- per-algorithm channel output before panning;
- stereo output before and after YM3012 rounding;
- timer/status events in source-clock units and timer-driven CSM output.

Exact equality remains the contract for the conformance kernel's integer state
and pre-resampling native samples. The cycle gate shows that this kernel is not
a viable real-time renderer on a stock Falcon. Any replacement audio kernel
must state its relaxed boundary explicitly and retain the exact path for
regression comparisons.

The reference side of that comparison is now executable. `make check` creates
15 codec-rate scenarios for pitch, write/key timing, ADSR, AM/PM LFO, noise,
feedback levels 0/7, and all eight algorithms. Every row records the exact
1280:1007 native boundary, ordered-write count/hash, stereo output, and
operator/control state. `tools/compare_ym2151_realtime.py` validates that
coverage and accepts future candidate captures using drift/timing, envelope,
LFO/noise-rate, and spectral thresholds documented in
`docs/perceptual-compatibility.md`. This completes the reference and policy
half of the perceptual gate. A second native projection independently applies
the 256-step sine phase, codec-rate feedback, algorithms, panning, noise, and
YM3012 rounding while borrowing exact frame-boundary control state. It passes
with topology spectral cosine of 0.7229-0.9999, log-spectrum RMSE of
5.09-10.61 dB, and energy ratio of 0.967-1.028. The integrated DSP kernel still
needs to emit its own candidate capture.

## Real-time compatibility contract

The selected Falcon playback target is perceptual FM compatibility at the
49,169.921875 Hz codec cadence, with the exact command-clocked kernel retained
as an offline/conformance oracle. The real-time kernel must preserve these
externally meaningful behaviors:

- every YM register write remains ordered and is mapped to the first codec
  sample at or after its exact 62.5 kHz timestamp, with less than one codec
  frame of output-event latency;
- key state, channel algorithm, panning, total-level changes, Timer A/B status,
  busy state, and CSM event order retain the exact register semantics;
- oscillator, envelope, LFO, noise, and timer accumulators have no long-term
  rate drift; pitch and control-rate timing may be quantized only to the codec
  frame boundary;
- PDX decoding, rate conversion, gain, panning, and saturated PCM/FM mixing
  retain their current integer contracts; and
- an all-eight-FM/all-eight-PDX workload must produce fresh buffers without an
  SSI underrun on a stock Falcon.

Native per-sample operator output, feedback history, modulation sidebands, and
YM3012 rounding are not required to equal ymfm sample for sample in this mode.
They must instead be checked against the exact kernel with pitch/timing tests,
spectral and envelope comparisons, and a corpus of real MDX/PDX material. A
codec-rate engine must update feedback and modulation on every produced sample;
holding selected native outputs is not a valid shortcut because those outputs
feed later operator state.

## Remaining roadmap

1. **Full decoded control and envelope feasibility measured:** commands
   `14`-`16` cover every isolated YM topology: algorithms 0-7 cost 37.75,
   37.00, 37.98, 37.00, 38.00, 39.05, 35.98, and 37.70 cycles per
   channel/frame, and their linear eight-channel projections fit the
   326.27-cycle budget. Command `17` now measures eight channels, one per
   algorithm, over 128 blocks with internal phase/feedback state, live SSI,
   stereo emission, drift-free LFO/noise/timer advancement, dynamic
   algorithm/pan, planar PDX/FM accumulation, final saturation, block-held
   AM/PM in every operator, decoded application of every remaining write
   class — total level, KC/KF pitch rebuilds from the exact phase-step
   table, key on/off, all four envelope-rate groups, LFO
   rate/depth/waveform, and both timers — and decoded envelope curvature:
   per-rate full-block affine steps with exponential attacks, block-boundary
   ADSR transitions, activity-proportional retirement, and
   attenuation-gated gain rebuilds, at 319.97 cycles/frame, inside the
   budget with 1.9% remaining. The Python prototype scores the same
   quantized block recurrence at mean attenuation error 2.99/1023,
   correlation 0.977, and 61-frame transition lag against the exact ADSR
   reference, inside every comparator boundary. Noise-frequency decode
   remains outside the gate.
2. **Reference gate complete:** the build now validates exact codec-rate
   vectors for pitch, key/write timing, envelopes, LFO/noise rates, feedback
   spectra, and all eight algorithms, gates an independent native perceptual
   projection, and provides the same comparator for future DSP captures.
3. Integrate the selected real-time kernel with the rolling write FIFO and
   double-buffered PCM mixer while retaining the current exact protocol path,
   then feed its state/output capture through the comparison gate.
4. Measure cycle count, SSI underruns, buffer switches, and host/DSP contention
   on a real Falcon before declaring the audio transport complete.
5. Finish MDX software modulation, synchronization, legato, remaining command
   behavior, and continuous mixed FM/PDX scheduling.
6. Run a compatibility corpus of real MDX/PDX pairs and complete the public
   MXDRV call-table behavior, error handling, packaging, and hardware soak
   tests.
