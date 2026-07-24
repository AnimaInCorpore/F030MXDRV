# F030MXDRV

F030MXDRV plays Sharp X68000 MDX/PDX music on an Atari Falcon. The 68030 runs
an MXDRV-compatible sequencer and the Falcon DSP56001 emulates the Yamaha
YM2151, mixes MSM6258 ADPCM, and feeds 16-bit stereo audio to the Falcon DAC.

The normal player uses a measured 24,584.9609375 Hz DSP kernel that fits the
stock 32 MHz DSP budget. A separate 62.5 kHz, sample-exact YM2151 kernel is
retained as the conformance oracle and is checked against the vendored MAME
ymfm implementation.

## Project status

The playback path is complete and passes the repository's Hatari gates. It
supports bounded 9- and 16-track MDX execution, automatic PDX lookup, eight
PCM voices, realtime FM/PDX mixing, interrupt-fed double buffering, two-loop
playback, and fadeout.

This is still a pre-release project:

- production playback has not completed a physical-Falcon validation and
  long-duration soak;
- the resident-independent dispatcher preserves the original 32-entry MXDRV
  call-table shape, but nine public entries still return `-1`; and
- no packaged hardware release is provided yet.

The exact support boundary is documented in
[`docs/mxdrv-api.md`](docs/mxdrv-api.md) and
[`docs/mdx-ground-truth.md`](docs/mdx-ground-truth.md).

## What is implemented

- YM2151 phase, ADSR, feedback, all eight algorithms, panning, four LFO
  waveforms, AM/PM, channel-7 noise, Timer A/B, CSM, busy state, and YM3012
  rounding.
- A codec-rate production kernel with ordered mid-block register events,
  independent feedback depth, DT1/DT2, block-rate envelopes and LFO, noise,
  live SSI output, and planar PDX mixing.
- A bounded MDX executor covering notes/rests, voice and tempo changes,
  repeats and escapes, detune, portamento, legato, key-on delay, software
  pitch/volume LFOs, OPM LFO control, sync, noise/PCM frequency, PCM8 enable,
  loop counting, and fadeout.
- X68000-compatible MSM6258 decoding for the standard 96-entry raw PDX layout,
  with eight voices, five rates, 16 PCM8 gain levels, global pan, saturation,
  and a DSP-side two-tap reconstruction filter.
- A 512-frame, 20.83 ms production transport. The 68030 prepares the next
  period while SSI repeats the last complete one; the DSP changes buffers only
  at a stereo-period boundary.
- Reproducible native-oracle, perceptual, smoke, stock-clock timing, endurance,
  and DSP-cycle gates.

The integrated worst-case DSP profile measures 364.14 instruction cycles per
24.585 kHz frame against a 652.53-cycle budget. The exact scalar renderer costs
12,024.34 cycles per native 62.5 kHz sample against a 256.68-cycle budget, so it
is deliberately a test oracle rather than the production renderer.

## Build

The supported build flow expects a POSIX shell plus:

- Git with access to the three pinned submodules;
- Python 3, a C++17 compiler, `make`, `tar`, `file`, and `rg`;
- DOSBox Staging or DOSBox for Motorola's DSP assembler; and
- Hatari for emulator integration, capture, endurance, and profiling targets.

Initialize the pinned dependencies and build the complete static validation
set:

```sh
git submodule update --init --recursive
make check
```

`make check` bootstraps vasm/vlink from the archived sources in
`third_party/f030dsp3d`, assembles both processors, builds the native ymfm and
MSM6258 oracles, regenerates all lookup/reference data, and validates the
19-scenario perceptual reference model. It does not launch Hatari.

Use `make help` for the complete target summary. The most useful targets are:

| Target | Purpose | Extra input |
| --- | --- | --- |
| `make all` | build the Falcon executables and DSP image | DOSBox |
| `make check` | run static build and oracle gates | DOSBox |
| `make smoke` | run the full non-interactive Hatari integration test | Hatari |
| `make capture-realtime` | capture and compare all 19 production-kernel scenarios | Hatari |
| `make stock-audio` | verify stock-clock SSI cadence and clipping | Hatari + Xevious corpus files |
| `make endurance` | play Xevious through two loops, fade, and shutdown | Hatari + Xevious corpus files |
| `make endurance-batch` | play every uppercase `*.MDX` in the local corpus | Hatari + local corpus |
| `make profile-dsp-rt5` | reproduce the integrated DSP cycle report | Hatari |

The principal outputs are:

```text
release/f030mxdrv.tos  conformance program and GEM launchable player
release/f030mxdrv.ttp  the same program with a Desktop command-line entry
release/xevious.tos    dedicated no-argument Xevious player
release/ym2151.lod     readable DSP assembler artifact
```

