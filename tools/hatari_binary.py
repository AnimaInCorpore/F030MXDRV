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


def program_argument(path) -> str:
    """Spell a guest program path the way Hatari's GEMDOS mount expects.

    Hatari splits the program argument into a GEMDOS directory and a filename
    on the host's separator. MSYS2's Python reports ``os.name == 'nt'`` but
    sets ``os.sep`` to ``/``, so even an absolute path comes out
    forward-slashed; Hatari then finds nothing to split, mounts the current
    directory instead of the program's, and boots to the desktop without ever
    running the program -- while still exiting 0. Hand Windows a backslash
    path. POSIX hosts already use the separator Hatari expects.
    """
    text = os.fspath(path)
    if os.name == "nt":
        return text.replace("/", "\\")
    return text
