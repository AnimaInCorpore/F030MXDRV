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
    # Force CLDLOD to emit bounded blocks. TOS 4.02's LOD converter rejects
    # very large contiguous data records even when the reserved RAM is ample.
    print("        ds      1")
    print()


def pack_nibbles(values: list[int]) -> list[int]:
    if any(value < 0 or value > 0x0F for value in values):
        raise ValueError("nibble-packed value out of range")
    packed: list[int] = []
    for offset in range(0, len(values), 6):
        word = 0
        for shift, value in enumerate(values[offset : offset + 6]):
            word |= value << (4 * shift)
        packed.append(word)
    return packed


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
    increment_words = integers(initializer(source, "static uint32_t const s_increment_table[64]"))
    increments = [
        (word >> (4 * index)) & 0x0F
        for word in increment_words
        for index in range(8)
    ]

    expected = {"phase": 768, "detune": 128, "sine": 256, "power": 256, "increments": 512}
    actual = {
        "phase": len(phase),
        "detune": len(detune),
        "sine": len(sine),
        "power": len(power),
        "increments": len(increments),
    }
    if actual != expected:
        raise RuntimeError(f"ymfm table shape changed: expected {expected}, got {actual}")

    print("; Generated from third_party/mame/3rdparty/ymfm/src/ymfm_fm.ipp.")
    print("; The source tables are BSD-3-Clause licensed by their ymfm authors.")
    print("; Do not edit this build artifact by hand.")
    print()
    # Falcon external P memory aliases external X/Y RAM. Keep the lookup block
    # above the command kernel's P footprint so Dsp_LoadProg can reserve both.
    print("        org     y:$800")
    print()
    phase_deltas = [(right - left) // 32 for left, right in zip(phase, phase[1:])]
    if any((right - left) % 32 for left, right in zip(phase, phase[1:])):
        raise RuntimeError("phase table is no longer delta-packable in 32-unit steps")

    print("opm_phase_step:")
    print(f"        ds      {len(phase)}")
    print()
    emit_table("opm_phase_step_packed", [phase[0], *pack_nibbles(phase_deltas)])
    emit_table("opm_detune_adjustment", detune)
    emit_table("opm_sine_attenuation", sine)
    emit_table("opm_power", power)
    print("opm_envelope_increment:")
    print(f"        ds      {len(increments)}")
    print()
    emit_table("opm_envelope_increment_packed", pack_nibbles(increments))
    # Packed exactly like fm_channel::output_4op's s_algorithm_ops table.
    emit_table("opm_algorithm_ops", [0x035, 0x03A, 0x064, 0x071, 0x131, 0x313, 0x301, 0x380])
    emit_table("opm_dt2_delta", [0, 384, 500, 608], width=4)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