`make clean` removes only generated `build/` and `release/` content. Local
music files belong in `corpus/`, which is ignored and is never removed by that
target.

## Local endurance corpus

MDX/PDX music is not part of the tracked repository. Put local test material
in `corpus/`, or override the directory on the command line:

```text
corpus/
  XEVIOUS.MDX
  XEVIOUS.PDX
  ...
```

```sh
make stock-audio
make endurance
make endurance-batch CORPUS_DIR=/path/to/mdx-corpus
```

The batch gate discovers uppercase `*.MDX` files, reads each embedded PDX
name, and copies the required pair into an isolated Hatari work directory. It
streams the trace through a FIFO, retaining a short tail only for failures.

## Run on a Falcon or in Hatari

The TTP command line accepts one required MDX and one optional PDX override:

```text
F030MXDRV.TTP song.mdx [bank.pdx]
```

When the override is absent, the player reads the PDX name from the MDX
header, appends `.PDX` if necessary, and resolves a basename beside the MDX.
An empty embedded name means FM-only playback. Paths are whitespace-delimited;
the MDX limit is 65,536 bytes and the raw PDX limit is 319,488 bytes.

With no command tail, `AUTOPLAY.INF` beside the program may contain the same
one- or two-token line. `xevious.tos` instead defaults to `XEVIOUS.MDX`; keep
the MDX and its embedded `XEVIOUS.PDX` beside that executable. An explicit
command line still overrides the built-in default.

Playback fades after two complete loops or on the first keypress. A second
keypress stops immediately. All exit paths restore MFP Timer A, DSP SSI,
crossbar routing, codec attenuation, and sound-lock ownership.

For the no-argument conformance program in Hatari:

```sh
make run
```

## Architecture

The 68030 owns the MXDRV-compatible API, file validation, track state, timing,
and PDX decoding. The DSP owns YM2151 state, realtime FM synthesis, final PCM
mixing, saturation, and SSI transport.

Protocol v23 uses 24-bit host words. Production refills batch up to 64
coalesced YM writes and 512 mono PDX frames; the DSP stages those writes into a
32-entry rolling event FIFO, renders sixteen 32-frame blocks, and switches the
inactive 1024-word stereo SSI buffer at the next complete boundary. A
drift-free 2560:1007 DDA maps the native 62.5 kHz YM clock to the Falcon quality
rate.

The executable embeds a 111-word `Dsp_ExecBoot` loader and a sparse 7,865-word
DSP program. This bypasses the converted-LOD size ceiling while retaining
`ym2151.lod` as an inspectable build artifact.

See [`docs/architecture.md`](docs/architecture.md) for the protocol and memory
layout.

## Verification model

The repository intentionally separates three contracts:

1. The command-clocked DSP kernel is sample-exact against MAME/ymfm at selected
   phase, envelope, timer, noise, LFO, algorithm, feedback, and YM3012
   checkpoints.
2. The production kernel preserves exact long-term pitch and control timing,
   while timbre is graded against a codec-rate 256-step-sine reference with
   explicit spectral, envelope, LFO, noise, and splice thresholds.
3. Hatari integration gates exercise the actual player, file loading, MDX/PDX
   execution, refill cadence, shutdown, and optional local song corpus.

The detailed contracts live in
[`docs/ym2151-ground-truth.md`](docs/ym2151-ground-truth.md),
[`docs/perceptual-compatibility.md`](docs/perceptual-compatibility.md), and
[`docs/pdx-ground-truth.md`](docs/pdx-ground-truth.md).

## Repository map

- `src/m68k/main.s`: Falcon bootstrap and conformance/smoke harness.
- `src/m68k/player.s`: command-tail/autoplay parsing, file loading, and player loop.
- `src/m68k/mxdrv_core.s`: resident-independent 32-entry API dispatcher.
- `src/m68k/mdx.s`: bounded 9/16-track MDX executor.
- `src/m68k/mdx_clock.s`: MFP Timer-A accumulation and foreground pump.
- `src/m68k/pdx.s`: checked PDX lookup, MSM6258 voices, and host mixer.
- `src/m68k/dsp_link.s`: packed host/DSP transfer and production refill path.
- `src/dsp/ym2151.asm`: exact and production YM2151 kernels plus SSI service.
- `src/dsp/stage2_loader.asm`: sparse embedded P-memory loader.
- `tests/traces/`: tracked oracle and perceptual register-write fixtures.
- `tools/`: reference generators, capture/comparison tools, endurance runner,
  and cycle profiler.
- `docs/`: API, file-format, DSP, architecture, and compatibility contracts.

The pinned references under `third_party/` are not modified by the build.
