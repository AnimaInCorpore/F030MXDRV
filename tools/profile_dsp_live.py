#!/usr/bin/env python3
"""Measure the DSP's real-time occupancy during actual production playback.

The bracketed `profile-dsp-rt*` reports measure a synthetic fixture between two
render markers, so they exclude the SSI transmit interrupt, the host-port
receive, and the refill command itself. This probe instead arms Hatari's DSP
profiler at the Nth realtime-refill command of a real corpus song and saves it
`--periods` refills later, so the window covers whole production periods with
every cycle the DSP actually spends.

Cycles are split three ways:

* work      -- synthesis plus transport, including the SSI interrupt;
* host      -- self-looping `jclr #0,x:m_hsr,*` waits, i.e. the DSP stalled on
               the 68030 delivering the period's event and PCM words;
* boundary  -- the refill boundary spin and the SSI TDE wait, i.e. the DSP
               idle because it finished early.

Occupancy is work + host against the hardware budget of
`oscillator / 2 / sample-rate` instruction cycles per codec frame. Run it under
a DSP-calibrated Hatari; a build that hands the DSP two cycles per 68030 clock
reports the same work but roughly twice the boundary idle, because it is
measuring a machine with twice the Falcon's DSP throughput.
"""

from __future__ import annotations

import argparse
import bisect
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hatari_binary import default_hatari  # noqa: E402
from profile_dsp import parse_listing, parse_profile, require_symbol  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
TOS_ROM = REPO / "third_party/f030dsp3d/tools/tos402.rom"
SAMPLE_RATE = 32779.9479166667
FRAMES_PER_PERIOD = 512

# `jclr`/`jset` whose target is the instruction itself: a pure wait.
SELF_LOOP_RE = re.compile(
    r"^\s*\d+\s+P:([0-9A-F]{4})\s+[0-9A-F]{6}\s+j(?:clr|set)\s+\S+,\*", re.M
)


