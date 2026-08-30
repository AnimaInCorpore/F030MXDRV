# Architecture and implementation status

The player path described here is implemented and gated under Hatari. The
remaining project work is physical-Falcon validation, the unsupported and
state-only MXDRV API cases listed in [`mxdrv-api.md`](mxdrv-api.md), and release
packaging. The numbered implementation areas below are a status record, not a
future port plan.

## Ownership

The 68030 side owns MXDRV-compatible calls, MDX/PDX parsing, track state,
tempo/timer scheduling, and ADPCM coordination. The DSP side owns the complete
YM2151 state machine and stereo FM sample generation. A small command transport
is the only coupling between them.

This matches the natural porting seam in the reference MXDRV. Its `WriteOPM`
routine receives the register in `d1.b` and data in `d2.b`, mirrors the byte in
`OPMBuf`, then writes the X68000 OPM ports. `src/m68k/mxdrv_port.s` preserves
those input conventions and replaces the hardware write with one DSP word.

## Host/DSP protocol v24

Every transport unit is one DSP/host 24-bit word. The upper byte is an opcode.

| Word | Meaning | Reply |
| --- | --- | --- |
| `01 00 00` | ping/protocol query | `4d 58 18` (`MX`, version 24) |
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
| `12 00 00` | query the mixed-output probe | exact stream: first nonzero signed stereo sum; realtime stream: first-buffer checksum |
| `13 00 00`, then 2014 words after `52 44 59` | upload PCM to the inactive buffer, render FM in place, and switch at a stereo boundary | ready token, then `00 00 00` after the switch |
| `14 00 00` | run the 2048-frame block-oriented algorithm-0 channel spike | deterministic checksum `0f 26 66` |
| `15 00 00` | run the 2048-frame block-oriented algorithm-7 carrier spike | deterministic checksum `89 eb 00` |
| `16 00 aa` | run the 2048-frame mixed-topology spike for algorithm `aa = 1..6` | per-algorithm deterministic checksum |
| `17 00 00` | run the 256-block live-SSI decoded-control and envelope engine | deterministic checksum `ee d0 f2` |
| `18 00 00`, then an event count, 0–224 packed writes, PCM8 pan, and 512 mono PCM words after `52 44 59` | accept the first production period, render the realtime FM buffer, and start interrupt-fed SSI | ready token, then `00 00 00` when the upload is owned |
| `19 00 00`, with the same variable payload | accept the next production period, render 16 32-frame FM blocks, and switch at the following whole-buffer boundary | ready token, then `00 00 00` when the upload is owned |
| `1a 00 00` | opt into the boundary-wait host service: a parked `19` refill is received during the previous period's boundary wait, so its whole payload is resident before the handoff that frees its target buffer; the receive itself is boundary-aware and may straddle the wrap, performing the stereo-safe handoff in place. Cleared by reset, stop, and a new realtime start. The production player enables it once per session; conformance and capture flows never do, keeping their scored stream-loop command timing | `00 00 00` |
| anything else | unsupported command | `ff ff ff` |

The synchronous acknowledgement intentionally provides back-pressure and keeps
conformance replay deterministic. The emulated YM2151 busy flag remains set
until command `04` advances the 64 input clocks represented by one native
sample. Command `04` is a testable sample clock, not the eventual real-time
audio path. Command `0e` supplies the event transport used by both SSI-driven
synthesis loops: up to 32 writes are accepted in nondecreasing
modular order and applied before the exact native sample. The storage is a ring
FIFO, so the host can refill slots after earlier entries are consumed. The
16-bit clock wraps naturally; entries must be no more than 32,767 samples
ahead. Command `0f` exposes the current scheduling position to the host.

Commands `0a`, `11`, `13`, `18`, and `19` are the exceptions to the single-word
transaction shape. Command `0a` consumes exactly 329 following host words
before replying.
Command `11` consumes 1007 interleaved signed left/right frame pairs, renders
the matching FM period, saturates PCM+FM to signed 16-bit, and starts SSI on
buffer A. While SSI's fast transmit interrupt repeats that complete block,
command `13` receives the next PCM period into the inactive buffer, renders FM
there, and switches only after completing the current stereo pair. Buffer A is
at external `X:$1000`, buffer B at `X:$1800`; each uses modulo addressing over
2014 interleaved words. Command `12` returns the sum of the first nonzero mixed
left/right pair as a conformance probe retained after the stream stops.

