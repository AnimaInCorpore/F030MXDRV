# F030MXDRV

**Sharp X68000 music on an Atari Falcon — with the Yamaha YM2151 emulated,
bit-exact, on the Falcon's own DSP.**

F030MXDRV is a native Atari Falcon port/recreation of MXDRV 2.06+17, the
X68000's canonical MDX/PDX music driver. The Falcon 68030 runs the
MXDRV-compatible driver and timing, the Falcon DSP56001 emulates the X68000's
Yamaha YM2151 (OPM), and the Falcon crossbar/codec receives the stereo result.

To our knowledge this is a world first: a register- and sample-exact YM2151
running on the Falcon's DSP56001, verified against MAME's ymfm down to
individual stereo samples — surrounded by the complete MXDRV call-table,
a bounded MDX executor, X68000-exact MSM6258 ADPCM (PDX) decoding, and
interrupt-fed DAC transport, all on stock Falcon hardware.

## Highlights

- **Bit-exact OPM synthesis on the DSP56001.** Phase accumulation, ADSR
  envelopes, logarithmic sine/power lookup, operator feedback, all eight
  algorithms, panning, and YM3012 output rounding — every table and expected
  sample generated mechanically from the vendored ymfm implementation.
- **The whole chip, not just the tone path.** All four LFO waveforms, AM/PM
  depth and sensitivity, operator AM gating, the channel-7 noise generator,
  Timer A/B status and reload semantics, CSM keying, and the 64-clock busy
  flag.
- **A real MXDRV, not a shim.** The original 32-entry call-table shape, owned
  MDX/PDX buffers, an `OPMBuf`-compatible mirror, a DSP-backed `WriteOPM`,
  and a bounded standard-file MDX executor covering 9- and 16-track headers,
  voice loading, tempo and raw OPM writes, FM key-on/off, F6/F5 repeats with
  the original mutable in-stream counter layout, F4 final-pass escapes, and
  PCM tracks 8–15 mapped to eight PDX voices.
- **X68000-exact ADPCM.** Validated 96-entry PDX sample lookup and eight
  streaming decoder voices matching the MSM6258 predictor, step, clamping,
  and nibble order, with all five playback rates, 16 volume steps, hardware
  pan, and saturating stereo mixing at the Falcon codec cadence.
- **Continuous DAC transport.** The DSP SSI transmit interrupt replays exact
  1280-native-sample/1007-codec-frame resampling periods through 16-bit SSI
  at 49.17 kHz into the Falcon DAC, double-buffered, with timestamped YM
  register events on a rolling native-sample clock that survives refills.
- **Verified, measured, reproducible.** A native ymfm oracle, golden
  tone/noise/CSM/vibrato traces, a Hatari integration smoke test, and five
  base profiles plus six algorithm-specific DSP cycle profiles gate every
  change.

## Honest status

This is not a finished music driver yet — and the numbers below are exactly
why the project publishes its own profiler.

- The command-line player now feeds FM and PDX through the codec-rate
  real-time kernel in sixteen 64-frame blocks per 1024-frame A/B buffer.
  SSI keeps the last complete buffer looping during a refill; Hatari gates
  both refill directions, a nonzero first-buffer checksum, and drift-free
  native-clock checkpoints at 1301, 2603, and 3904 samples.
- The exact kernel measures **12,024.34 instruction cycles per native
  62.5 kHz sample** against the Falcon's **256.68-cycle** budget — a 46.85x
  real-time miss (down from 50.10x before the current optimization pass).
  It is kept as the conformance reference.
