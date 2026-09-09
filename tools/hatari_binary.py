"""Resolve which Hatari binary the emulator gates should run.

Stock Hatari grants the Falcon DSP twice the cycles the hardware has (32 MIPS
instead of 16) and models the CPU-to-DSP host port at 72-174 % of hardware
speed, so any throughput or real-time result taken from it describes a machine
that does not exist. The DSP-calibrated build in the F030Arcade tree fixes both
and is the default here; see docs/hatari-timing.md.

Resolution order: the ``HATARI`` environment variable, then a calibrated build
under ``F030ARCADE``, ``~/Work/F030Arcade`` or a sibling of this repository,
then ``hatari`` on ``PATH``. The checkout is not always under ``~/Work``, and a
Windows host configures the tree as ``build-ucrt64`` and links ``hatari.exe``,
so search those spellings rather than hard-coding one. This mirrors the
Makefile's HATARI_CANDIDATES; keep the two in step.
"""

import os

CALIBRATED_BUILDS = ("build", "build-ucrt64")
CALIBRATED_NAMES = ("hatari", "hatari.exe")

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _calibrated_roots():
    roots = []
    arcade = os.environ.get("F030ARCADE")
    if arcade:
        roots.append(arcade)
    roots.append(os.path.expanduser("~/Work/F030Arcade"))
    roots.append(os.path.join(os.path.dirname(_REPO), "F030Arcade"))
    return roots


def default_hatari() -> str:
    override = os.environ.get("HATARI")
    if override:
        return override
    for root in _calibrated_roots():
        for build in CALIBRATED_BUILDS:
            for name in CALIBRATED_NAMES:
                calibrated = os.path.join(
                    root, "third_party", "hatari", build, "src", name)
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
