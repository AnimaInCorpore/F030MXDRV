# F030MXDRV

**Sharp X68000 music on an Atari Falcon — with the Yamaha YM2151 emulated,
in real time, on the Falcon's own DSP.**

F030MXDRV is a native Atari Falcon port/recreation of MXDRV 2.06+17, the
X68000's canonical MDX/PDX music driver. The Falcon 68030 runs the
MXDRV-compatible driver and timing, the Falcon DSP56001 emulates the X68000's
Yamaha YM2151 (OPM), and the Falcon crossbar/codec receives the stereo result.

The DSP contains a register- and sample-exact YM2151 conformance core, verified
against MAME's ymfm down to individual stereo samples. Playback uses a measured
24.585 kHz quality kernel that preserves musical clocks and register semantics
within the stock Falcon's realtime budget — surrounded by the complete MXDRV call-table, a
complete bounded MDX executor, X68000-exact MSM6258 ADPCM (PDX) decoding, and
interrupt-fed DAC transport, all on stock Falcon hardware.

## Highlights

- **Bit-exact OPM conformance on the DSP56001.** Phase accumulation, ADSR
  envelopes, logarithmic sine/power lookup, operator feedback, all eight
  algorithms, panning, and YM3012 output rounding — every table and expected
  sample generated mechanically from the vendored ymfm implementation.
- **The whole chip, not just the tone path.** All four LFO waveforms, AM/PM
  depth and sensitivity, operator AM gating, the channel-7 noise generator,
  Timer A/B status and reload semantics, CSM keying, and the 64-clock busy
  flag.
- **Real time on the Falcon's 32 MHz DSP.** A 24.585 kHz quality kernel
  renders all eight FM channels — decoded envelope curvature, per-operator
  DT1/DT2, true block AM/PM, channel-7 noise substitution, timers, mid-block
  event splitting, independent feedback-history depth, and planar PDX mixing —
  in **364.14 of the 652.53 instruction cycles** available per frame, with
  exact write ordering and effectively drift-free musical pitch.
- **A real MXDRV, not a shim.** The original 32-entry call-table shape, owned
  MDX/PDX buffers, an `OPMBuf`-compatible mirror, a DSP-backed `WriteOPM`,
  and a bounded standard-file MDX executor covering the full command set:
  9- and 16-track headers, voice loading, tempo and raw OPM writes, repeats
  with the original mutable in-stream counter layout, portamento, detune,
  legato, key-on delay, software pitch and volume LFOs, OPM LFO control,
  sync control, noise and PCM frequency, fadeout with loop counting, and PCM
  tracks 8–15 mapped to eight PDX voices.
- **X68000-exact ADPCM.** Validated 96-entry PDX sample lookup and eight
  streaming decoder voices matching the MSM6258 predictor, step, clamping,
  and nibble order, with all five playback rates, 16 volume steps, hardware
  pan, saturating stereo mixing, and a DSP-side two-tap anti-image filter. The legacy
  pre-E8 IOCS ADPCM path retains its original fixed gain instead of applying
  PCM8's volume table.
- **Continuous DAC transport.** The DSP SSI transmit interrupt feeds 16-bit
  stereo at 24.585 kHz into the Falcon DAC. Production playback is double-
  buffered in 512-frame periods, with sequencer writes batched into the next
  refill and each prepared buffer switched only at a complete boundary.
- **Verified, measured, reproducible.** A native ymfm oracle, golden oracle
  traces, an 18-scenario perceptual capture gate replayed through the
  production player in Hatari, a corpus-wide end-to-end endurance gate, and
  eleven DSP cycle profiles gate every change.

## Status

The driver is player-complete under emulation. What remains before a release
is the real-hardware pass: soak testing on a physical Falcon, the MXDRV
option-call semantics, and packaging.

- **The perceptual gate covers all 19 scenarios.** Its independent 24.585 kHz
  projection retains exact pitch/control timing, all eight algorithms, both
  feedback extremes, LFO, envelopes, detune, noise, and sustained-feedback
  stability. The realtime DSP now computes audible serial modulation and
  feedback history as separate products, eliminating the former coupled-gain
  fold for feedback levels 1–7. Sustained feedback level 7 is fenced on two
  independent topologies (algorithms 4 and 5). See
  [`docs/perceptual-compatibility.md`](docs/perceptual-compatibility.md).