Commands `18` and `19` are the production realtime counterparts. Each receives
a count and up to 64 ordered, coalesced YM writes followed by the common PCM8
pan and 512 signed mono PCM frames. The DSP first receives those event words
into a short-loop staging array, then queues them at the current rolling
timestamp after the complete blind TOS bulk upload is safe. It expands the
mono block into the selected planar 24-bit
accumulators, applies a two-tap PCM anti-image filter, and renders 16
operator-major 32-frame blocks into a 1024-word
SSI buffer. The start command imports the exact register and key image into the
persistent realtime state, backs up the packed lookup tables before its planar
right stream overlays external Y, derives the noise jump tables, and maps the
DSP56001 sine ROM. The DSP acknowledges once it owns the host payload; the
68030 then mixes and uploads the following period while the DSP renders and
waits for the next complete active-buffer boundary. Stop restores the packed
tables, exact caches, external-Y mapping, and linear address modifiers.
Command `12` returns the deterministic checksum of the first realtime buffer;
the Hatari attack-trace fixture expects `f8 c0 40`.

Active buffered audio accepts synchronous command `02` writes, `0e`
transactions, `0f` queries, the refill matching its current mode (`13` or
`19`), and command `0c`. In exact mode a direct write refreshes the exact phase
cache and queued writes are consumed at their precise native sample while a
refill renders 1280 native samples. In realtime mode direct writes are mirrored
into the exact register image and decoded into the persistent block state;
queued writes are drained at their landing frames: a block whose FIFO head
falls inside it renders as event-aligned segments, so every write takes
effect on the first codec frame at or after its native timestamp. Its
drift-free 1920:1007 DDA advances each 512-frame refill by 976 native
samples; the smoke sequence observes clocks 976, 1952, and 2928. The rolling
clock is not reset by start or refill; only chip reset returns it to zero.
Command `0d` counts prepared frames, not the number replayed by SSI, and reads
1536 after the start plus two realtime refills. This distinction keeps the
result deterministic when SSI repeats a completed block during a slow refill.

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

Command `17` is the integrated quality-kernel all-topology mixed-output stress
profile. It keeps the real SSI fast transmit interrupt active on buffer A,
reserves `r6/m6` for that interrupt, and begins with algorithms 0-7 on eight
channels in 32-frame blocks from 32 overlaid internal long phases. Decoded
channel-control writes change algorithm and pan during the run. All four
both/left/right/mute modes route audible carriers into an internal common ring
or host-prepared planar PDX streams. The final pass adds the common group,
interleaves left/right into buffer B, and moves full accumulators so the
DSP56001 limiter supplies signed 24-bit saturation. The planar fixture
represents successively refilled inactive blocks and wraps during the
256-block profile; its preparation is outside the measured
DSP bracket, as it would be on the 68030. Every profile array stays within
Falcon's 8,192-word X/Y reservations. The right stream temporarily overlays
external-Y table storage, so the packed table is backed up in X and
re-expanded after the measurement.

The measured window also advances the complete decoded control state: a
drift-free 1920:1007 native clock, a decoded-rate LFO, both decoded timers
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
through the channel's feedback pointer while a packed per-channel dispatch
word rides the parallel Y-bank pointer: its low sixteen bits address the
render entry for the channel's algorithm and feedback class (a bypass head
for level 0 and the exact-gain head for levels 1-7, resolved at register-decode
time so no per-block classification survives into the render), and bits
16-23 carry the raw control byte for the pan-routing tests. The DSP56001
only pairs same-numbered index and address registers, which fixed this
layout. The 32 fixture events cover
the profiled decoded control set: `$20-$27` algorithm/pan, four-band total
level, KC/KF pitch rebuilds from the exact expanded phase-step table with
octave shift and doubled per-operator multipliers, key edges that restart
real attacks with zeroed phases or move operators to release, all four
envelope-rate groups translated through the raw M1/M2/C1/C2 slot map into
live affine-constant reloads when the class matches the operator's ADSR
state, LFO rate/depth/waveform, and Timer B plus timer control
load/run/status behavior. The scaled `$19` depth turns the low
eight control bits into this block's signed PM offset, bit 16 still selects
full or 0.75 AM gain, and the exact 32-step noise transform runs through
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
phase cache. Its checksum is `ee d0 f2`.

