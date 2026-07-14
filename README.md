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
  and a bounded MDX executor covering voice loading, tempo and raw OPM
  writes, FM key-on/off, E9/EA repeats with the original mutable in-stream
  counter layout, EB final-pass escapes, and PCM tracks 8–15 mapped to eight
  PDX voices.
- **X68000-exact ADPCM.** Validated 96-entry PDX sample lookup and eight
  streaming decoder voices matching the MSM6258 predictor, step, clamping,
  and nibble order, with all five playback rates, 16 volume steps, hardware
  pan, and saturating stereo mixing at the Falcon codec cadence.
- **Continuous DAC transport.** The DSP SSI transmit interrupt replays exact
  1280-native-sample/1007-codec-frame resampling periods through 16-bit SSI
  at 49.17 kHz into the Falcon DAC, double-buffered, with timestamped YM
  register events on a rolling native-sample clock that survives refills.
- **Verified, measured, reproducible.** A native ymfm oracle, golden
  tone/noise/CSM/vibrato traces, a Hatari integration smoke test, and two
  deterministic DSP cycle profilers gate every change.

## Honest status

This is not a finished music driver yet — and the numbers below are exactly
why the project publishes its own profiler.

- The command-line player feeds FM and PDX through the interrupt-buffered
  path with uninterrupted DAC transport, but **not accurate wall-clock
  playback**: the sample-exact FM kernel currently needs about 959 ms of
  modeled DSP time to render each 20.48 ms block, so a completed block
  repeats while the next one renders.
- The exact kernel measures **12,022.76 instruction cycles per native
  62.5 kHz sample** against the Falcon's **256.68-cycle** budget — a 46.84x
  real-time miss (down from 50.10x before the current optimization pass).
  It is kept as the conformance reference.
- The selected real-time target is a perceptual codec-rate FM kernel with
  exact write ordering, register semantics, and drift-free pitch/control
  timing, rather than sample equality. A first codec-rate feasibility kernel
  advances four drift-free oscillators in 39.16 cycles per codec frame using
  modulo rings and parallel X/Y moves. A second, block-oriented spike now
  renders a complete serial algorithm-0 channel — operator-1 feedback,
  per-frame modulation, block-rate envelope gains, and interleaved stereo —
  in 50.17 cycles per codec frame. Its linear eight-channel projection is
  401.39 cycles against the 326.27-cycle frame budget, so the worst-case
  all-algorithm-0 workload currently misses real time by **1.23x** (not the
  exact kernel's 46.84x). Split X/Y feedback state and software-pipelined
  ring/output traffic removed 16.5% from the first version of this spike;
  cheaper parallel-algorithm stages remain unexploited.
- MDX synchronization/modulation and real-time mixed-block production
  remain. The exact boundary between implemented and pending work is kept in
  [the architecture notes](docs/architecture.md).

## How it fits together

- The 68030 executable embeds everything the DSP needs: packed immutable
  ymfm tables, plus the complete sparse DSP program behind a 111-word
  `Dsp_ExecBoot` first stage that receives 2,926 initialized P-memory words
  through the host port — removing the 8 KiB converted-LOD ceiling.
- The DSP kernel caches all 32 unmodulated phase increments across register
  writes in internal Y RAM and advances them with parallel X/Y fetches.
  Samples with non-zero phase modulation combine cached per-operator
  frequency data with the live LFO value instead of re-decoding registers.
  Terminal release envelopes and fully silent channels bypass work that
  cannot affect chip state or output; hot scalar state lives in
  short-addressable internal X RAM.
- Protocol v11 gives the DSP two interleaved stereo buffers in external
  X RAM. The 68030 uploads one 1007-frame PDX period into the inactive
  buffer; the DSP renders the matching FM period in place with signed 16-bit
  saturation, switches buffers at a stereo boundary, and leaves the last
  complete block repeating if a refill misses a codec period. A refillable
  32-entry ring FIFO carries exact register events with native-sample
  timestamps while SSI runs.
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
compressed DSP lookup tables, and emits a 256-sample reference trace under
`build/reference/`.

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
and clean teardown. It also copies a 16-track MDX fixture through the public
API, covering FM voice loading, E0/E1 writes, note duration/key-off, a timed
track-8 PDX trigger, two-pass E9/EA repetition, EB final-pass escape, Timer-B
period changes, rejection of an out-of-range repeat target, and timer release
on stop.

Hatari can also capture the cycle profiles behind the status numbers above:

```sh
make profile-dsp      # exact eight-channel renderer -> build/dsp-profile/report.txt
make profile-dsp-rt   # codec-rate four-operator floor -> build/dsp-profile-rt/report.txt
make profile-dsp-rt2  # algorithm-0 block spike -> build/dsp-profile-rt2/report.txt
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
playback to stop. This is an integration player rather than a finished audio
path: SSI transport remains continuous, but the exact full-load FM renderer
is about 46.84 times slower than the codec consumes it. `make run` starts the
no-argument conformance mode in Hatari.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/player.s`: TTP argument parser, GEMDOS loader, and player loop.
- `src/m68k/mxdrv_core.s`: resident-independent 32-call MXDRV API foundation.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/mdx.s`: bounded 16-track MDX initialization and tick executor.
- `src/m68k/mdx_clock.s`: MFP Timer-A accumulation and foreground tick pump.
- `src/m68k/pdx.s`: validated PDX lookup, eight MSM6258 voices, and codec mixer.
- `src/m68k/dsp_link.s`: packed 24-bit host/DSP exchange.
- `src/dsp/stage2_loader.asm`: embedded sparse P-memory loader.
- `src/dsp/ym2151.asm`: DSP protocol and command-clocked YM2151 sample kernel.
- `tools/ym2151_oracle.cpp`: native executable built against vendored ymfm.
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
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
