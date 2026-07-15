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

Protocol v12 implements the event shape with a rolling clock. A refillable
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
audio buffers, and the reply is that block's checksum (`$27d93b`), gated by
the smoke suite.

The optimized loop splits feedback history across internal X/Y memory so it
can fetch and update both words with the modulator ring, prefetches the next
ring word beside each modulated-stage `MPY`, transfers that word into `A` while
storing the previous result, and overlaps the carrier's left output store with
its right-pan shift. A `$ff` address mask keeps every indexed read inside the
DSP56001's factory 256-step signed sine ROM at `Y:$0100-$01ff`; the same value
is the phase MAC operand. Its rounded `$9330` multiplicand is five parts per
million low, so one `$60000` low-word correction after the 2,048-frame profile
block restores exact boundary phase while the intermediate error stays below
0.012 ROM step. Command setup temporarily enables that ROM, then restores the
external map and rebuilds the cache words overlaid by the 48-bit spike state.

Hatari measures 83,451 instruction cycles for the block, or 40.75 cycles per
channel/frame — a 1.04x surcharge over the 39.16-cycle four-carrier floor for
feedback, serial modulation, masking, stereo stores, and block overhead. This
is 32.2% below the first 60.10-cycle implementation. The linear eight-channel
projection is 325.98 cycles against the 326.27-cycle codec-frame budget, a
bare 0.09% synthesis margin. Envelope evolution, LFO/noise, queued-write,
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
24.66 cycles (7.56%) of synthesis headroom. This is 7.48% cheaper than the
fully serial algorithm-0 shape and establishes useful carrier-specialization
headroom, but still excludes envelope, LFO/noise, queued-write, SSI, and event
service. Algorithms 1-6 need their own mixtures of the measured serial and
carrier stage shapes before integration.

## Embedded second-stage program loader

The 68030 executable now embeds both a 111-word first-stage boot image and the
sparse final P-memory image. XBIOS `Dsp_ExecBoot` resets the DSP and installs
the first stage in internal P RAM. Its reset vector jumps to `P:$0040`; the
final YM program deliberately begins at `P:$0080`, leaving
`P:$0040-$007f` untouched while the loader receives the complete program
through `Dsp_BlkUnpacked`.

The generated stream starts with magic `$4d584c`, followed by a section count
and address/count/data records. The current program contains 3,044 initialized
words in five sparse P sections. After installing them, the loader replies
`$4c4f41` and jumps through the replaced reset vector at `P:$0000`. The build
generator rejects a bootstrap above the 512-word XBIOS limit, any overlap with
the reserved loader gap or `P:$0c80` table boundary, non-P sections, and
sections outside 16-bit P memory.
This removes the former 8 KiB converted-LOD ceiling from future specialized or
unrolled kernels; the actual Falcon P-memory reservation is now the relevant
limit.