Hatari measures 346.21 cycles per codec frame over the 8,192-frame,
256-block profile against the 489.40-cycle budget, leaving 143.19 cycles
(29.3%). Dynamic topology/pan routing, planar PDX accumulation, final
saturation, live SSI, the full decoded register control path, and decoded
envelope curvature therefore fit the budget together. That figure is a
bracketed render window and is not the whole cost: measured across whole
production periods, the same DSP spends 407.59 cycles per frame on synthesis
and transport plus 5.58 stalled on the 68030's host-port delivery, so real
occupancy is 84.4% and the margin is 76.22 cycles rather than 143.19. See
[`hatari-timing.md`](hatari-timing.md). Envelope-active
operators advance once per block by a composed full-block affine step from
generated per-rate tables — exponential attacks toward zero attenuation,
linear decay/sustain/release with exact mean tick rates, block-boundary
ADSR transitions, and total-level gains rebuilt through a 2^(-x/64)
decomposition only when the 10-bit attenuation moved. The pass runs from
internal P RAM and its cost is proportional to envelope activity: operators
whose envelope can no longer move retire from the active list, and the
fixture's eight-operator key-on transient, sustained D2R decay tail, and
late release all retire inside the measured window. The 256-block window
amortizes the 32-event fixture at a realistic MXDRV write density instead of
the previous 4x-dense 32-block window. Noise-frequency decode stays outside
this gate.

The current reduction comes from software-pipelining unmodulated operator
stages, pairing feedback accumulation with the next X/Y fetch, sending each
zero-padded host word as one wait-stated longword, and acknowledging an owned
PCM payload before committing its staged YM burst. On the 68030, batch
coalescing uses a generation-tagged register-to-slot map rather than a linear
rescan, while the common one-voice, precached unity-gain PDX path emits directly
to the wire block. These changes preserve the existing checksum and perceptual
oracles; they change scheduling and instruction count, not the synthesis model.

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

## Implementation status

1. **Scaffold (done):** build both CPUs, load/ping/reset, mirror OPM registers,
   and expose the MXDRV `WriteOPM` seam.
2. **Driver foundation and MDX executor (playback path done under emulation):**
   preserve the 32-call table and Trap #4 register-preservation convention,
   own bounded MDX/PDX copies, expose OPM/PCM work buffers, and implement
   reset/play/stop/pause/fade/mask state. Playback now
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
   ownership. The TTP player loads one MDX and an optional PDX override through
   GEMDOS and drains that pump between blocking realtime refills until the
   tracks end or a key is pressed; it does not add a VBL wait to the 20.8 ms
   audio cadence. With no override, it resolves the MDX's embedded PDX basename
   (including the conventional `.PDX` suffix) beside the MDX file.
   Command-tail parsing has a Hatari-covered boundary self-test. FB/FA/F9 now
   use the original algorithm carrier masks and normal/raw attenuation rules,
   with active PDX gain updated in place. Software and hardware modulation
   controls are covered by the conformance and perceptual capture gates.
3. **Operator kernel (done):** KC/KF, DT1, DT2, octave, multiplier, phase
   accumulation, log-sine/power conversion, ADSR, operator mapping, feedback,
   all eight algorithms, panning, and stereo sample generation now run on the
   DSP. The checked attack trace is bit-exact with ymfm at the phase, envelope,
   and rounded-output boundaries; a second sweep covers all eight algorithms
   with operator feedback enabled.
4. **Chip globals (done):** register reset, key edges, pan, YM3012
   10.3-float round-trip behavior, all LFO waveforms, AM/PM modulation,
   channel-7 noise, Timer A/B load/reload/reset/status behavior, CSM keying,
   and the write-busy status bit are implemented.