def collect_spins(listing: Path, symbols: dict) -> tuple[set[int], set[int]]:
    """Return (host-port wait PCs, SSI boundary wait PCs)."""
    text = listing.read_text(errors="replace")
    self_loops = {int(m.group(1), 16) for m in SELF_LOOP_RE.finditer(text)}

    # The boundary block runs from the wait label to the next label; its own
    # `jclr #m_tde,x:m_sr,*` is part of the same idle, not a host wait.
    start = require_symbol(symbols, "P", "command_rt_refill_wait_boundary")
    following = sorted(
        address
        for (space, _name), address in symbols.items()
        if space == "P" and address > start
    )
    stop = following[0] if following else start + 1
    boundary = set(range(start, stop))
    return self_loops - boundary, boundary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hatari", default=default_hatari(),
                        help=f"Hatari binary to run (default: {default_hatari()})")
    parser.add_argument("--corpus-dir", type=Path, default=REPO / "corpus")
    parser.add_argument("--song", default="XEVIOUS",
                        help="corpus basename to play (default: XEVIOUS)")
    parser.add_argument("--listing", type=Path, default=REPO / "build/dsp/YM2151.LST")
    parser.add_argument("--player", type=Path, default=REPO / "release/xevious.tos")
    parser.add_argument("--skip", type=int, default=300,
                        help="refills to let pass before arming (default: 300)")
    parser.add_argument("--periods", type=int, default=128,
                        help="refills to profile (default: 128)")
    parser.add_argument("--run-vbls", type=int, default=2000)
    parser.add_argument("--cpuclock", default="16")
    parser.add_argument("--output", type=Path, default=REPO / "build/dsp-profile-live/report.txt")
    parser.add_argument("--raw-profile", type=Path,
                        help="keep Hatari's raw per-PC DSP profile for analysis")
    args = parser.parse_args()

    if not shutil.which(args.hatari):
        sys.exit(f"error: profile-dsp-live needs Hatari ({args.hatari})")
    mdx = args.corpus_dir / f"{args.song}.MDX"
    pdx = args.corpus_dir / f"{args.song}.PDX"
    for path in (args.player, TOS_ROM, args.listing, mdx, pdx):
        if not path.is_file():
            sys.exit(f"error: missing required file: {path}")

    symbols = parse_listing(args.listing)
    entry = require_symbol(symbols, "P", "command_rt_refill_receive")
    host_pcs, boundary_pcs = collect_spins(args.listing, symbols)

    (REPO / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dsp-live-", dir=REPO / "build") as tmp:
        work = Path(tmp)
        shutil.copy(args.player, work / "xevious.tos")
        shutil.copy(mdx, work)
        shutil.copy(pdx, work)

        profile = work / "profile.txt"
        end = work / "end.ini"
        arm = work / "arm.ini"
        start = work / "start.ini"
        end.write_text(f"dp save {profile}\ndp off\n")
        arm.write_text(
            # The arm script itself runs on a matching refill entry. Hatari's
            # breakpoint counter includes that current hit, so N complete
            # entry-to-entry periods require the (N+1)th match.
            f"dp on\ndb pc = ${entry:04x} :{args.periods + 1} :once :trace :file {end}\n"
        )
        start.write_text(
            f"db pc = ${entry:04x} :{args.skip} :once :trace :file {arm}\n"
        )

        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        subprocess.run(
            [args.hatari, "--machine", "falcon", "--cpuclock", args.cpuclock,
             "--dsp", "emu", "--tos", str(TOS_ROM), "--patch-tos", "true",
             "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
             "--confirm-quit", "false", "--run-vbls", str(args.run_vbls),
             "--log-file", str(work / "hatari.log"),
             "--parse", str(start), str(work / "xevious.tos")],
            cwd=REPO, env=env, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=1800, check=False,
        )

        if not profile.is_file() or not profile.stat().st_size:
            sys.exit("error: Hatari did not capture a live DSP profile; the run "
                     f"may not have reached refill {args.skip}")
        if args.raw_profile:
            args.raw_profile.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(profile, args.raw_profile)
        hz, oscillator_cycles, rows = parse_profile(profile)

    total = oscillator_cycles / 2.0
    host = sum(c for pc, _i, c, _p in rows if pc in host_pcs) / 2.0
    boundary = sum(c for pc, _i, c, _p in rows if pc in boundary_pcs) / 2.0
    work_cycles = total - host - boundary

    frames = args.periods * FRAMES_PER_PERIOD
    budget_frame = hz / 2.0 / SAMPLE_RATE
    budget_window = budget_frame * frames

    labels = sorted(
        (address, name) for (space, name), address in symbols.items() if space == "P"
    )
    addresses = [address for address, _ in labels]
    blocks: defaultdict[str, int] = defaultdict(int)
    for pc, _instructions, cycles, _percent in rows:
        index = bisect.bisect_right(addresses, pc) - 1
        blocks[labels[index][1] if index >= 0 else f"p_${pc:04x}"] += cycles

    lines = [
        f"DSP56001 live production occupancy ({args.song}, {args.cpuclock} MHz 68030)",
        f"  Hatari binary:              {args.hatari}",
        f"  profiled refills:           {args.periods} (armed after {args.skip})",
        f"  Hatari DSP oscillator:      {hz:,} Hz",
        f"  measured instruction cycles: {total:,.0f}",
        f"  real-time budget for window: {budget_window:,.0f}",
        f"  window / real time:          {total / budget_window:.3f}x",
        "",
        f"  instruction cycles per codec frame (budget {budget_frame:,.2f}):",
        f"    synthesis and transport:  {work_cycles / frames:8,.2f}"
        f"   {100.0 * work_cycles / budget_window:6.1f}% of budget",
        f"    stalled on the host port: {host / frames:8,.2f}"
        f"   {100.0 * host / budget_window:6.1f}% of budget",
        f"    idle at the SSI boundary: {boundary / frames:8,.2f}"
        f"   {100.0 * boundary / budget_window:6.1f}% of budget",
        "",
        f"  DSP occupancy:              "
        f"{100.0 * (work_cycles + host) / budget_window:.1f}% of real time",
        f"  margin:                     "
        f"{budget_frame - (work_cycles + host) / frames:,.2f} cycles per frame",
        "",
        "Largest labeled basic blocks:",
    ]
    for name, cycles in sorted(blocks.items(), key=lambda item: -item[1])[:12]:
        lines.append(
            f"  {cycles * 100.0 / oscillator_cycles:6.2f}%  {cycles / 2.0:12,.0f}"
            f" instruction cycles  {name}"
        )

    report = "\n".join(lines) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report, encoding="utf-8")
    print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
