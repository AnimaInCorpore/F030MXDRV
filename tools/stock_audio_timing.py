#!/usr/bin/env python3
"""Gate production SSI refill timing at stock Falcon clock rates.

Boots the dedicated Xevious player at 16 MHz with the DSP at its normal
32 MHz, streams Hatari's SSI trace through a FIFO, and verifies that every
completed 1024-frame production buffer hands off on the next boundary.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAYER = os.path.join(REPO, "release", "xevious.tos")
TOS_ROM = os.path.join(
    REPO, "third_party", "f030dsp3d", "tools", "tos402.rom"
)

PDX_PATTERN = "GEMDOS: XEVIOUS.PDX"
SSI_WORD_PATTERN = "Dsp SSI transmit value to crossbar:"
SWITCH_PATTERN = "Dsp SSI CRB write: 0x005a00"
REFILL_PATTERN = "Direct Transfer 0x190000"
HOST_DIRECT_RE = re.compile(r"\(Host->DSP\): Direct Transfer 0x([0-9a-fA-F]+)")
PROTOCOL_ERROR_PATTERN = "Transfer 0xffffff"
PROTOCOL_ERROR_CONTEXT = "DSP->Host"
WORDS_PER_PERIOD = 1024 * 2


class TraceScorer(threading.Thread):
    """Consume the trace FIFO without writing a many-megabyte trace file."""

    def __init__(self, fifo_path):
        super().__init__(daemon=True)
        self.fifo_path = fifo_path
        self.production = False
        self.ssi_words = 0
        self.switch_words = []
        self.refills = 0
        self.awaiting_refill_payload = False
        self.batch_counts = []
        self.protocol_error = None
        self.failure = None

    def run(self):
        try:
            with open(self.fifo_path, "r", errors="replace") as fifo:
                for line in fifo:
                    if PDX_PATTERN in line:
                        self.production = True
                    if SSI_WORD_PATTERN in line:
                        self.ssi_words += 1
                    if not self.production:
                        continue
                    if SWITCH_PATTERN in line:
                        self.switch_words.append(self.ssi_words)
                    elif REFILL_PATTERN in line:
                        self.refills += 1
                        self.awaiting_refill_payload = True
                    elif self.awaiting_refill_payload:
                        match = HOST_DIRECT_RE.search(line)
                        if match:
                            self.batch_counts.append(int(match.group(1), 16))
                            self.awaiting_refill_payload = False
                    elif (PROTOCOL_ERROR_PATTERN in line
                          and PROTOCOL_ERROR_CONTEXT in line
                          and self.protocol_error is None):
                        self.protocol_error = line.strip()
        except OSError as error:
            self.failure = str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-vbls", type=int, default=1500,
                        help="Hatari emulated-time cap (default: 1500)")
    parser.add_argument("--min-switches", type=int, default=600,
                        help="minimum production buffer handoffs (default: 600)")
    parser.add_argument("--min-batch-words", type=int, default=33,
                        help="minimum observed YM burst size (default: 33)")
    parser.add_argument("--wall-timeout", type=int, default=180,
                        help="Hatari wall-time cap in seconds (default: 180)")
    args = parser.parse_args()

    if not shutil.which("hatari"):
        sys.exit("error: stock audio timing gate needs Hatari")
    for path in (PLAYER, TOS_ROM):
        if not os.path.isfile(path):
            sys.exit(f"error: missing required file: {path}")

    build_dir = os.path.join(REPO, "build")
    os.makedirs(build_dir, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stock-audio-", dir=build_dir) as work:
        fifo_path = os.path.join(work, "trace.fifo")
        os.mkfifo(fifo_path)
        scorer = TraceScorer(fifo_path)
        scorer.start()

        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        command = [
            "hatari", "--machine", "falcon", "--cpuclock", "16",
            "--dsp", "emu", "--tos", TOS_ROM, "--patch-tos", "true",
            "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
            "--confirm-quit", "false", "--run-vbls", str(args.run_vbls),
            "--log-file", os.path.join(work, "hatari.log"),
            "--trace-file", fifo_path,
            "--trace", "gemdos,dsp_host_interface,dsp_host_ssi,xbios",
            PLAYER,
        ]
        try:
            completed = subprocess.run(
                command, cwd=REPO, env=env, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=args.wall_timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            sys.exit(f"error: Hatari exceeded {args.wall_timeout}s wall time")
        scorer.join(timeout=30)

        reasons = []
        if completed.returncode:
            reasons.append(f"Hatari exited with status {completed.returncode}")
        if scorer.is_alive():
            reasons.append("trace reader did not reach EOF")
        if scorer.failure:
            reasons.append("trace reader failed: " + scorer.failure)
        if not scorer.production:
            reasons.append("Xevious PDX load was not observed")
        if scorer.protocol_error:
            reasons.append("protocol error: " + scorer.protocol_error)
        if len(scorer.switch_words) < args.min_switches:
            reasons.append(
                f"only {len(scorer.switch_words)} buffer handoffs; "
                f"need {args.min_switches}"
            )

        intervals = [
            later - earlier
            for earlier, later in zip(scorer.switch_words, scorer.switch_words[1:])
        ]
        # Hatari can log the cold-start CRB write on the opposite side of the
        # simultaneous first SSI transfer. That affects only the first measured
        # interval by one trace word; every warm handoff must be exactly 2048.
        if intervals and intervals[0] not in (WORDS_PER_PERIOD,
                                               WORDS_PER_PERIOD + 1):
            reasons.append(f"cold-start interval is {intervals[0]} SSI words")
        late = [
            (index + 2, interval)
            for index, interval in enumerate(intervals[1:])
            if interval != WORDS_PER_PERIOD
        ]
        if late:
            preview = ", ".join(f"#{index}={words}" for index, words in late[:5])
            reasons.append("missed steady buffer boundary: " + preview)
        if scorer.refills < args.min_switches:
            reasons.append(
                f"only {scorer.refills} realtime refill commands; "
                f"need {args.min_switches}"
            )
        largest_batch = max(scorer.batch_counts, default=0)
        if largest_batch < args.min_batch_words:
            reasons.append(
                f"largest YM burst was {largest_batch} words; "
                f"need {args.min_batch_words} to cross the former overflow"
            )

        if reasons:
            for reason in reasons:
                print("FAIL: " + reason, file=sys.stderr)
            sys.exit(1)

        first = intervals[0] if intervals else 0
        print(
            "Stock Falcon SSI timing: OK "
            f"({len(scorer.switch_words)} handoffs, {scorer.refills} refills, "
            f"largest YM burst {largest_batch} words, "
            f"cold interval {first}, {len(intervals) - 1} steady intervals "
            f"at {WORDS_PER_PERIOD} words)"
        )


if __name__ == "__main__":
    main()
