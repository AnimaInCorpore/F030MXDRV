# F030MXDRV

F030MXDRV is an Atari Falcon port/recreation of MXDRV 2.06+17. The intended
division of work is:

- the Falcon 68030 runs the MXDRV-compatible MDX/PDX driver and timing;
- the Falcon DSP56001 emulates the X68000's Yamaha YM2151 (OPM);
- the Falcon crossbar/codec ultimately receives stereo samples from the DSP.

The current milestone is executable on TOS and under Hatari. The 68030 side now
has the original 32-entry MXDRV call-table shape, owned MDX/PDX buffers, core
transport state, an `OPMBuf`-compatible mirror, and a DSP-backed replacement for
MXDRV's `WriteOPM`. The DSP clocks stereo YM2151 samples at the native 62.5 kHz
rate with phase accumulation, ADSR envelopes, logarithmic sine/power lookup,
operator feedback, all eight algorithms, panning, and YM3012 output rounding.
Generated tables and expected samples come mechanically from the vendored ymfm
implementation.

This is not a complete music driver yet. MDX command replay and timer service,
YM2151 LFO/noise/timers/CSM, PDX mixing, resampling, and Falcon SSI/crossbar
output remain. The exact boundary between implemented and pending work is kept
in [the architecture notes](docs/architecture.md).

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
signed YM3012 rounding:

```sh
make smoke
```

The outputs are:

```text
release/f030mxdrv.tos
release/ym2151.lod
```

Keep both files in the same Falcon directory. `f030mxdrv.tos` loads
`ym2151.lod`, runs the conformance checks, and reports the result on the TOS
console. `make run` starts it in Hatari when Hatari is installed. It is a test
harness at this stage, not yet an MDX player.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/mxdrv_core.s`: resident-independent 32-call MXDRV API foundation.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/dsp_link.s`: packed 24-bit host/DSP exchange.
- `src/dsp/ym2151.asm`: DSP protocol and command-clocked YM2151 sample kernel.
- `tools/ym2151_oracle.cpp`: native executable built against vendored ymfm.
- `tools/generate_ym2151_tables.py`: mechanical ymfm-to-DSP table generator.
- `tests/traces/attack_all_carriers.trace`: timestamped oracle input trace.
- `docs/ym2151-ground-truth.md`: facts extracted from the vendored MAME core.
- `docs/dsp56001-notes.md`: constraints taken from the local Motorola manual.
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