- The selected real-time target is a perceptual codec-rate FM kernel with
  exact write ordering, register semantics, and drift-free pitch/control
  timing, rather than sample equality. A first codec-rate feasibility kernel
  advances four drift-free oscillators in 39.16 cycles per codec frame using
  modulo rings and parallel X/Y moves. A second, block-oriented spike now
  renders a complete serial algorithm-0 channel — operator-1 feedback,
  per-frame modulation, block-held operator gains, and interleaved stereo —
  in 37.75 cycles per codec frame after storing feedback at its already-scaled
  depth. Its linear eight-channel synthesis projection is 301.98 cycles
  against the 326.27-cycle frame budget, leaving **7.44%** before support
  work. A new
  algorithm-7-shaped spike preloads carrier accumulation beside its phase
  masks and reaches 37.70 cycles per frame, projecting to 301.61 cycles and
  **7.56%** synthesis headroom for four-carrier channels. The six remaining
  mixed topologies now measure 35.98–39.05 cycles per channel/frame; their
  worst case is algorithm 5 at 312.37 projected cycles, leaving **4.26%**.
  A bounded accumulator DDA feeds the DSP56001's on-chip 256-step sine ROM and
  preserves exact profile-block-boundary phase. All isolated topology
  arithmetic now fits. The first integrated serial stress profile reserves
  `r6` for live SSI, executes all eight channels from internal phase state,
  advances block-held envelopes plus drift-free LFO/noise/timer state, services
  32 queued writes, and emits stereo. Moving its hot phase/feedback state and
  carrier sum on chip, batching exact block-boundary LFO/timer bookkeeping,
  and retaining exact noise boundary state first reduced that gate to 313.35
  cycles per frame. It now routes a both/left/right/mute channel pattern into
  host-prepared planar PDX blocks and uses the DSP56001 limiter for the final
  interleaved SSI output. The integrated gate now decodes and applies the
  **complete profiled control set**: `$20-$27` algorithm/pan,
  four-band total level, KC/KF pitch rebuilds from the exact phase-step
  table with octave shift and per-operator multipliers, key on/off, all four
  envelope-rate groups, LFO rate/depth/waveform, and both timers — plus
  **decoded envelope curvature**: envelope-active operators advance by
  composed full-block affine steps from ymfm-derived per-rate tables, with
  exponential attacks, block-boundary ADSR transitions,
  activity-proportional retirement, and total-level gains rebuilt through a
  2^(-x/64) decomposition only when the 10-bit attenuation moved. The
  envelope pass runs from internal P RAM while the amortized decode helpers
  and tables live in a program island at P:$2000, inside physically free
  RAM that Falcon's external P/Y aliasing exposes above the Y reservation.
  The exact 64-step noise transform runs through slice tables the DSP
  derives from the LFSR step function at setup. Boundary service drains
  every due FIFO write, and the fixture covers a seven-event burst, empty
  boundaries, an eight-operator key-on transient that decays and retires,
  a sustained decay tail, and a late release. Over the 128-block profile
  the gate measures **320.24 cycles per frame** against the
  **326.27-cycle** budget — full decoded control plus envelope curvature
  fit with **6.03 cycles (1.85%)** to spare, and the prototype scores the
  same block recurrence at MAE 2.99/1023, correlation 0.977, and 61-frame
  transition lag against the exact ADSR reference, inside every comparator
  boundary. Protocol v19 promotes this state into the production player: it
  imports the current register/key image, consumes the real rolling FIFO,
  applies direct live writes (including multiplier changes), mixes planar
  PDX, renders the inactive 1024-frame buffer, and restores the exact tables
  on stop. `make capture-realtime` replays all 15 perceptual scenarios
  through that production stream in Hatari and gates the reconstructed
  vectors. The realtime pitch conversion is exact — **0.009 ppm drift,
  at most 7 counts of phase error** — serial modulation runs at ymfm's
  decoded out>>1 depth through role-scaled gains, and pitch, timing,
  noise, algorithms 0-3, feedback-7, and — with true block AM from a
  48-bit LFO accumulator — **the complete LFO gate (spectral cosine
  0.9973)** pass at 320.63 cycles/frame. The measured remaining kernel
  work: per-level feedback depth — measured impossible without a render
  restructure; the parametric model sweep and the impossibility record
  live in docs/perceptual-compatibility.md — plus the feedback-0
  discrepancy, DT1/DT2, noise-frequency/output substitution, and
  sub-block event splitting.
- MDX synchronization/modulation, remaining command behavior, real-hardware
  contention measurement, and the compatibility corpus remain. The exact
  boundary between implemented and pending work is kept in
  [the architecture notes](docs/architecture.md).

