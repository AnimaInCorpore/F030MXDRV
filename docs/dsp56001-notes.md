# DSP56001 implementation notes

The local `docs/DSP56001_um.pdf` is the architectural reference for the DSP
side. The current DSP core relies on these specific rules from the Motorola
DSP56000/DSP56001 User's Manual.

## Numeric representation

Section 4.2, “Data Representation and Rounding” (manual pages 4-9 onward),
defines data-ALU words as signed 24-bit fractional values with the binary point
left justified. The same bit patterns can be manipulated as small integers with
logical shifts and adds, as the current synthesis kernel does, but future use of
`MPY`/`MAC`, scaling mode, rounding, or accumulator limiting must account for
the fractional alignment explicitly. Generated ymfm lookup values are emitted
as raw 24-bit words rather than silently rescaled constants.

## Address-generation pipeline

Section 8.1, pipeline Case 2 (manual page 8-2), states that an indirect address
is formed before the preceding `MOVE` has finished writing its `Rn` register.
One independent instruction cycle is required between writing `Rn` and using
it for an indirect memory access. The same scheduling discipline is used for
the `Nn` offsets in `src/dsp/ym2151.asm`. Where there is no useful independent
instruction, the core inserts a `NOP` before `x:(Rn+Nn)` or `y:(Rn+Nn)`.

Indexed and post-update addressing only pair same-numbered registers:
`(Rn+Nn)` and `(Rn)+Nn` exist, but `(R7+N5)` does not assemble. Address
arithmetic also always applies the pointer's own `Mn` modifier, so an indexed
access through a modulo pointer must keep base plus offset inside one modulo
block. Both rules shaped the decoded-control state layout of protocol
command `$17`: its per-operator arrays are operator-major so the channel's
feedback pointer can index them, and its modulo-sensitive tables are placed
so a stride-8 walk never leaves a 64-word block.

## Hardware loops

The `DO` instruction description (manual pages A-63 through A-65) confirms that
the loop has no per-iteration overhead, but a count of zero means 65,536
iterations rather than zero. Variable-count loops in the synthesis kernel
therefore branch around `DO` when the count can be zero. Section 8.1.2 (manual pages 8-6
onward) also lists instructions forbidden near a loop end; loop bodies here are
kept to simple ALU or memory moves and are checked by Motorola ASM56000.

These constraints are part of correctness, not just optimization: violating
either the address delay or zero-count behavior produces valid assembly with
incorrect chip state at runtime.

## First synthesis hot-path pass

Deriving one OPM phase increment includes key-code gap removal, DT1/DT2 table
access, octave shifting, multiplier handling, and PM sensitivity. Repeating
that static work for all 32 operators on every sample dominated the initial
correctness-oriented kernel. The DSP now caches the no-PM increments and
rebuilds them after writes to the register groups that can contain KC/KF,
DT1/MUL, or DT2. The same rebuild pass stores five PM-independent words per
operator in internal `Y:$0000` — gap-removed position including DT2, raw
block, channel PM sensitivity, signed DT1 delta, and doubled multiplier — so
a non-zero per-sample LFO PM value now costs only the PM shift, boundary
adjustment, one table read, the octave shift, and one `MPY` per operator
instead of the complete register decode. The `tests/traces/vibrato_pm.trace`
fixture pins this dynamic path to exact ymfm output at maximum saw-LFO rate,
PM depth, and PMS.

The 32-word cache starts at internal `Y:$0100`. This keeps phase in X and its
increment in Y, allowing one parallel fetch followed by add/store: three
instructions per operator in the common no-PM path. It also avoids external
`Y:$0200`, which overlaps the external program address range under the Falcon
memory reservation used by this executable. The output path separately skips
four-operator evaluation when all four envelopes are `$3ff`, while explicitly
clocking that channel's next feedback input to zero. Released envelopes already
at `$3ff` bypass rate derivation until a later key-on makes them active again.
Phase, key edges, feedback history, LFO/noise, and timers continue to clock.

Frequently accessed scalar state now occupies internal `X:$0000-$0041`.
Short-address loads and stores remove an extension word and avoid external RAM;
this reduced the initialized loader payload from 8,100 to 7,113 bytes before
adding the FIFO and audio transport. The buffered-audio image later reached 8,082
bytes, which motivated the second-stage loader described below rather than
making code size part of the synthesis contract.