5. **Falcon audio (production path complete under emulation):** the exact DSP path converts 1280 native
   62.5 kHz samples into 1007 frames at the Falcon's 25.175 MHz / 4 / 128 codec
   rate. Protocol v24 provides the production 512-frame, 32.780 kHz realtime path.
   Both feed 16-bit, two-word SSI network frames from a fast transmit
   interrupt using two aligned external-X buffers. The normal interrupt mutates
   only its dedicated `r6/m6` pair; a separate long exception path reads SSISR
   and writes TX to clear a transmit underrun. The 68030 can fill the inactive
   buffer while the previous complete period continues to loop, and the DSP
   disables the transmit interrupt briefly to switch at a stereo boundary.
   The Hatari gate retains exact A-to-B/B-to-A coverage and now also exercises
   realtime A-to-B and B-to-A refills, real FIFO writes, direct live writes,
   clock progression through 976, 1952, and 2928 native samples, a 1536-frame
   prepared count, deterministic first-buffer output, and clean table/cache
   restoration at stop.

   A reproducible Hatari DSP-cycle gate now supersedes the earlier VBL-derived
   throughput estimate. With four operators active on all eight channels and
   the cached no-PM path selected, rendering one 1280-sample period consumes
   15,707,155 instruction cycles, or 12,271.21 per native sample. The Falcon
   budget is 256.68 cycles per sample, so the exact scalar kernel misses real
   time by 47.81x before steady SSI and host-port overhead. That exact kernel is
   retained as the conformance reference. The production block kernel renders
   eight channels, mixed PDX, decoded controls, block envelopes, and live SSI
   at 346.21 cycles per codec frame against a 489.40-cycle budget. Its relaxed
   boundary is block-rate envelope/LFO evolution and codec-rate synthesis;
   ordered writes split blocks at their first landing frame, and DT1/DT2 plus
   noise-frequency/output substitution are integrated. An embedded second-stage P-memory loader removes the
   former 8 KiB converted-LOD ceiling: a 111-word `Dsp_ExecBoot` program at
   `P:$0040` receives all sparse P sections, acknowledges completion, and enters
   the final program at its replaced reset vector.
6. **PCM/PDX (done under emulation):** raw PDX banks have checked lookup for one
   or more 96-entry tables, bounded to sixteen banks, and eight independent
   streaming MSM6258 decoders. A
   codec-rate host mixer implements the five PCM8 playback clocks with exact
   rational phase accumulation, all 16 two-decibel volume steps, common PCM8
   pan, voice start/stop and active masks, and signed 16-bit saturation. A
   generated oracle checks low-nibble-first decoding, predictor and step state,
   sample exhaustion, malformed bank ranges, and deterministic two-voice mixer
   frames under Hatari. The protocol-v24 player renders 512 PDX frames on the
   host with a voice-major mono block mixer, uploads them with global pan and
   batched YM writes, combines them with the realtime FM kernel, and double-
   buffers the result through Falcon SSI. The
   1007-frame exact integration gate remains as a conformance check. MDX PCM
   notes bind tracks 8-15 to PDX voices 0-7 with encoded durations and default
   rate/gain/pan. The optional local-corpus gate exercises real MDX/PDX pairs
   under Hatari. The TTP player loads an explicit PDX override or resolves the
   embedded MDX PDX
   name, then includes its decoded PCM in every realtime inactive-buffer refill.
   Transport is continuous because the
   previous block repeats if a refill is late; fresh PDX time advances only when
   the next block is prepared.

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
19 codec-rate scenarios for pitch, per-operator DT1/DT2 detune, write/key
timing, ADSR, AM/PM LFO, two-rate noise,
feedback levels 0/7, all eight algorithms, and sustained feedback level 7 on
algorithms 4 and 5. Every row records the exact
1920:1007 native boundary, ordered-write count/hash, stereo output, and
operator/control state. `tools/compare_ym2151_realtime.py` validates that
coverage and accepts future candidate captures using drift/timing, envelope,
LFO/noise-rate, and spectral thresholds documented in
`docs/perceptual-compatibility.md`. This completes the reference and policy
half of the perceptual gate. A second native projection independently applies
the 256-step sine phase, codec-rate feedback, algorithms, panning, noise, and
YM3012 rounding while borrowing exact frame-boundary control state. It passes
with topology spectral cosine of 0.7955-1.0000, log-spectrum RMSE of
1.81-8.64 dB, and energy ratio of 0.984-1.015. The integrated DSP kernel is
captured separately by `make capture-realtime`.

### What the emulator cannot decide

Every gate in this repository runs under Hatari, so it is worth recording where
Hatari's own authors say the model stops being the hardware. These are not
reasons to distrust the gates — the synthesis contracts above are checked
against ymfm, not against Hatari — but they bound which *transport* questions
an emulator run can answer, and they should be read before any future change
to buffering, pacing, or the SSI path.