## How it fits together

- The 68030 executable embeds everything the DSP needs: packed immutable
  ymfm tables, plus the complete sparse DSP program behind a 111-word
  `Dsp_ExecBoot` first stage that receives 6,584 initialized P-memory words
  through the host port — removing the 8 KiB converted-LOD ceiling.
- The DSP kernel caches all 32 unmodulated phase increments across register
  writes in internal Y RAM and advances them with parallel X/Y fetches.
  Samples with non-zero phase modulation combine cached per-operator
  frequency data with the live LFO value instead of re-decoding registers.
  Terminal release envelopes and fully silent channels bypass work that
  cannot affect chip state or output; hot scalar state lives in
  short-addressable internal X RAM.
- Protocol v19 retains the exact 1007-frame conformance transport and adds a
  1024-frame production transport aligned to sixteen 64-frame synthesis
  blocks. The 68030 uploads interleaved PDX, the DSP expands it to planar
  accumulators, renders FM into the inactive interleaved SSI buffer, switches
  at a stereo boundary, and leaves the last complete block repeating if a
  refill misses a codec period. A refillable 32-entry ring FIFO carries
  ordered register events with native-sample timestamps while SSI runs.
- A guarded timer-service entry reports exact YM Timer-B periods in native
  sample units; public play connects it to an otherwise-idle MFP Timer A
  whose 1024 Hz ISR only accumulates ticks, with a foreground pump doing the
  XBIOS/DSP work. Every exit path restores MFP, DSP SSI, crossbar, and
  sound-lock ownership.

## Build

The repository uses the same tools bundled with `third_party/f030dsp3d`:

- vasm/vlink are bootstrapped from its source archives;
- Motorola's DSP assembler and `CLDLOD` run under DOSBox Staging (or DOSBox).

```sh
make check
```

This also compiles a native MAME/ymfm oracle, mechanically generates
compressed DSP lookup tables, emits the exact 256-sample conformance trace,
validates a 15-scenario codec-rate perceptual corpus, and gates an independent
256-step/codec-feedback projection against it under `build/reference/`.

## Verify

When Hatari is installed, the non-interactive integration smoke test boots
TOS 4.02, loads the DSP program, and verifies ping/reset/register-write
traffic, the MXDRV `OPMBuf` seam, an exact phase step, envelope state, stereo
sample checkpoints, and all eight algorithms with feedback against ymfm,
including signed YM3012 rounding. It also checks busy/status, a deterministic
LFO boundary, a maximum-depth saw-vibrato sample through the dynamic PM path,
channel-7 noise output, Timer A/B boundaries and status reset/cancel, and a
timer-driven CSM key sample:

```sh
make smoke
```

The same run verifies standard PDX lookup bounds, empty and malformed
entries, exact MSM6258 samples, a generated two-voice rate/gain/pan mixer
vector, a complete host-rendered PCM period mixed by the DSP, sound locking,
DSP-to-DAC matrix setup, interrupt-fed A/B buffer refills, rolling-clock FIFO
writes during both refill directions, three seconds of safe block repetition,
and clean teardown. It also copies a standard 16-track MDX fixture through the
public API, covering FM voice loading, FF/FE writes, note duration/key-off, a
timed track-8 PDX trigger, two-pass F6/F5 repetition, F4 final-pass escape,
Timer-B period changes, rejection of an out-of-range repeat target, and timer
release on stop.

The perceptual corpus covers pitch, non-codec-aligned key and register writes,
ADSR state, AM/PM LFO and noise rates, feedback spectra, and all eight
algorithms. Its native projection independently renders the proposed
256-step, codec-rate-feedback compromise; across the topology suite it retains
0.7229-0.9999 spectral cosine and 0.967-1.028x RMS energy with zero control
drift. The production DSP kernel is captured and checked against the same
explicit rate, timing, envelope, and spectral limits with:

```sh
make capture-realtime
```

which replays every scenario in Hatari, dumps block-boundary DSP state,
reconstructs the per-frame vectors, and runs the comparator (equivalently,
`make compare-realtime REALTIME_CANDIDATE_DIR=path/to/capture` gates an
existing capture directory).