- **Every corpus song plays end to end.** `make endurance-batch` plays all
  17 real MDX/PDX songs in `release/` through the argument-less autoplay
  path under Hatari — sustained refills as the only cadence, live ADPCM
  decoding, two full loops, the automatic fade, and a clean CODEC/DSP
  shutdown — with zero protocol errors across the corpus.
- **Stock-clock refill timing is gated.** `make stock-audio` runs the dedicated
  Xevious player with a 16 MHz 68030 and normal 32 MHz DSP, then verifies from
  Hatari's raw SSI trace that every steady A/B handoff occurs after exactly
  1024 stereo words (one 512-frame, 20.83 ms period) and rejects excessive
  saturated output words.
- The sample-exact renderer (12,024.34 instruction cycles per native
  62.5 kHz sample against the 256.68-cycle budget — 46.85x real time) is
  retained as the conformance reference that anchors the perceptual kernel.

## How it fits together

- The 68030 executable embeds everything the DSP needs: packed immutable
  ymfm tables, plus the complete sparse DSP program behind a 111-word
  `Dsp_ExecBoot` first stage that receives 7,862 initialized P-memory words
  through the host port — removing the 8 KiB converted-LOD ceiling.
- The DSP kernel caches all 32 unmodulated phase increments across register
  writes in internal Y RAM and advances them with parallel X/Y fetches.
  Samples with non-zero phase modulation combine cached per-operator
  frequency data with the live LFO value instead of re-decoding registers.
  Terminal release envelopes and fully silent channels bypass work that
  cannot affect chip state or output; hot scalar state lives in
  short-addressable internal X RAM.
- Protocol v23 retains the exact 1007-frame conformance transport and adds a
  512-frame production transport aligned to sixteen 32-frame synthesis
  blocks. The 68030 mixes PDX voice-major into one mono block, uploads it once
  with the global PCM8 pan and coalesced ordered YM writes, then prepares the
  following period while the DSP renders. The DSP expands PDX to planar
  accumulators, renders FM into the inactive interleaved SSI buffer, and
  switches only at a complete 20.83 ms boundary. Production bursts have a
  64-word staging area, while a refillable 32-entry ring FIFO retains the exact
  timestamped event path used by conformance capture.
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
validates an 18-scenario codec-rate perceptual corpus, and gates an independent
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
public API, covering FM voice loading, note duration/key-off, a timed track-8
PDX trigger, repeat and escape handling, Timer-B period changes, fadeout with
loop counting, and timer release on stop.

The perceptual corpus covers pitch, DT1/DT2 detune, non-codec-aligned key and
register writes, ADSR state, AM/PM LFO and noise rates, feedback spectra, and
all eight algorithms. The production DSP kernel is captured and checked
against explicit rate, timing, envelope, and spectral limits with:

```sh
make capture-realtime
```

which replays every scenario in Hatari, dumps block-boundary DSP state,
reconstructs the per-frame vectors, and runs the comparator (equivalently,
`make compare-realtime REALTIME_CANDIDATE_DIR=path/to/capture` gates an
existing capture directory). The vector schema and thresholds are documented
in [`docs/perceptual-compatibility.md`](docs/perceptual-compatibility.md).

The stock timing gate and two end-to-end endurance gates play real corpus
songs through the
argument-less autoplay path under Hatari — sustained refills, live ADPCM
decoding, the natural song end after two loops and the fade, and clean
CODEC/DSP shutdown, with the trace asserting the refill volume and the
absence of protocol error replies:

```sh
make stock-audio      # Xevious, stock 16 MHz 68030, raw SSI cadence
make endurance        # the reference song, trace-asserted
make endurance-batch  # every corpus song in release/
```

The batch driver streams each Hatari trace through a FIFO and scores it in
flight, so no trace file is written; failing songs keep a rolling trace tail
under `build/endurance-batch/`.