## Falcon SSI interrupt-buffered mixed path

The audio path configures SSI control A as `$4100`: 16-bit words and two words
per synchronous network frame. Control B is `$5a00`: synchronous network mode,
transmit enabled, and transmit interrupts enabled, while serial clock and
transmit frame sync remain crossbar inputs. SSI priority is level 2 through IPR
`$3000`. Each signed 16-bit YM sample is shifted into the upper 16 bits of the
DSP's 24-bit transmit register.

The normal SSI transmit vector at `P:$0010` is a two-instruction fast interrupt:
it moves `X:(r6)+` to TX and returns through the implicit fast-interrupt path.
The dedicated `r6/m6` pair is not used by synthesis, so refills can be
interrupted without saving ALU state or disturbing a hardware `DO` loop. The
transmit-exception vector at `P:$0012` is a long interrupt that reads SSISR and
then writes TX, the required sequence for clearing TUE. It is a recovery path,
not part of normal block playback.

The Falcon DAC rate selected by the host is 25.175 MHz divided by 4 and 128,
or 49,169.921875 Hz. Relative to the native 62,500 Hz OPM rate this is exactly
`1280/1007`, so the staging renderer advances one or two native samples per
codec frame and stores the latest result. Each 1007-frame block uses 2014
interleaved stereo words. Buffer A starts at external `X:$1000`, buffer B at
`X:$1800`; both are 2048-word aligned so `m6=2013` wraps each non-power-of-two
block correctly. They are uninitialized storage, add no `.LOD` records, and
both fit below the 8192-word external-X reservation.

Protocol command `$11` receives 1007 interleaved signed stereo frames rendered
by the 68030 PDX mixer. The DSP renders the matching FM period, adds and clamps
each channel to signed 16-bit, then starts interrupt-fed playback from buffer A.
Command `$13` selects the inactive buffer with `r7`, receives and mixes the next
period there while `r6` keeps the active block repeating, then switches only
after a complete stereo pair. The switch clears TIE while retaining transmit,
waits for TDE, supplies a matching right word if the active pointer is between
channels, preloads the new block's first left word, and restores `$5a00`.
Buffer pointers use `r6/r7`; the phase-cache loop owns `r4`, so sharing that
register would displace the refill position during every YM sample.

Protocol v17 implements the event shape with a rolling clock. A refillable
32-entry ring FIFO stores an absolute 16-bit native-sample time beside each
packed register write. Entries must be in nondecreasing modular order and
within the 32,767-sample future horizon; all writes due at a boundary are
applied before clocking that YM sample. FIFO and clock-query transactions are
serviced while SSI is active, and the clock continues across refills instead of
restarting at zero.

## Cycle feasibility gate

The Falcon DSP oscillator measured by Hatari is 32,084,988 Hz. One DSP56001
instruction cycle is two oscillator clocks, leaving about 256.68 instruction
cycles for each native 62.5 kHz YM sample. `make profile-dsp` arms Hatari's DSP
profiler on a unique host-port marker, then measures command `$0b` from entry
through completion of the first 1280-native-sample render. Listing symbols are
resolved mechanically, and the generated report is written to
`build/dsp-profile/report.txt`.

The deterministic fixture enables a sustained four-operator algorithm-7 voice
on all eight channels and deliberately uses the cached no-PM phase path. Hatari
2.6.1 reports 30,782,302 oscillator clocks, or 15,391,151 instruction cycles,
for the block. That is 12,024.34 instruction cycles per native sample and
959.40 ms of modeled DSP time for audio consumed in 20.48 ms: a 46.85x
real-time miss. The profile window does not include steady SSI interrupt or
host-port service overhead, and a PM-modulated workload can only be more
expensive. This replaces the earlier 8.6x estimate derived indirectly from a
VBL throughput test.

The result makes full-rate, ymfm-equivalent output from the current scalar
kernel an untenable optimization target. The exact kernel remains useful as a
conformance model, but a real-time Falcon renderer now requires an explicit
compromise in output accuracy, synthesis rate, supported workload, or target
hardware. Real Falcon cycle and underrun measurements are still required to
validate transport behavior, but plausible emulator timing error cannot close
a nearly 47x gap.

