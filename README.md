# F030MXDRV

F030MXDRV is an Atari Falcon port/recreation of MXDRV 2.06+17. The intended
division of work is:

- the Falcon 68030 runs the MXDRV-compatible MDX/PDX driver and timing;
- the Falcon DSP56001 emulates the X68000's Yamaha YM2151 (OPM);
- the Falcon crossbar/codec ultimately receives stereo samples from the DSP.

The current milestone is executable on TOS and under Hatari. The 68030 side now
has the original 32-entry MXDRV call-table shape, owned MDX/PDX buffers, core
transport state, an `OPMBuf`-compatible mirror, and a DSP-backed replacement for
MXDRV's `WriteOPM`. Standard raw PDX banks now have validated 96-entry sample
lookup and a streaming single-voice decoder that matches the X68000 MSM6258
predictor, step, clamping, and nibble order. The DSP clocks stereo YM2151 samples
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
Falcon DAC through the XBIOS sound matrix. A separate protocol-v8 live mode now
renders every frame after SSI starts, advances the same rolling native clock,
and consumes timestamped writes without a staging boundary. It is a measured
optimization target rather than the final audio path: the current Hatari gate
produced 5,679 fresh frames in a nominal one-second interval, versus about
49,170 required by the codec.

This is not a complete music driver yet. MDX command replay and timer service,
PDX rate conversion/polyphonic mixing, and continuous underrun-free synthesis
remain. PDX samples can be located and decoded but are not yet triggered by MDX
tracks or mixed into Falcon output. The buffered SSI mode still supplies the
full-rate transport proof, while the live mode proves the direct scheduling and
synthesis control flow despite underrunning. Protocol v8
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
entries, and exact MSM6258 samples from a generated oracle. It then verifies
sound locking, DSP-to-DAC matrix setup, buffered and live audio start/stop,
rolling-clock FIFO writes during live synthesis, SSI frame-count floors,
tristating, and sound unlock under Hatari.

The outputs are:

```text
release/f030mxdrv.tos
release/ym2151.lod
```

Keep both files in the same Falcon directory. `f030mxdrv.tos` loads
`ym2151.lod`, runs the conformance checks plus buffered and live SSI probes, and
reports the result on the TOS console. `make run` starts it in Hatari when
Hatari is installed. It is a test harness at this stage, not yet an MDX player.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/mxdrv_core.s`: resident-independent 32-call MXDRV API foundation.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/pdx.s`: validated standard PDX lookup and MSM6258 stream decoder.
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
- `docs/dsp56001-notes.md`: constraints taken from the local Motorola manual.
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
