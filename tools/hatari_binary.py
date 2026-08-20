"""Resolve which Hatari binary the emulator gates should run.

Stock Hatari grants the Falcon DSP twice the cycles the hardware has (32 MIPS
instead of 16) and models the CPU-to-DSP host port at 72-174 % of hardware
speed, so any throughput or real-time result taken from it describes a machine
that does not exist. The DSP-calibrated build in the F030Arcade tree fixes both
and is the default here; see docs/hatari-timing.md.

Resolution order: the ``HATARI`` environment variable, then the calibrated
build under ``F030ARCADE`` (default ``~/Work/F030Arcade``), then ``hatari`` on
``PATH``.
"""

import os

CALIBRATED_SUFFIX = os.path.join("third_party", "hatari", "build", "src", "hatari")


def default_hatari() -> str:
    override = os.environ.get("HATARI")
    if override:
        return override
    arcade = os.environ.get("F030ARCADE") or os.path.expanduser("~/Work/F030Arcade")
    calibrated = os.path.join(arcade, CALIBRATED_SUFFIX)
    if os.path.isfile(calibrated) and os.access(calibrated, os.X_OK):
        return calibrated
    return "hatari"