### Codec-rate lower-bound spike

`make profile-dsp-rt` brackets protocol command `$10` between
`rt_profile_loop_start` and `rt_profile_loop_done` and writes the independent
report to `build/dsp-profile-rt/report.txt`. The command clocks 2,048 frames of
one four-operator channel at the 49,169.921875 Hz codec cadence. Each oscillator
retains a 16-bit fractional phase in an aligned internal-X modulo-4 ring while
`r0-r3` retain the integer positions in the DSP56001's on-chip 256-entry sine
ROM at `Y:$0100-$01ff`. Fractional carry advances each integer pointer without
long-term pitch drift.

The optimized loop keeps four static gains in internal X, so each phase mask
dual-fetches sine and gain while the following `MAC` overlaps its phase-ring
store. Hatari reports 80,208 instruction cycles, or 39.16 cycles per
channel/frame. A linear eight-channel pass is 313.31 cycles against the
measured 326.27-cycle codec-frame budget, leaving only 12.96 cycles (4.0%).
The four distinct gain multipliers exercise the carrier floor; the checksum is
`$6c679b` and the normal smoke suite checks it. Command cleanup unmaps the ROM
and rebuilds the exact-renderer phase cache outside the measured bracket.

This is deliberately a strict floor: it omits envelope evolution,
feedback, modulation routing, LFO/noise, write-event service, panning, SSI, and
PDX/FM saturation. Consequently the result does not establish that a complete
scalar engine fits. It establishes that drift-free oscillator/table arithmetic
is viable only when organized around DSP parallel moves. The next feasibility
kernel must be block-oriented and specialized by YM algorithm, allowing gain,
modulation, carrier accumulation, and buffer traffic to share those parallel
memory slots; a generic feature-by-feature extension of this loop has no
credible cycle margin.

### Algorithm-0 block spike

`make profile-dsp-rt2` brackets protocol command `$14` between
`rt2_profile_loop_start` and `rt2_profile_loop_done` and writes its report to
`build/dsp-profile-rt2/report.txt`. The command renders one serial
M1(feedback)->C1->M2->C2 channel for 2048 codec frames in operator-major
64-frame blocks: each stage keeps its phase in a 48-bit accumulator, writes a
64-word internal-X modulator ring, and the next stage consumes that ring in
place. Feedback and modulation are applied on every frame; operator gains are
held for each block and envelope evolution is deliberately outside this
synthesis-only spike. The carrier writes interleaved stereo into the reused
audio buffers, and the reply is that block's checksum (`$0f2666`), gated by
the smoke suite.

The optimized loop stores feedback history across internal X/Y memory at its
already-divided 1/8 table-index depth, so both words load together and their
sum feeds the phase without three hot-loop shifts. It fetches and updates both
words with the modulator ring, prefetches the next
ring word beside each modulated-stage `MPY`, transfers that word into `A` while
storing the previous result, and overlaps the carrier's left output store with
its right-pan shift. A `$ff` address mask keeps every indexed read inside the
DSP56001's factory 256-step signed sine ROM at `Y:$0100-$01ff`; the same value
is the phase MAC operand. Its rounded `$9330` multiplicand is five parts per
million low, so one `$60000` low-word correction after the 2,048-frame profile
block restores exact boundary phase while the intermediate error stays below
0.012 ROM step. Command setup temporarily enables that ROM, then restores the
external map and rebuilds the cache words overlaid by the 48-bit spike state.

Hatari measures 77,307 instruction cycles for the block, or 37.75 cycles per
channel/frame. This is 37.2% below the first 60.10-cycle implementation and
1.41 cycles below the generic 39.16-cycle four-carrier floor because the block
stages eliminate fractional-ring traffic from every operator. The linear
eight-channel projection is 301.98 cycles against the 326.27-cycle codec-frame
budget, leaving 24.29 cycles (7.44%) of synthesis margin. Envelope evolution,
LFO/noise, queued-write,
SSI, and event-service costs are still absent, so this closes the arithmetic
spike gap rather than proving an integrated real-time renderer.

### Algorithm-7 carrier spike

