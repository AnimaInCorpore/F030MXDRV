#!/usr/bin/env python3
"""Record the DSP's cost of every production payload on its own.

`profile_dsp_live.py` averages over a window. This probe instead chains one
Hatari DSP-profile snapshot per buffer handoff: the profiler is armed at the
Nth realtime refill, and a breakpoint on `command_rt_refill_at_boundary`
saves the profile and re-arms itself for the next handoff, `--periods` times.
Hatari's `dp save` resets the counters, so each snapshot is exactly one
handoff interval: one period when the deadline held, two when the DSP had to
repeat the previous period.

Each line of the report is one interval: how many periods it spanned, how
many payloads were rendered in it (normally one), the synthesis-and-transport
cost per frame of that payload, and the labeled blocks that dominated it. The
per-payload column is what a deadline is decided on; a payload above the
budget of `oscillator / 2 / sample-rate` cycles per frame is a repeat.

Run it under the DSP-calibrated Hatari, like every other realtime probe.
"""

from __future__ import annotations

import argparse
import bisect
import os
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hatari_binary import default_hatari, program_argument  # noqa: E402
from profile_dsp import parse_listing, parse_profile, require_symbol  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
TOS_ROM = REPO / "third_party/f030dsp3d/tools/tos402.rom"
SAMPLE_RATE = 32779.9479166667
FRAMES_PER_PERIOD = 512


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hatari", default=default_hatari())
    parser.add_argument("--corpus-dir", type=Path, default=REPO / "corpus")
    parser.add_argument("--song", default="XEVIOUS",
                        help="corpus basename to play (default: XEVIOUS)")
    parser.add_argument("--listing", type=Path, default=REPO / "build/dsp/YM2151.LST")
    parser.add_argument("--player", type=Path,
                        help="player binary (default: release/xevious.tos for XEVIOUS, "
                             "release/f030mxdrv.tos with AUTOPLAY.INF otherwise)")
    parser.add_argument("--skip", type=int, default=300,
                        help="refills to let pass before the first snapshot (default: 300)")
    parser.add_argument("--periods", type=int, default=32,
                        help="handoff intervals to record (default: 32)")
    parser.add_argument("--run-vbls", type=int, default=2000)
    parser.add_argument("--cpuclock", default="16")
    parser.add_argument("--blocks", type=int, default=8,
                        help="labeled blocks to list per interval (default: 8)")
    parser.add_argument("--output", type=Path,
                        default=REPO / "build/dsp-profile-live/payloads.txt")
    args = parser.parse_args()

    if not shutil.which(args.hatari):
        sys.exit(f"error: profile-dsp-payloads needs Hatari ({args.hatari})")
    mdx = args.corpus_dir / f"{args.song}.MDX"
    pdx = args.corpus_dir / f"{args.song}.PDX"
    dedicated = args.song.upper() == "XEVIOUS"
    if args.player is None:
        args.player = REPO / ("release/xevious.tos" if dedicated else "release/f030mxdrv.tos")
    for path in (args.player, TOS_ROM, args.listing, mdx):
        if not path.is_file():
            sys.exit(f"error: missing required file: {path}")

    symbols = parse_listing(args.listing)
    entry = require_symbol(symbols, "P", "command_rt_refill_at_boundary")
    owned = require_symbol(symbols, "P", "command_rt_refill_owned")
    wait_start = require_symbol(symbols, "P", "command_rt_refill_wait_service")
    wait_stop = require_symbol(symbols, "P", "command_rt_refill_wait_write")
    labels = sorted((address, name) for (space, name), address in symbols.items()
                    if space == "P")
    addresses = [address for address, _ in labels]

    (REPO / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dsp-payloads-", dir=REPO / "build") as tmp:
        work = Path(tmp)
        player = work / ("xevious.tos" if dedicated else "f030mxdrv.tos")
        shutil.copy(args.player, player)
        shutil.copy(mdx, work)
        if pdx.is_file():
            shutil.copy(pdx, work)
        if not dedicated:
            (work / "AUTOPLAY.INF").write_bytes(f"{args.song.upper()}.MDX\r\n".encode())

        # Every snapshot script saves the profile and arms the next one; the
        # breakpoint counter includes the current hit, so `:2` is one handoff.
        for index in range(args.periods + 1):
            body = f"dp save {work}/p{index}.txt\n"
            if index < args.periods:
                body += (f"db pc = ${entry:04x} :2 :once :trace"
                         f" :file {work}/s{index + 1}.ini\n")
            else:
                body += "dp off\n"
            (work / f"s{index}.ini").write_text(body)
        (work / "arm.ini").write_text(
            f"dp on\ndb pc = ${entry:04x} :2 :once :trace :file {work}/s0.ini\n")
        (work / "start.ini").write_text(
            f"db pc = ${entry:04x} :{args.skip} :once :trace :file {work}/arm.ini\n")

        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        subprocess.run(
            [args.hatari, "--machine", "falcon", "--cpuclock", args.cpuclock,
             "--dsp", "emu", "--tos", str(TOS_ROM), "--patch-tos", "true",
             "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
             "--confirm-quit", "false", "--run-vbls", str(args.run_vbls),
             "--log-file", str(work / "hatari.log"),
             "--parse", str(work / "start.ini"), program_argument(player)],
            cwd=work, env=env, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=1800, check=False,
        )

        snapshots = []
        for index in range(args.periods + 1):
            path = work / f"p{index}.txt"
            if not path.is_file() or not path.stat().st_size:
                continue
            hz, oscillator_cycles, rows = parse_profile(path)
            total = oscillator_cycles / 2.0
            wait = 0.0
            payloads = 0
            blocks: defaultdict[str, float] = defaultdict(float)
            for pc, instructions, cycles, _percent in rows:
                if wait_start <= pc < wait_stop:
                    wait += cycles / 2.0
                if pc == owned:
                    payloads = instructions
                slot = bisect.bisect_right(addresses, pc) - 1
                blocks[labels[slot][1] if slot >= 0 else f"p_${pc:04x}"] += cycles / 2.0
            snapshots.append((hz, total, wait, payloads, blocks))

    if not snapshots:
        sys.exit("error: Hatari saved no profile snapshot; the run may not have "
                 f"reached refill {args.skip}")
    hz = snapshots[0][0]
    budget_frame = hz / 2.0 / SAMPLE_RATE
    lines = [
        f"DSP56001 cost per production payload ({args.song}, {args.cpuclock} MHz 68030)",
        f"  Hatari binary:            {args.hatari}",
        f"  intervals recorded:       {len(snapshots)} (armed after refill {args.skip})",
        f"  budget per codec frame:   {budget_frame:,.2f} instruction cycles",
        "",
        "interval  periods  payloads  work/frame  heaviest labeled blocks (cycles per payload frame)",
    ]
    for index, (_hz, total, wait, payloads, blocks) in enumerate(snapshots):
        frames = max(payloads, 1) * FRAMES_PER_PERIOD
        work_cycles = total - wait
        top = sorted(((cycles / frames, name) for name, cycles in blocks.items()
                      if name != "command_rt_refill_wait_service"), reverse=True)
        heaviest = ", ".join(f"{name}={cost:.0f}" for cost, name in top[:args.blocks])
        lines.append(
            f"{index:8d}  {total / (budget_frame * FRAMES_PER_PERIOD):7.2f}"
            f"  {payloads:8d}  {work_cycles / frames:10.1f}  {heaviest}"
        )
    report = "\n".join(lines) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report, encoding="utf-8")
    print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
