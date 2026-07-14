#!/usr/bin/env python3
"""Generate DSP56001 tables from the vendored MAME/ymfm source.

The generated file is a build artifact. Keeping extraction mechanical avoids a
second hand-maintained copy of the chip tables while the DSP implementation is
still evolving.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def initializer(source: str, declaration: str) -> str:
    start = source.index(declaration)
    start = source.index("{", start) + 1
    end = source.index("};", start)
    body = source[start:end]
    return re.sub(r"//.*", "", body)


def integers(body: str) -> list[int]:
    return [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", body)]


def emit_table(name: str, values: list[int], width: int = 8) -> None:
    print(f"{name}:")
    for offset in range(0, len(values), width):
        row = ",".join(str(value) for value in values[offset : offset + width])
        print(f"        dc      {row}")
    print()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} path/to/ymfm_fm.ipp", file=sys.stderr)
        return 2

    source_path = Path(sys.argv[1])
    source = source_path.read_text(encoding="utf-8")

    phase = integers(initializer(source, "static const uint32_t s_phase_step[12*64]"))
    detune = integers(initializer(source, "static uint8_t const s_detune_adjustment[32][4]"))
    sine = integers(initializer(source, "static uint16_t const s_sin_table[256]"))
    power_body = initializer(source, "static uint16_t const s_power_table[256]")
    power = [((int(value, 16) | 0x400) << 2) for value in re.findall(r"X\((0x[0-9a-fA-F]+)\)", power_body)]

    expected = {"phase": 768, "detune": 128, "sine": 256, "power": 256}
    actual = {"phase": len(phase), "detune": len(detune), "sine": len(sine), "power": len(power)}
    if actual != expected:
        raise RuntimeError(f"ymfm table shape changed: expected {expected}, got {actual}")

    print("; Generated from third_party/mame/3rdparty/ymfm/src/ymfm_fm.ipp.")
    print("; The source tables are BSD-3-Clause licensed by their ymfm authors.")
    print("; Do not edit this build artifact by hand.")
    print()
    print("        org     y:$0")
    print()
    emit_table("opm_phase_step", phase)
    emit_table("opm_detune_adjustment", detune)
    emit_table("opm_sine_attenuation", sine)
    emit_table("opm_power", power)
    emit_table("opm_dt2_delta", [0, 384, 500, 608], width=4)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
