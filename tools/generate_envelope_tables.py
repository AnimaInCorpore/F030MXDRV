#!/usr/bin/env python3
"""Generate the realtime block envelope tables from the vendored ymfm source.

The realtime block engine advances every envelope-active operator once per
64-frame block with one affine step, level' = a*level + b, in 10.13 fixed
point; the capture harness derives mid-block levels analytically from the
same recurrence. The per-rate constants compose the exact per-tick YM2151
recurrence over the average number of envelope ticks in one block:

- one 64-frame block spans 64*1280/1007 native samples and the envelope
  divider ticks every third native sample, so a block averages
  64*1280/1007/3 = 27.117... ticks;
- rates with shift = rate>>2 below 11 qualify only every 2^(11-shift) ticks;
- attack composes the exact per-tick affine env' = env*(1-inc/16) - inc/16
  over the rate's eight-entry increment pattern, then takes the fractional
  tick power; its fixed point is exactly -1, so the block addend is derived
  on the DSP as a - 1 and only the multiplier is stored;
- decay, sustain, and release accumulate the pattern's mean increment.

Attack rates 62 and 63 store a frozen (unity) multiplier: the exact engine
never updates an attacking envelope at those rates, and key-on handles them
by starting from zero attenuation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FRAC = 13
BLOCK_FRAMES = 64
BLOCK_TICKS = BLOCK_FRAMES * 1280 / 1007 / 3
UNITY = (1 << 23) - 1


def load_increments(source_path: Path) -> list[list[int]]:
    source = source_path.read_text(encoding="utf-8")
    start = source.index("s_increment_table[64]")
    start = source.index("{", start) + 1
    end = source.index("};", start)
    body = re.sub(r"//.*", "", source[start:end])
    words = [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", body)]
    if len(words) != 64:
        raise RuntimeError(f"ymfm increment table shape changed: {len(words)} words")
    return [[(word >> (4 * index)) & 0xF for index in range(8)] for word in words]


def emit_table(name: str, values: list[int], width: int = 8) -> None:
    print(f"{name}:")
    for offset in range(0, len(values), width):
        row = ",".join(f"${value & 0xFFFFFF:06x}" for value in values[offset : offset + width])
        print(f"        dc      {row}")
    print()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} path/to/ymfm_fm.ipp", file=sys.stderr)
        return 2
    increments = load_increments(Path(sys.argv[1]))

    attack: list[int] = []
    decay: list[int] = []
    for rate in range(64):
        pattern = increments[rate]
        shift = rate >> 2
        ticks = BLOCK_TICKS / (1 << (11 - shift)) if shift < 11 else BLOCK_TICKS
        a8, b8 = 1.0, 0.0
        for inc in pattern:
            a8, b8 = (1.0 - inc / 16.0) * a8, (1.0 - inc / 16.0) * b8 - inc / 16.0
        if a8 >= 1.0 or rate >= 62:
            attack.append(UNITY)
        else:
            attack.append(min(int(round(a8 ** (ticks / 8.0) * (1 << 23))), UNITY))
        mean = sum(pattern) / 8.0
        decay.append(int(round(mean * ticks * (1 << FRAC))))

    env_fraction = [
        min(int(round(2.0 ** (-frac / 64.0) * (1 << 23))), UNITY) for frac in range(64)
    ]
    # ymfm's full-volume operator peaks at 8191 of the signed 16-bit output
    # range, so the 0.23 amplitude convention carries that same 1/4 relative
    # level. Everything the kernel derives from gains inherits it: serial
    # modulation and feedback depth land at ymfm's scale, and a four-carrier
    # sum peaks at exactly full scale instead of clipping the limiter.
    tl_fraction = [
        min(int(round(2.0 ** (-frac / 8.0) * (1 << 21))), UNITY) for frac in range(8)
    ]
    # operator-major index (logical*8 + channel) to raw register slot and to
    # the channel-major phase/gain index; logical order is M1,C1,M2,C2.
    slotmap = [(op & 7) | ((op & 8) << 1) | ((op & 16) >> 1) for op in range(32)]
    gainmap = [((op & 7) << 2) | (op >> 3) for op in range(32)]
    sustain = [
        ((d1l | ((d1l + 1) & 0x10)) << 5) << FRAC for d1l in range(16)
    ]

    print("; Generated from third_party/mame/3rdparty/ymfm/src/ymfm_fm.ipp by")
    print("; tools/generate_envelope_tables.py. Do not edit this build artifact.")
    print()
    emit_table("rt5_attack_factor", attack)
    emit_table("rt5_decay_step", decay)
    emit_table("rt5_env_fraction", env_fraction)
    emit_table("rt5_tl_fraction", tl_fraction)
    emit_table("rt5_env_slotmap", slotmap)
    emit_table("rt5_env_gainmap", gainmap)
    emit_table("rt5_env_sustain", sustain)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
