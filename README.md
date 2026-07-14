# F030MXDRV

F030MXDRV is an Atari Falcon port/recreation of MXDRV 2.06+17. The intended
division of work is:

- the Falcon 68030 runs the MXDRV-compatible MDX/PDX driver and timing;
- the Falcon DSP56001 emulates the X68000's Yamaha YM2151 (OPM);
- the Falcon crossbar/codec ultimately receives stereo samples from the DSP.

The current milestone is executable on TOS and under Hatari. The 68030 side now
has the original 32-entry MXDRV call-table shape, owned MDX/PDX buffers, core
transport state, an `OPMBuf`-compatible mirror, and a DSP-backed replacement for
MXDRV's `WriteOPM`. A bounded MDX executor validates the sequence/voice table
and all 16 track offsets, advances encoded waits and notes, loads standard FM
voice records, performs tempo/raw OPM writes and FM key-on/off, and maps PCM
tracks 8-15 to the eight PDX voices. E9/EA repeats and EB final-pass escape use
the original mutable in-stream counter layout with bounds checks. A guarded
timer-service entry reports exact YM Timer-B periods in native sample units,
and public play connects it to an otherwise-idle MFP Timer A. Its 1024 Hz ISR
only accumulates pending ticks; a foreground pump performs the XBIOS/DSP work
and stop restores timer/vector ownership. A TTP command-line mode now loads an
MDX plus an optional PDX through GEMDOS, runs that pump once per VBL, accepts a
key to stop, and restores MFP, DSP SSI, crossbar, and sound-lock ownership on
every exit path. Standard raw PDX banks now have validated 96-entry sample
lookup and eight streaming decoder voices that match the X68000 MSM6258
predictor, step, clamping, and nibble order. The host-side PCM8 layer applies
all five playback rates, the 16 volume steps, common hardware pan, and saturating
stereo mixing at the Falcon codec cadence. The DSP clocks stereo YM2151 samples
at the native 62.5 kHz
rate with phase accumulation, ADSR envelopes, logarithmic sine/power lookup,
operator feedback, all eight algorithms, panning, and YM3012 output rounding.
The DSP also clocks all four LFO waveforms, AM/PM depth and sensitivity,
operator AM gating, the channel-7 noise generator, Timer A/B status and reload
semantics, CSM keying, and the 64-clock busy flag. Generated tables and expected
tone/noise/CSM samples come mechanically from the vendored ymfm implementation.
Packed immutable tables now live in the 68030 executable and are uploaded during
DSP bootstrap, leaving enough of TOS 4.02's loader budget for the first Falcon
audio path. The first cycle-oriented pass caches all 32 unmodulated phase
increments across register writes in internal Y RAM, advances them with
parallel X/Y fetches, and retains the full frequency calculation only on
samples with non-zero phase modulation. Terminal release envelopes and fully
silent channels also bypass work that cannot affect chip state or output. Hot
scalar state now occupies short-addressable internal X RAM, reducing both
external accesses and the converted DSP image size.

The full-rate transport path pre-renders one exact
1280-native-sample/1007-codec-frame resampling period on the DSP, replays the
stereo block through 16-bit SSI at 49.17 kHz, and routes DSP transmit to the
Falcon DAC through the XBIOS sound matrix. Protocol v9 also lets the 68030
upload one exact 1007-frame stereo PDX period; the DSP adds it to a freshly
rendered FM period with signed 16-bit saturation and loops the mixed block
through the same SSI path. A separate live mode
renders every frame after SSI starts, advances the same rolling native clock,
and consumes timestamped writes without a staging boundary. It is a measured
optimization target rather than the final audio path: the current Hatari gate
produced 5,679 fresh frames in a nominal one-second interval, versus about
49,170 required by the codec.

This is not a complete music driver yet. MDX synchronization/modulation,
full FM volume handling, continuous mixed-block production, and underrun-free
live synthesis remain. The command-line player uses the experimental live DSP
mode, so FM follows sequencer writes but currently underruns. PDX files load and
their voices are sequenced/decoded on the 68030, but those PCM frames are not
yet continuously delivered to the DAC. PDX lookup, decoding, rate conversion,
gain, pan, eight-voice host mixing, and bounded PCM/FM output to the DAC are
verified, but only in the explicit integration harness. The buffered SSI mode
still supplies the
full-rate transport proof, while the live mode proves the direct scheduling and
synthesis control flow despite underrunning. Protocol v9
provides a refillable 32-entry ring FIFO of exact register events on a rolling
16-bit native sample clock; FIFO and clock-query transactions work while SSI is
active, and the clock persists across buffered and live sessions.
The exact boundary between implemented and pending work is kept in
[the architecture notes](docs/architecture.md).

