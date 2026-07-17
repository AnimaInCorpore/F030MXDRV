#!/usr/bin/env python3
"""Batch endurance gate: play every corpus MDX end to end under Hatari.

Runs the same scenario as `make endurance` (argument-less AUTOPLAY.INF
autoplay, blocking refill cadence, two loops + fade + clean shutdown) for
each release/*.MDX song. The Hatari trace is streamed through a FIFO and
scored on the fly -- refill count, Dsp_Unlock shutdown, protocol-error
replies -- so no multi-gigabyte trace file is ever written to disk. Only a
small rolling tail is kept, and saved just for failing songs.

Hatari is terminated early once the clean shutdown is observed, so each
song costs only its own playing time instead of the full VBL cap.
"""

import argparse
import collections
import os
import shutil
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(REPO, "release")
BATCH_DIR = os.path.join(REPO, "build", "endurance-batch")
TOS_ROM = os.path.join(REPO, "third_party", "f030dsp3d", "tools", "tos402.rom")

REFILL_PATTERN = "Direct Transfer 0x190000"
UNLOCK_PATTERN = "Dsp_Unlock"
PROTOCOL_ERROR_PATTERN = "Transfer 0xffffff"
PROTOCOL_ERROR_CONTEXT = "DSP->Host"

MIN_REFILLS = 200          # same floor as the Makefile endurance target
RUN_VBLS = 45000           # hard emulated-time cap (~15 min); unlock kills earlier
WALL_TIMEOUT = 1500        # seconds of wall clock per song before giving up
UNLOCK_GRACE = 3.0         # keep reading after unlock to catch late errors
TAIL_LINES = 4000


def read_pdx_name(mdx_path):
    """Return the PDX filename requested by an MDX header, or None."""
    data = open(mdx_path, "rb").read(512)
    eot = data.find(b"\x1a")
    if eot < 0:
        return None
    end = data.find(b"\x00", eot + 1)
    name = data[eot + 1 : end].decode("ascii", errors="replace").strip()
    if not name:
        return None
    stem = name.rsplit(".", 1)[0].upper()
    candidate = stem + ".PDX"
    if os.path.exists(os.path.join(RELEASE, candidate)):
        return candidate
    raise FileNotFoundError(f"{os.path.basename(mdx_path)} wants PDX {name!r}"
                            f" but {candidate} is not in release/")


class TraceScorer(threading.Thread):
    """Consume the Hatari trace FIFO and score it line by line."""

    def __init__(self, fifo_path):
        super().__init__(daemon=True)
        self.fifo_path = fifo_path
        self.refills = 0
        self.unlock_at = None
        self.protocol_error = None
        self.tail = collections.deque(maxlen=TAIL_LINES)

    def run(self):
        # Opens block until Hatari opens the write end.
        with open(self.fifo_path, "r", errors="replace") as fifo:
            for line in fifo:
                self.tail.append(line)
                if REFILL_PATTERN in line:
                    self.refills += 1
                elif UNLOCK_PATTERN in line:
                    if self.unlock_at is None:
                        self.unlock_at = time.monotonic()
                elif (PROTOCOL_ERROR_PATTERN in line
                      and PROTOCOL_ERROR_CONTEXT in line
                      and self.protocol_error is None):
                    self.protocol_error = line.strip()