Hatari's manual calls Falcon emulation "experimental and incomplete", and
lists the crossbar sound matrix itself among its experimental features: the
whole ADC/DAC/DMA/DSP interconnect this player depends on carries that label.
CPU, FPU, MMU and DSP emulation are documented as instruction-wise correct but
not cycle accurate, unlike the 68000 core, and for 68030-to-DSP synchronization
specifically the maintainers state that enabling cache emulation is sometimes
closer to a real machine and sometimes further from it. There is no emulator
setting that makes host/DSP contention authoritative.

Seven specific approximations bear on this design:

- The DSP SSI receive path substitutes one interrupt type for another as an
  acknowledged workaround, because the documented one produced no sound. SSI
  interrupt semantics under emulation are therefore approximated rather than
  modeled, which is the mechanism the transmit interrupt and the A/B switch
  are built on.
- When the DAC receives no data, the crossbar forces its write position ahead
  of the read position. That is invented starvation behavior, so a late refill
  may sound acceptable under Hatari and behave differently on hardware. The
  repeat-last-period design is still the right response to a late refill; it is
  simply untested rather than tested-and-passing.
- Several crossbar registers were reverse-engineered because Atari's
  documentation does not fully describe them, and the Falcon030 Service Guide's
  SOUNDINT/SNDINT description is noted as inaccurate against measured hardware.
  Interrupt-timing conclusions drawn from emulation are weaker than register
  conclusions drawn from the specification.
- The emulator runs peripherals that the hardware leaves unconfigured. `PCC`
  is the proven instance: Port C resets to GPIO, so without `PCC = $1f8` the
  slave SSI has no clock or frame sync on hardware while Hatari plays audio
  normally — see [`dsp56001-notes.md`](dsp56001-notes.md). Assume the same
  shape for every other enable path this player depends on. The 25.175 MHz
  clock restriction and the `Setmontracks` frame-slot pair below are the two
  live candidates: both select *which* hardware path carries the samples, and
  a wrong selection is audible under Hatari and silent on a Falcon.
- Host-side bus bandwidth is not reproduced faithfully. A real 68030 loses a
  mode-dependent share of the bus to the video shifter, and the host budget
  per period — the PDX mix block plus a 524-word paced host-port blast against
  a 20.8 ms period — was measured without that loss. A mode-dependent host
  underrun is a plausible first hardware symptom and is invisible here.
- The external DSP memory decode is taken from the emulator. The `P:$2000`
  and `P:$2b20` islands exist only because external P maps to the 32K SRAM
  directly, external Y onto the same lower 16K word for word, and external X
  onto the upper 16K at `phys = addr + $4000`. That layout packs program into
  the gaps between live data arrays, so a decode that differs on hardware by
  even one region corrupts state rather than failing cleanly. Probe the
  aliasing on hardware before the audio soak, not during it.
- The DSP memory-cost model is a deliberate simplification, but one its author
  states is correct for the Falcon specifically. It is the one place in this
  list where the emulator's number should be trusted for design work; see
  [`dsp56001-notes.md`](dsp56001-notes.md). What was *not* trustworthy was the
  rate at which stock Hatari hands those cycles out: it grants the DSP two per
  emulated 68030 clock twice over, so the emulated DSP56001 runs at 32 MIPS
  against the Falcon's 16, and its host port costs 72-174% of hardware. Both
  are corrected in the DSP-calibrated build the gates now use, and correcting
  them turned the transport from comfortable into marginal; see
  [`hatari-timing.md`](hatari-timing.md).

The practical rule this yields: emulation gates decide synthesis correctness,
register semantics, protocol behavior, and relative cycle cost. Underrun
behavior, refill pacing under real contention, matrix state left by other
programs, and codec-level clipping are hardware-soak questions, and a green
gate is not evidence about any of them. Stated as the recurring pattern:
Hatari is more permissive than the hardware during setup and more forgiving
than the hardware during failure.

### Paths no green gate has ever executed

The approximations above have a corollary worth listing separately, because it
is not about accuracy but about coverage: several code paths in this player
have never run in any passing gate, and will execute for the first time on
hardware.

