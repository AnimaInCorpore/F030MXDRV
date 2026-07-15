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


def emit_dsp_reservation(name: str, values: list[int]) -> None:
    print(f"{name}:")
    print(f"        ds      {len(values)}")
    print()


def emit_m68k_table(values: list[int], width: int = 8) -> None:
    for offset in range(0, len(values), width):
        row = ",".join(str(value) for value in values[offset : offset + width])
        print(f"        dc.l    {row}")


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


def pack_pairs_12(values: list[int]) -> list[int]:
    if len(values) % 2 or any(value < 0 or value > 0x0FFF for value in values):
        raise ValueError("12-bit pair-packed values are invalid")
    return [left | (right << 12) for left, right in zip(values[::2], values[1::2])]


def pack_fixed(values: list[int], bits: int) -> list[int]:
    per_word = 24 // bits
    limit = (1 << bits) - 1
    if any(value < 0 or value > limit for value in values):
        raise ValueError(f"{bits}-bit packed value out of range")
    packed: list[int] = []
    for offset in range(0, len(values), per_word):
        word = 0
        for shift, value in enumerate(values[offset : offset + per_word]):
            word |= value << (bits * shift)
        packed.append(word)
    return packed


def main() -> int:
    host_output = len(sys.argv) == 3 and sys.argv[1] == "--host"
    if len(sys.argv) != 2 and not host_output:
        print(
            f"usage: {Path(sys.argv[0]).name} [--host] path/to/ymfm_fm.ipp",
            file=sys.stderr,
        )
        return 2

    source_path = Path(sys.argv[2] if host_output else sys.argv[1])
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

    phase_deltas = [(right - left) // 32 for left, right in zip(phase, phase[1:])]
    if any((right - left) % 32 for left, right in zip(phase, phase[1:])):
        raise RuntimeError("phase table is no longer delta-packable in 32-unit steps")

    packed_phase = [phase[0], *pack_fixed(phase_deltas, 3)]
    packed_detune = pack_fixed(detune, 5)
    sine_deltas = [left - right for left, right in zip(sine, sine[1:])]
    packed_sine = [sine[0], *sine_deltas[:5], *pack_fixed(sine_deltas[5:], 6)]
    if any(value & 3 for value in power):
        raise RuntimeError("power table is no longer exactly quarter-packable")
    quarter_power = [value >> 2 for value in power]
    power_deltas = [left - right for left, right in zip(quarter_power, quarter_power[1:])]
    packed_power = [quarter_power[0], *pack_fixed(power_deltas, 3)]
    packed_increments = pack_nibbles(increments)
    algorithm_ops = [0x035, 0x03A, 0x064, 0x071, 0x131, 0x313, 0x301, 0x380]
    dt2_delta = [0, 384, 500, 608]
    uploaded_tables = [
        ("opm_phase_step_packed", packed_phase),
        ("opm_detune_adjustment_packed", packed_detune),
        ("opm_sine_attenuation_packed", packed_sine),
        ("opm_power_packed", packed_power),
        ("opm_envelope_increment_packed", packed_increments),
        ("opm_algorithm_ops", algorithm_ops),
        ("opm_dt2_delta", dt2_delta),
    ]
    # Leave P:$0000-$0c7f available to the command kernel, then place the
    # expanded exact tables and their packed upload source contiguously. The
    # codec-rate kernels use the DSP56001's factory Y sine ROM, so no separate
    # waveform is uploaded.
    runtime_table_start = 0x0C80
    table_words = sum(len(values) for _, values in uploaded_tables)

    print("; Generated from third_party/mame/3rdparty/ymfm/src/ymfm_fm.ipp.")
    print("; The source tables are BSD-3-Clause licensed by their ymfm authors.")
    print("; Do not edit this build artifact by hand.")
    print()

    if host_output:
        print(f"YM_TABLE_WORDS        equ     {table_words}")
        print(f"YM_TABLE_UPLOAD_WORDS equ     {table_words + 1}")
        print()
        print("ym2151_table_upload:")
        print("        dc.l    DSP_CMD_LOAD_TABLES")
        for _, values in uploaded_tables:
            emit_m68k_table(values)
    else:
        # Falcon external P memory aliases external X/Y RAM. Keep the runtime
        # lookup block above the complete command kernel and its clock helpers.
        print(f"        org     y:${runtime_table_start:x}")
        print()
        emit_dsp_reservation("opm_phase_step", phase)
        emit_dsp_reservation("opm_envelope_increment", increments)
        emit_dsp_reservation("opm_detune_adjustment", detune)
        emit_dsp_reservation("opm_sine_attenuation", sine)
        emit_dsp_reservation("opm_power", power)
        print(f"YM_TABLE_WORDS equ     {table_words}")
        print("opm_uploaded_tables:")
        for name, values in uploaded_tables:
            emit_dsp_reservation(name, values)
        print("opm_uploaded_tables_end:")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