The vector schema and thresholds are documented in
[`docs/perceptual-compatibility.md`](docs/perceptual-compatibility.md).

Hatari can also capture the cycle profiles behind the status numbers above:

```sh
make profile-dsp      # exact eight-channel renderer -> build/dsp-profile/report.txt
make profile-dsp-rt   # codec-rate four-operator floor -> build/dsp-profile-rt/report.txt
make profile-dsp-rt2  # algorithm-0 block spike -> build/dsp-profile-rt2/report.txt
make profile-dsp-rt3  # algorithm-7 carrier spike -> build/dsp-profile-rt3/report.txt
make profile-dsp-rt4  # algorithms 1-6 -> build/dsp-profile-rt4/algorithm-*/report.txt
make profile-dsp-rt5  # live-SSI all-topology floor -> build/dsp-profile-rt5/report.txt
```

## Run

The outputs are:

```text
release/f030mxdrv.tos
release/f030mxdrv.ttp
release/ym2151.lod
```

The DSP bootstrap and program are embedded in the executable. `ym2151.lod` is
retained as a readable assembler artifact and is reopened only by the
no-argument conformance mode to cover the GEMDOS player file path.
`f030mxdrv.tos` runs the conformance checks plus the interrupt-buffered SSI
probe and reports the result on the TOS console. `f030mxdrv.ttp` is the same
executable with a Desktop command-line entry point:

```text
F030MXDRV.TTP song.mdx [bank.pdx]
```

The MDX is limited to 65,536 bytes and the optional raw PDX bank to 319,488
bytes. Filenames are whitespace-delimited TOS paths. Press any key during
playback to stop. The player uses the codec-rate real-time FM/PDX path; the
sample-exact renderer remains available to the no-argument conformance mode
and is still 46.85 times slower than real time. `make run` starts that
conformance mode in Hatari.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/player.s`: TTP argument parser, GEMDOS loader, and player loop.
- `src/m68k/mxdrv_core.s`: resident-independent 32-call MXDRV API foundation.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/mdx.s`: bounded 9/16-track MDX initialization and tick executor.
- `src/m68k/mdx_clock.s`: MFP Timer-A accumulation and foreground tick pump.
- `src/m68k/pdx.s`: validated PDX lookup, eight MSM6258 voices, and codec mixer.
- `src/m68k/dsp_link.s`: packed 24-bit host/DSP exchange.
- `src/dsp/stage2_loader.asm`: embedded sparse P-memory loader.
- `src/dsp/ym2151.asm`: DSP protocol and command-clocked YM2151 sample kernel.
- `tools/ym2151_oracle.cpp`: native executable built against vendored ymfm.
- `tools/compare_ym2151_realtime.py`: codec-rate vector validator and
  exact-to-perceptual comparator.
- `tools/generate_ym2151_tables.py`: mechanical ymfm-to-DSP table generator.
- `tools/pdx_adpcm_oracle.cpp`: MAME-compatible MSM6258 reference vectors.
- `tools/profile_dsp.py`: deterministic Hatari DSP-cycle capture and report.
- `tools/generate_dsp_stage2.py`: LOD-to-embedded-loader image generator.
- `tests/traces/attack_all_carriers.trace`: timestamped oracle input trace.
- `tests/traces/noise_channel7.trace`: fastest-rate channel-7 noise trace.
- `tests/traces/timer_csm.trace`: two-sample Timer A/CSM oracle trace.
- `tests/traces/vibrato_pm.trace`: maximum-rate saw-vibrato PM oracle trace.
- `docs/ym2151-ground-truth.md`: facts extracted from the vendored MAME core.
- `docs/pdx-ground-truth.md`: PDX table and X68000 ADPCM decoding facts.
- `docs/mdx-ground-truth.md`: MDX sequence, track, duration, and command facts.
- `docs/dsp56001-notes.md`: constraints taken from the local Motorola manual.
- `docs/perceptual-compatibility.md`: codec-vector schema and acceptance gates.
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