`make profile-dsp-rt3` brackets protocol command `$15` between
`rt3_profile_loop_start` and `rt3_profile_loop_done` and writes
`build/dsp-profile-rt3/report.txt`. It shares command `$14`'s ROM mapping,
48-bit DDA, feedback history, block size, output buffers, correction, and
cleanup, but routes all four operators as carriers. Operator 1 stores its
feedback pre-scaled by 1/8, preserving the serial spike's feedback depth while
placing a separate half-amplitude carrier in the accumulation ring.

Operators 2-4 have no incoming modulation, so each masks `B` directly and
preloads the current ring word beside that mask. A following `MAC` adds the
sine/gain product in place, eliminating a separate `MPY` and `ADD` from each
carrier stage; operator 4 overlaps the left output store with the right-pan
shift. The four gains sum to 0.9375 at aligned phase, keeping the unsaturated
test vector inside signed full scale. The deterministic reply is `$89eb00`.

Hatari measures 77,211 instruction cycles, or 37.70 cycles per channel/frame.
The linear eight-channel projection is 301.61 cycles per codec frame, leaving
24.66 cycles (7.56%) of synthesis headroom. This is 0.13% cheaper than the
optimized fully serial algorithm-0 shape and establishes useful
carrier-specialization headroom, but still excludes envelope, LFO/noise,
queued-write, SSI, and event service.

### Algorithms 1-6 mixed-topology spikes

`make profile-dsp-rt4` captures protocol command `$16` once for each selector
1-6 and writes the reports below
`build/dsp-profile-rt4/algorithm-*/report.txt`. The six outer loops compose
shared feedback, serial-modulator, independent-carrier, carrier-accumulation,
and stereo-output stages while retaining separate listing symbols for Hatari's
cycle brackets. Their deterministic replies are checked by the normal smoke
test.

Operator 1 stores its output at the already-divided 1/8 feedback depth. That
keeps the same feedback strength as the three shifts in command `$14`, removes
those shifts from every mixed-topology frame, and still gives later operators
non-zero table-index modulation. Algorithms 1-3 use one internal-X ring for
their fan-in paths. Algorithms 4 and 5 instead preserve reusable modulation in
the internal-Y ring at `Y:$00c0-$00ff` and accumulate carriers in internal X.
After the modulated phase selects a sine entry, the phase `MAC` preloads the X
carrier accumulation before the indexed Y sine-ROM read, avoiding the Y/Y
memory conflict in the first dual-branch implementation. Algorithm 6 reuses
the direct X carrier-accumulation stage from command `$15` after its one serial
branch.

| Algorithm | Channel cycles/frame | Eight-channel projection | Synthesis headroom |
| --- | ---: | ---: | ---: |
| 1 | 37.00 | 295.99 | 9.28% |
| 2 | 37.98 | 303.87 | 6.87% |
| 3 | 37.00 | 295.99 | 9.28% |
| 4 | 38.00 | 303.99 | 6.83% |
| 5 | 39.05 | 312.37 | 4.26% |
| 6 | 35.98 | 287.86 | 11.77% |

All six mixed topologies fit their linear eight-channel synthesis projection.
After algorithm 0's scaled-feedback optimization, algorithm 5 is the overall
isolated worst case at 39.05 cycles and leaves 4.26%. These are still
synthesis-only results: block-rate envelope work, LFO/noise, queued writes,
SSI, saturation, and event service are not included.

### Live-SSI eight-channel fully decoded control gate

`make profile-dsp-rt5` brackets protocol command `$17` between
`rt5_profile_loop_start` and `rt5_profile_loop_done` and writes
`build/dsp-profile-rt5/report.txt`. It is the first profile to execute eight
channels, one for each algorithm, rather than projecting one channel linearly.
The sine ROM
moves to `r0`, leaving `r6/m6` exclusively owned by the real two-word SSI fast
interrupt while buffer A loops. Thirty-two long phases and eight feedback
pairs overlay the exact renderer's internal cache/scratch range at
`L:$0054-$007b`; the cache is rebuilt before returning to the command loop.
Both-output carriers reuse the internal-Y algorithm-4/5 branch ring. Left-only
and right-only carriers accumulate into host-prepared planar PDX streams in
external X/Y memory, which the final pass combines with the common ring and
interleaves into the inactive SSI buffer. All profile arrays remain inside
Falcon's 8,192-word X/Y reservations. The right stream temporarily overlays
external-Y table storage, so the packed table is backed up in X and expanded
again before the exact renderer resumes.