- **The transmit-underrun recovery ISR** at `P:$0012` reads SSISR and then
  writes TX, the required sequence for clearing TUE. Because Hatari's DAC
  starvation is invented, no gate has ever starved the SSI, so this vector is
  dead code under emulation. Its first real execution will be under interrupt
  at the 65.5 kHz word rate, and a bug there turns one late refill into
  permanent silence rather than a click.
- **The repeat-last-period response to a late refill** is the right design,
  but for the same reason it is untested rather than tested-and-passing.
- **The host-port spins are unbounded.** `dsp_blast_paced` polls TXDE per word
  and RXDF for the reply with no iteration limit, in supervisor mode, from
  `Supexec`. Under Hatari the DSP never stops consuming, so these loops always
  terminate. On hardware any DSP-side stall — a wedged recovery ISR, an
  aborted transfer, a mis-timed refill — becomes a hard hang with no
  diagnostic, which is the shape the missing `PCC` write took on hardware. A
  bounded retry with a printable bail-out costs nothing against 524 words per
  20.8 ms period and converts every bring-up hang into an error message. This
  is a recommended change, not an implemented one.
- **DSP reservation is asymmetric.** The player calls `Dsp_Reserve` (107) and
  `Dsp_ExecBoot` (110), and `Dsp_Unlock` (105) on exit, but never `Dsp_Lock`
  (104). Under Hatari nothing else ever wants the DSP, so the asymmetry is
  free. Confirm it against real TOS 4.02 semantics before a release build,
  particularly with a DSP-using accessory resident.
- **The codec clipping readback has never returned a real value.** `Sndstatus(0)`
  bits 4 and 5 are the only mix-headroom check that measures the converter
  rather than the mix that fed it, and only hardware can move them.