## Build

The repository uses the same tools bundled with `third_party/f030dsp3d`:

- vasm/vlink are bootstrapped from its source archives;
- Motorola's DSP assembler and `CLDLOD` run under DOSBox Staging (or DOSBox).

On the current development setup:

```sh
make check
```

This also compiles a native MAME/ymfm oracle, mechanically generates compressed
DSP lookup tables, and emits a 256-sample reference trace under
`build/reference/`.

When Hatari is installed, the non-interactive integration smoke test boots TOS
4.02, loads the DSP program, and verifies ping/reset/register-write traffic,
the MXDRV `OPMBuf` seam, an exact phase step, envelope state, stereo sample
checkpoints, and all eight algorithms with feedback against ymfm, including
signed YM3012 rounding. It also checks busy/status, a deterministic LFO
boundary, channel-7 noise output, Timer A/B boundaries and status reset/cancel,
and a timer-driven CSM key sample:

```sh
make smoke
```

The smoke test also verifies standard PDX lookup bounds, empty and malformed
entries, exact MSM6258 samples, and a generated two-voice rate/gain/pan mixer
vector. It uploads a complete host-rendered PCM period and verifies the first
nonzero DSP-mixed stereo sum before checking
sound locking, DSP-to-DAC matrix setup, buffered and live audio start/stop,
rolling-clock FIFO writes during live synthesis, SSI frame-count floors,
tristating, and sound unlock under Hatari.
It also copies a 16-track MDX fixture through the public API, verifies E2 FM
voice loading, E0/E1 writes, FM note duration/key-off, and a timed track-8 PDX
trigger. The fixture also covers two-pass E9/EA repetition, EB final-pass escape,
Timer-B period changes, rejection of an out-of-range repeat target, automatic
MFP tick accumulation, foreground draining, and timer release on stop.

The outputs are:

```text
release/f030mxdrv.tos
release/f030mxdrv.ttp
release/ym2151.lod
```

Keep the executable and `ym2151.lod` in the same Falcon directory.
`f030mxdrv.tos` loads
`ym2151.lod`, runs the conformance checks plus buffered and live SSI probes, and
reports the result on the TOS console. `f030mxdrv.ttp` is the same executable
with a Desktop command-line entry point:

```text
F030MXDRV.TTP song.mdx [bank.pdx]
```

The MDX is limited to 65,536 bytes and the optional raw PDX bank to 319,488
bytes. Filenames are whitespace-delimited TOS paths. Press any key during
playback to stop. This is an integration player rather than a finished audio
path: live FM is below real-time and continuous PDX output is still pending.
`make run` starts the no-argument conformance mode in Hatari.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/player.s`: TTP argument parser, GEMDOS loader, and player loop.
- `src/m68k/mxdrv_core.s`: resident-independent 32-call MXDRV API foundation.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/mdx.s`: bounded 16-track MDX initialization and tick executor.
- `src/m68k/mdx_clock.s`: MFP Timer-A accumulation and foreground tick pump.
- `src/m68k/pdx.s`: validated PDX lookup, eight MSM6258 voices, and codec mixer.
- `src/m68k/dsp_link.s`: packed 24-bit host/DSP exchange.
- `src/dsp/ym2151.asm`: DSP protocol and command-clocked YM2151 sample kernel.
- `tools/ym2151_oracle.cpp`: native executable built against vendored ymfm.
- `tools/generate_ym2151_tables.py`: mechanical ymfm-to-DSP table generator.
- `tools/pdx_adpcm_oracle.cpp`: MAME-compatible MSM6258 reference vectors.
- `tests/traces/attack_all_carriers.trace`: timestamped oracle input trace.
- `tests/traces/noise_channel7.trace`: fastest-rate channel-7 noise trace.
- `tests/traces/timer_csm.trace`: two-sample Timer A/CSM oracle trace.
- `docs/ym2151-ground-truth.md`: facts extracted from the vendored MAME core.
- `docs/pdx-ground-truth.md`: PDX table and X68000 ADPCM decoding facts.
- `docs/mdx-ground-truth.md`: MDX sequence, track, duration, and command facts.
- `docs/dsp56001-notes.md`: constraints taken from the local Motorola manual.
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