Hatari can also capture the cycle profiles behind the status numbers above:

```sh
make profile-dsp      # exact eight-channel renderer -> build/dsp-profile/report.txt
make profile-dsp-rt   # codec-rate four-operator floor -> build/dsp-profile-rt/report.txt
make profile-dsp-rt2  # algorithm-0 block spike -> build/dsp-profile-rt2/report.txt
make profile-dsp-rt3  # algorithm-7 carrier spike -> build/dsp-profile-rt3/report.txt
make profile-dsp-rt4  # algorithms 1-6 -> build/dsp-profile-rt4/algorithm-*/report.txt
make profile-dsp-rt5  # live-SSI production kernel -> build/dsp-profile-rt5/report.txt
```

## Run

The outputs are:

```text
release/f030mxdrv.tos
release/f030mxdrv.ttp
release/xevious.tos
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

For a quick playback test, `xevious.tos` starts `XEVIOUS.MDX` with
`XEVIOUS.PDX` when launched without arguments. Keep both files beside the
executable. An explicit command line still overrides this built-in default;
`make xevious` rebuilds the dedicated executable.

Without arguments, an `AUTOPLAY.INF` file beside the program supplies the
same two-token command line, so Desktop launches and unattended runs start
playback directly. The MDX is limited to 65,536 bytes and the optional raw
PDX bank to 319,488 bytes. Filenames are whitespace-delimited TOS paths.

Playback fades out after two full loops of the song or on the first
keypress; a second keypress stops immediately. The player uses the
codec-rate real-time FM/PDX path; the sample-exact renderer remains
available to the no-argument conformance mode. `make run` starts that
conformance mode in Hatari.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/player.s`: TTP/autoplay argument parsing, GEMDOS loader, and player loop.
- `src/m68k/mxdrv_core.s`: resident-independent 32-call MXDRV API foundation.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/mdx.s`: bounded 9/16-track MDX initialization and tick executor.
- `src/m68k/mdx_clock.s`: MFP Timer-A accumulation and foreground tick pump.
- `src/m68k/pdx.s`: validated PDX lookup, eight MSM6258 voices, and codec mixer.
- `src/m68k/capture.s`: scenario-file capture mode behind the perceptual gate.
- `src/m68k/dsp_link.s`: packed 24-bit host/DSP exchange.
- `src/dsp/stage2_loader.asm`: embedded sparse P-memory loader.
- `src/dsp/ym2151.asm`: DSP protocol, exact sample kernel, and the codec-rate
  real-time kernel.
- `tools/ym2151_oracle.cpp`: native executable built against vendored ymfm.
- `tools/capture_ym2151_realtime.py`: Hatari capture orchestrator for the
  18-scenario perceptual gate.
- `tools/compare_ym2151_realtime.py`: codec-rate vector validator and
  exact-to-perceptual comparator.
- `tools/generate_ym2151_tables.py`: mechanical ymfm-to-DSP table generator.
- `tools/generate_envelope_tables.py`: per-rate affine envelope step tables.
- `tools/pdx_adpcm_oracle.cpp`: MAME-compatible MSM6258 reference vectors.
- `tools/profile_dsp.py`: deterministic Hatari DSP-cycle capture and report.
- `tools/generate_dsp_stage2.py`: LOD-to-embedded-loader image generator.
- `tools/endurance_batch.py`: corpus-wide end-to-end playback gate.
- `tools/stock_audio_timing.py`: stock-clock raw-SSI refill timing gate.
- `tests/traces/`: timestamped oracle input traces — tone, noise, timer/CSM,
  vibrato, and the perceptual corpus fixtures.
- `docs/ym2151-ground-truth.md`: facts extracted from the vendored MAME core.
- `docs/pdx-ground-truth.md`: PDX table and X68000 ADPCM decoding facts.
- `docs/mdx-ground-truth.md`: MDX sequence, track, duration, and command facts.
- `docs/dsp56001-notes.md`: constraints taken from the local Motorola manual.
- `docs/perceptual-compatibility.md`: codec-vector schema and acceptance gates.
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