def run_song(mdx_name, pdx_name, keep_dir):
    song = os.path.splitext(mdx_name)[0]
    work = os.path.join(BATCH_DIR, song)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    shutil.copy(os.path.join(RELEASE, "f030mxdrv.tos"), work)
    shutil.copy(os.path.join(RELEASE, mdx_name), work)
    tokens = mdx_name
    if pdx_name:
        shutil.copy(os.path.join(RELEASE, pdx_name), work)
        tokens += " " + pdx_name
    with open(os.path.join(work, "AUTOPLAY.INF"), "w", newline="") as inf:
        inf.write(tokens + "\r\n")

    fifo_path = os.path.join(work, "trace.fifo")
    os.mkfifo(fifo_path)
    scorer = TraceScorer(fifo_path)
    scorer.start()

    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    cmd = [
        "hatari", "--machine", "falcon", "--dsp", "emu",
        "--tos", TOS_ROM, "--patch-tos", "true",
        "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
        "--confirm-quit", "false", "--run-vbls", str(RUN_VBLS),
        "--log-file", os.path.join(work, "hatari.log"),
        "--trace-file", fifo_path,
        "--trace", "gemdos,dsp_host_interface,xbios",
        os.path.join(work, "f030mxdrv.tos"),
    ]
    started = time.monotonic()
    proc = subprocess.Popen(cmd, cwd=REPO, env=env,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    timed_out = False
    while proc.poll() is None:
        now = time.monotonic()
        if scorer.unlock_at is not None and now - scorer.unlock_at > UNLOCK_GRACE:
            proc.terminate()
            break
        if now - started > WALL_TIMEOUT:
            timed_out = True
            proc.terminate()
            break
        time.sleep(0.5)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    scorer.join(timeout=30)
    elapsed = time.monotonic() - started

    reasons = []
    if scorer.protocol_error:
        reasons.append("protocol-error: " + scorer.protocol_error)
    if scorer.unlock_at is None:
        reasons.append("timeout waiting for Dsp_Unlock" if timed_out
                       else "no Dsp_Unlock (VBL cap hit before shutdown)")
    if scorer.refills < MIN_REFILLS:
        reasons.append(f"refills {scorer.refills} < {MIN_REFILLS}")

    verdict = "PASS" if not reasons else "FAIL"
    if verdict == "FAIL":
        tail_path = os.path.join(BATCH_DIR, song + "-tail.txt")
        with open(tail_path, "w") as tail:
            tail.writelines(scorer.tail)
    if verdict == "PASS" and not keep_dir:
        shutil.rmtree(work, ignore_errors=True)
    else:
        os.unlink(fifo_path)

    return {
        "song": song, "verdict": verdict, "refills": scorer.refills,
        "unlock": scorer.unlock_at is not None, "elapsed": elapsed,
        "reasons": reasons,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("songs", nargs="*",
                        help="MDX basenames to run (default: every release/*.MDX)")
    parser.add_argument("--keep-workdirs", action="store_true",
                        help="keep per-song work directories even on PASS")
    args = parser.parse_args()

    if not shutil.which("hatari"):
        sys.exit("error: endurance batch needs Hatari")
    if args.songs:
        corpus = [s if s.upper().endswith(".MDX") else s + ".MDX"
                  for s in args.songs]
        corpus = [s.upper() for s in corpus]
    else:
        corpus = sorted(f for f in os.listdir(RELEASE) if f.endswith(".MDX"))
        # Known-good reference song first, as the canary.
        if "XEVIOUS.MDX" in corpus:
            corpus.remove("XEVIOUS.MDX")
            corpus.insert(0, "XEVIOUS.MDX")

    os.makedirs(BATCH_DIR, exist_ok=True)
    scoreboard_path = os.path.join(BATCH_DIR, "scoreboard.txt")
    results = []
    with open(scoreboard_path, "w", buffering=1) as scoreboard:
        for mdx_name in corpus:
            pdx_name = read_pdx_name(os.path.join(RELEASE, mdx_name))
            result = run_song(mdx_name, pdx_name, args.keep_workdirs)
            results.append(result)
            line = (f"{result['verdict']}  {result['song']:<10}"
                    f" refills={result['refills']:<6}"
                    f" unlock={'yes' if result['unlock'] else 'NO'}"
                    f" wall={result['elapsed']:.0f}s")
            if result["reasons"]:
                line += "  [" + "; ".join(result["reasons"]) + "]"
            scoreboard.write(line + "\n")
            print(line, flush=True)

    failed = [r for r in results if r["verdict"] == "FAIL"]
    print(f"\n{len(results) - len(failed)}/{len(results)} songs passed")
    if failed:
        print("failing tails kept in " + BATCH_DIR)
        sys.exit(1)
    print("Hatari corpus endurance playback: OK")


if __name__ == "__main__":
    main()