- **Hostile inherited matrix state is not reproducible.** The pinning described
  under [Falcon audio-path constraints](#falcon-audio-path-constraints) can
  only be shown to execute, never to fix anything, until the player is launched
  after something that left the matrix dirty.

## Real-time compatibility contract

The selected Falcon playback target is musical FM compatibility at the
32,779.9479167 Hz codec cadence, with the exact command-clocked kernel retained
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

Protocol v24 satisfies the write-latency clause: the production kernel
splits a block at each queued write's landing frame, draining and decoding
between the segments, so effects land on the first codec frame at or after
their native timestamps. The envelope, AM, LFO, and timer advances keep their
documented block cadence; only register effects split. DT1/DT2 pitch offsets are decoded per operator since the channel pitch rebuild
adopted the exact engine's position and detune semantics, and register $0f is
decoded into channel-7 noise substitution: operator 31's sine mutes while a
once-per-block pass supplies ymfm's linear-attenuation noise volume, resampled
at the decoded frequency. The substitution pass costs about 15 cycles per
frame while noise is enabled — over the budget only in the all-channels-maxed
profile fixture, which therefore clears $0f and leaves the noise-enabled cost
to the capture scenarios and the hardware soak.

## Falcon audio-path constraints

Four properties of the Falcon sound matrix bound the playback path. They come
from the August 1992 Falcon specification, not from emulator behavior, and two
of them are places where Hatari is more permissive than the hardware.

**The internal codec accepts only two of the three master clocks.** The
specification states that the CODEC can use the internal 25.175 MHz or the
external clock; the internal 32 MHz clock is available to the other matrix
devices only. This matters because 32 MHz produces exactly the rates this
engine would most like to have: 32 MHz / 256 / 3 is 41,666.67 Hz, precisely
two thirds of the native 62.5 kHz OPM rate, and 32 MHz / 256 / 4 is half of
it. Either would replace the 1920:1007 DDA with an exact 3:2 or 2:1
decimation. Hatari's crossbar implements the full 32 MHz rate table and mutes
the DAC only for prescale values 6, 8, 10, and 12 or above, so such a change
would pass every gate in this repository and produce nothing on a stock
Falcon. `SOUND_CLK25M` is therefore the only supported production clock, and
the 32.780 kHz cadence is chosen from the 25.175 MHz table. The external-clock
exception is real but requires non-stock hardware: an external 32 MHz
oscillator on the DSP port is codec-legal and would make 41,666.67 Hz
available, against a 385-cycle frame budget that the measured 346.21-cycle
kernel fits. That remains an optional future mode, not a supported
configuration.

**The DAC cannot operate in gated clock mode.** Passing no-handshake to
`Devconnect` is a hardware requirement rather than a tuning choice.

**A frame is eight 16-bit slots, not two.** In continuous clock mode the SSI
ports transfer 128-bit frames carrying eight 16-bit samples, with SYNC high
for the first 16 bits and low for the remaining 96. The two-word `CRA=$4100`
frame and word-length frame sync in `CRB=$5a00` are correct against that
structure: the DSP fills slots 0 and 1 and idles for the rest of the frame.
The consequence is that the DAC's source is a selected pair out of the eight,
chosen by bits 12 and 13 of the sound mode control register. That selection is
a second place where a green gate proves little: if the emulated crossbar
forwards whatever the DSP transmits regardless of the monitor-track pair, a
wrong `Setmontracks` argument is inaudible here and silent on hardware, so the
call is pinned rather than inherited for the same reason as the rest of the
route.

**Matrix state survives across programs.** Play-track count, the monitor track
pair, the 16-bit adder's input selection, DMA playback state, and codec
attenuation are all left behind by whatever ran previously; TOS does not reset
them for a new `Devconnect`. Both the player and the conformance harness
therefore pin the whole route rather than inheriting any of it: `Buffoper(0)`
stops inherited DMA playback that would contend for the same DAC,
`Sndstatus(1)` reinitializes the converters and clears their latched overflow
bits, `Soundcmd` mode 4 restricts the 16-bit adder to the matrix so the A/D
path cannot bleed into the output, `Settracks` and `Setmontracks` fix the
play-track count and point the DAC at frame slots 0 and 1, and `Dsptristate`
couples DSP transmit to the matrix. The player additionally saves and restores
the user's codec attenuation around playback.

None of this can be *proven* under Hatari, which starts from a clean matrix; a
hostile initial state is not reproducible there. The endurance gate therefore
asserts only that the calls still execute, and the hardening's real test is
the hardware soak. On exit the player reads `Sndstatus(0)`, whose bits 4 and 5
report left and right codec clipping, and prints a warning naming the affected
channels. That is a hardware-side check on mix headroom — it measures the
analog converter rather than the mix that fed it — and no emulation gate can
substitute for it.

## Remaining work

The functional port and its emulation gates are complete. The remaining work
is deliberately narrow:

1. **Validate on a physical Falcon.** Confirm the SSI clock/DMA arrangement,
   transmit-underrun recovery, A/B handoff timing, host/DSP contention, and
   long-duration mixed FM/PDX playback at the target machine clock. The
   matrix-state hardening and the codec clipping readback are implemented; the
   soak is what gives them meaning. These are exactly the questions listed as
   out of the emulator's reach under [What the emulator cannot
   decide](#what-the-emulator-cannot-decide), so plan the soak to observe
   them deliberately rather than to confirm that playback starts.

   Run the steps in this order, so that a failure identifies which
   approximation it came from rather than merely stopping the soak:

   1. **Aliasing probe, before any audio.** Write a pattern through
      `Y:$2000`, read it back through `P:$2000` and `X:$6000`, and confirm the
      decode exactly. Everything else assumes the program islands do not
      overlap live data.
   2. **Boot with the verbose markers.** Confirm progress past `PCC`,
      `Dsptristate` and `Devconnect`, then past the payload-sent and reply
      markers, which separate "stopped consuming mid-block" from "took the
      block and never replied".
   3. **Induce a late refill deliberately** by stalling the host pump for one
      period, and observe whether the recovery ISR and the repeat-last-period
      response behave, rather than hoping they never run.
   4. **Long mixed FM/PDX playback in at least two video modes**, watching for
      a mode-dependent underrun that would indicate the host budget rather
      than the DSP budget is the binding constraint.
   5. **Read `Sndstatus(0)` at exit** on the loudest corpus material, to give
      the clipping check its first real measurement.
   6. **Launch after a DMA-playing program** without an intervening reset, to
      exercise the matrix pinning against a genuinely dirty initial state.
2. **Finish public API compatibility.** Complete the unsupported and state-only
   calls listed in [`mxdrv-api.md`](mxdrv-api.md), then tighten edge-case error
   semantics beyond the exercised MDX/PDX playback path.
3. **Package a release.** Document the tested Falcon configuration, provide
   the final distribution layout, and repeat the hardware soak against that
   packaged build.