Each 64-frame block services one ordered write from a profile-local FIFO,
advances the drift-free 1280:1007 native clock, a decoded-rate LFO, both
decoded timers, and a maximum-length one-step-per-frame noise LFSR, then runs
one three-instruction, 32-iteration loop that advances every decoded
per-operator envelope level by its decoded step while rebuilding every
PM-adjusted per-operator phase increment. Pitch state is operator-major
(slot = operator * 8 + channel), so each algorithm body preloads its stages'
increments through the channel's feedback pointer as `y:(r2+n2)` beside the
existing `x:(r7+n7)` gain preload, and the channel-control read rides the
parallel Y-bank feedback pointer through `(r4+n4)`. The 32-event fixture
covers every decoded register class: eight `$20-$27` algorithm/pan rewrites,
five four-band total-level writes, four KC and two KF events that rebuild
four base increments from the exact expanded `opm_phase_step` table with
octave shift and doubled per-operator multiplier, four key on/off events
rewriting decoded envelope levels and slopes, one write from each of the
four envelope-rate groups translated through the raw-slot map into signed
class-shifted steps, LFO rate/depth/waveform writes, and Timer B plus timer
control load/run/status handling. The scaled `$19` PM depth multiplies the
low eight control bits into this block's signed increment offset, and
control bit 16 still selects full or 0.75 AM gain in all four stages.
Full-accumulator moves invoke the DSP56001 limiter only after the complete
mix. The exact 64-step Galois noise transform is applied through three
6/6/5-bit slice tables that command setup derives from the x^17+x^14+1 step
function itself — 17 single-bit columns advanced 64 steps, then a doubling
fill — so no noise-table words occupy the bounded P-memory image. Cleanup
disables SSI, reads SSISR and writes TX to clear a latched underrun,
restores the external Y map, and rebuilds the exact phase cache, including
the internal-Y frequency-cache words the decoded step/increment arrays
overlay. The deterministic reply is `$791bf5`.

Hatari measures 664,666 instruction cycles for 2,048 frames, or 324.54 cycles
per frame against the 326.27-cycle budget. The 41.43 ms modeled block fits
its 41.65 ms period with 1.73 cycles/frame (0.53%) remaining. Every decoded
register class the real transport must apply now executes inside the budget
beside live SSI, planar PDX mixing, and saturation, establishing full
control feasibility for the fixture workload. The write-first common-ring
pass has been spent: the block's first both-panned carrier stores instead of
accumulating, the rare unwritten ring is cleared once at emission, and both
write variants keep full-accumulator limiter moves so the checksum gate
proves the output bit-identical. Recovering the lever cost P-memory pressure:
the key-event decode became a four-iteration mask-shift loop, the fixed
timer-register reads use absolute addressing, and the program now ends two
words below the P:$1400 table boundary. Noise-frequency decode plus
per-frame-accurate envelope curvature remain outside this gate.

## Embedded second-stage program loader

The 68030 executable now embeds both a 111-word first-stage boot image and the
sparse final P-memory image. XBIOS `Dsp_ExecBoot` resets the DSP and installs
the first stage in internal P RAM. Its reset vector jumps to `P:$0040`; the
final YM program deliberately begins at `P:$0080`, leaving
`P:$0040-$007f` untouched while the loader receives the complete program
through `Dsp_BlkUnpacked`.

The generated stream starts with magic `$4d584c`, followed by a section count
and address/count/data records. The current program ends two words below the
P:$1400 table boundary; the decoded-control gate fits only because its fixture
data moved into P `dc` tables, the noise jump tables are derived at runtime,
and the write-first mix-ring change repaid its new loops with the key-event
and timer-decode word reclaims. After installing them, the loader replies
`$4c4f41` and jumps through the replaced reset vector at `P:$0000`. The build
generator rejects a bootstrap above the 512-word XBIOS limit, any overlap with
the reserved loader gap or `P:$1400` table boundary, non-P sections, and
sections outside 16-bit P memory.
This removes the former 8 KiB converted-LOD ceiling from future specialized or
unrolled kernels; the actual Falcon P-memory reservation is now the relevant
limit.
