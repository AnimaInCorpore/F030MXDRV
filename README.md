# F030MXDRV

F030MXDRV is an Atari Falcon port/recreation of MXDRV 2.06+17. The intended
division of work is:

- the Falcon 68030 runs the MXDRV-compatible MDX/PDX driver and timing;
- the Falcon DSP56001 emulates the X68000's Yamaha YM2151 (OPM);
- the Falcon crossbar/codec ultimately receives stereo samples from the DSP.

This first scaffold is deliberately small but executable. It builds a TOS host
program and a DSP `.lod`, loads the DSP, validates a versioned host protocol,
resets a MAME-aligned YM2151 register image, and provides the `WriteOPM`
replacement seam needed by the MXDRV port. The DSP also computes OPM phase
steps from the real ymfm tables, including KC/KF, DT1, DT2, octave, and MUL.
It does **not** synthesize audio yet. The next implementation stages are tracked
in [the architecture notes](docs/architecture.md).

## Build

The repository uses the same tools bundled with `third_party/f030dsp3d`:

- vasm/vlink are bootstrapped from its source archives;
- Motorola's DSP assembler and `CLDLOD` run under DOSBox Staging (or DOSBox).

On the current development setup:

```sh
make check
```

This also compiles a native MAME/ymfm oracle, mechanically generates the DSP
tables, and emits a 256-sample reference trace under `build/reference/`.

When Hatari is installed, the non-interactive integration smoke test boots TOS
4.02, loads the DSP program, and verifies ping/reset/register-write traffic plus
an exact DSP-versus-ymfm phase-step comparison from Hatari's DSP trace:

```sh
make smoke
```

The outputs are:

```text
release/f030mxdrv.tos
release/ym2151.lod
```

Keep both files in the same Falcon directory. `f030mxdrv.tos` loads
`ym2151.lod`, performs ping/reset, and reports the result on the TOS console.
`make run` starts that smoke test in Hatari when Hatari is installed.

## Source map

- `src/m68k/main.s`: Falcon loader and smoke test.
- `src/m68k/mxdrv_port.s`: replacement seam for MXDRV's original `WriteOPM`.
- `src/m68k/dsp_link.s`: packed 24-bit host/DSP exchange.
- `src/dsp/ym2151.asm`: DSP protocol, YM2151 register state, and phase kernel.
- `tools/ym2151_oracle.cpp`: native executable built against vendored ymfm.
- `tools/generate_ym2151_tables.py`: mechanical ymfm-to-DSP table generator.
- `tests/traces/attack_all_carriers.trace`: timestamped oracle input trace.
- `docs/ym2151-ground-truth.md`: facts extracted from the vendored MAME core.
- `docs/dsp56001-notes.md`: constraints taken from the local Motorola manual.
- `docs/architecture.md`: ownership, protocol, and staged port plan.

The references under `third_party/` remain unmodified.
