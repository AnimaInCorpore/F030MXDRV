#!/usr/bin/env python3
"""Capture the realtime DSP kernel's block-boundary state under Hatari.

For every perceptual scenario this harness compiles the exact trace into a
CAPTURE.SCN consumed by the TTP's capture mode, replays it through the
protocol-v19 realtime stream inside Hatari, and collects DSP state dumps from
debugger breakpoints at every 64-frame block entry and at every completed
1024-frame buffer. A reconstruction pass turns those dumps into the
per-codec-frame TSV rows accepted by tools/compare_ym2151_realtime.py.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from profile_dsp import parse_listing, require_symbol  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BLOCK_FRAMES = 64
BUFFER_FRAMES = 1024
CODEC_NUMERATOR = 1280
CODEC_DENOMINATOR = 1007
FNV_OFFSET = 2_166_136_261
FNV_PRIME = 16_777_619

# name -> (trace file, codec frames, algorithm override, feedback override)
SCENARIOS: dict[str, tuple[str, int, int | None, int | None]] = {
    "pitch": ("perceptual_pitch.trace", 8192, None, None),
    "timing": ("perceptual_timing.trace", 2048, None, None),
    "envelope": ("perceptual_envelope.trace", 8192, None, None),
    "lfo": ("perceptual_lfo.trace", 8192, None, None),
    "noise": ("noise_channel7.trace", 8192, None, None),
    **{
        f"algorithm-{index}": ("attack_all_carriers.trace", 4096, index, 4)
        for index in range(8)
    },
    "feedback-0": ("attack_all_carriers.trace", 4096, 0, 0),
    "feedback-7": ("attack_all_carriers.trace", 4096, 0, 7),
}

# Symbol-anchored dump ranges shared by both breakpoint scripts. Each entry is
# (memory space, first symbol, last symbol, extra words past the last symbol).
STATE_RANGES: tuple[tuple[str, str, str, int], ...] = (
    ("x", "rt5_native_phase", "rt5_timer_status", 0),
    ("x", "rt5_phase", "rt5_phase", 31),
    ("y", "rt5_phase", "rt5_phase", 31),
    ("y", "rt5_env_a", "rt5_operator_increment", 31),
    ("x", "rt5_env_state", "rt5_env_key_phase", 0),
    ("x", "rt5_env_target", "rt5_runtime_output", 0),
    ("y", "rt5_env_b", "rt5_env_b", 31),
    ("x", "rt5_channel_control", "rt5_channel_control", 7),
    ("x", "ym_queue_count", "ssi_refill_buffer", 0),
)
BUFFER_RANGES: tuple[tuple[str, str, str, int], ...] = (
    ("x", "ssi_buffer_a", "ssi_buffer_a", 2047),
    ("x", "ssi_buffer_b", "ssi_buffer_b", 2047),
)
STATE_MARKER = 0
BUFFER_MARKER = 1


@dataclass
class TraceEvent:
    sample: int
    reg: int
    data: int


@dataclass
class Record:
    kind: int
    words: dict[tuple[str, int], int] = field(default_factory=dict)

    def array(self, space: str, base: int, count: int) -> list[int]:
        return [self.words[(space, base + index)] for index in range(count)]


def load_trace(path: Path) -> list[TraceEvent]:
    events: list[TraceEvent] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        sample_text, register_text, data_text = line.split()
        events.append(
            TraceEvent(int(sample_text), int(register_text, 16), int(data_text, 16))
        )
    if any(a.sample > b.sample for a, b in zip(events, events[1:])):
        raise ValueError(f"{path}: events are not in nondecreasing order")
    return events


def apply_overrides(
    events: list[TraceEvent], algorithm: int | None, feedback: int | None
) -> list[TraceEvent]:
    adjusted: list[TraceEvent] = []
    for event in events:
        data = event.data
        if event.reg == 0x20:
            if algorithm is not None:
                data = (data & ~0x07) | algorithm
            if feedback is not None:
                data = (data & ~0x38) | (feedback << 3)
        adjusted.append(TraceEvent(event.sample, event.reg, data))
    return adjusted


def compile_scenario(events: list[TraceEvent], frames: int) -> bytes:
    if frames % BUFFER_FRAMES:
        raise ValueError("frame count must be a whole number of 1024-frame buffers")
    if len(events) > 32:
        raise ValueError("scenario does not fit the 32-entry FIFO ring")
    blob = struct.pack(">4sLHH", b"SCN1", frames, len(events), 0)
    for event in events:
        if not 0 <= event.sample <= 0x7FFF:
            raise ValueError("event timestamp exceeds the FIFO horizon")
        blob += struct.pack(">HBB", event.sample, event.reg, event.data)
    return blob


def resolve_ranges(
    symbols: dict[tuple[str, str], int],
    ranges: tuple[tuple[str, str, str, int], ...],
) -> list[tuple[str, int, int]]:
    resolved = []
    for space, first, last, extra in ranges:
        start = require_symbol(symbols, space.upper(), first)
        end = require_symbol(symbols, space.upper(), last) + extra
        if end < start:
            raise SystemExit(f"error: dump range {first}..{last} is inverted")
        resolved.append((space, start, end))
    return resolved


def first_reply_after(listing: Path, address: int) -> int:
    """P address of the first `jsr send_reply` at or after the given address.

    A `do`-loop's end label cannot host a one-shot breakpoint: Hatari samples
    the DSP PC at loop-end+1 on every iteration. Each realtime start/refill
    handler instead sends exactly one OK reply after its sixteen blocks, so
    that `jsr` is the reliable buffer-completion marker.
    """
    pattern = re.compile(r"^\s*\d+\s+P:([0-9A-F]+)\s+[0-9A-F]+\s+jsr\s+send_reply\b")
    candidates = []
    for line in listing.read_text(errors="replace").splitlines():
        match = pattern.match(line)
        if match:
            candidates.append(int(match.group(1), 16))
    following = [value for value in sorted(candidates) if value >= address]
    if not following:
        raise SystemExit(f"error: no `jsr send_reply` found after P:{address:04x}")
    return following[0]


def write_debug_scripts(
    directory: Path, symbols: dict[tuple[str, str], int], listing: Path
) -> Path:
    block_entry = require_symbol(symbols, "P", "rt5_render_runtime_block")
    start_done = first_reply_after(
        listing, require_symbol(symbols, "P", "command_start_realtime_mixed")
    )
    refill_done = first_reply_after(
        listing, require_symbol(symbols, "P", "command_refill_realtime_mixed")
    )

    state_ranges = resolve_ranges(symbols, STATE_RANGES)
    buffer_ranges = state_ranges + resolve_ranges(symbols, BUFFER_RANGES)

    def script(marker: int, ranges: list[tuple[str, int, int]]) -> str:
        lines = [f"dm p ${marker:x}-${marker:x}"]
        lines += [f"dm {space} ${start:x}-${end:x}" for space, start, end in ranges]
        return "\n".join(lines) + "\n"

    state_ini = (directory / "state.ini").resolve()
    buffer_ini = (directory / "buffer.ini").resolve()
    start_ini = (directory / "start.ini").resolve()
    state_ini.write_text(script(STATE_MARKER, state_ranges), encoding="utf-8")
    buffer_ini.write_text(script(BUFFER_MARKER, buffer_ranges), encoding="utf-8")
    start_ini.write_text(
        f"db pc = ${block_entry:04x} :trace :quiet :file {state_ini}\n"
        f"db pc = ${start_done:04x} :trace :quiet :file {buffer_ini}\n"
        f"db pc = ${refill_done:04x} :trace :quiet :file {buffer_ini}\n",
        encoding="utf-8",
    )
    return start_ini


INTERNAL_WORD_RE = re.compile(r"^([XY]) ram:([0-9a-fA-F]+)\s+([0-9a-fA-F]+)")
EXTERNAL_WORD_RE = re.compile(r"^([XY]):([0-9a-fA-F]+) \(P:[0-9a-fA-F]+\): ([0-9a-fA-F]+)")


def parse_dumps(text: str) -> list[Record]:
    records: list[Record] = []
    current: Record | None = None
    for line in text.splitlines():
        if line.startswith("DSP memdump from ") and line.endswith("in 'P' address space:"):
            marker = int(line.split()[3], 16)
            current = Record(kind=marker)
            records.append(current)
            continue
        if current is None:
            continue
        match = INTERNAL_WORD_RE.match(line) or EXTERNAL_WORD_RE.match(line)
        if match:
            space = match.group(1).lower()
            current.words[(space, int(match.group(2), 16))] = int(match.group(3), 16)
    return records


def run_scenario(
    name: str,
    build_dir: Path,
    tos_image: Path,
    symbols: dict[tuple[str, str], int],
    listing: Path,
    hatari: str,
    run_vbls: int,
) -> tuple[list[Record], list[TraceEvent], int]:
    trace_name, frames, algorithm, feedback = SCENARIOS[name]
    events = apply_overrides(
        load_trace(REPO / "tests" / "traces" / trace_name), algorithm, feedback
    )

    directory = build_dir / name
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    shutil.copy(tos_image, directory / "F030MXDRV.TOS")
    (directory / "CAPTURE.SCN").write_bytes(compile_scenario(events, frames))
    start_ini = write_debug_scripts(directory, symbols, listing)

    environment = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    result = subprocess.run(
        [
            hatari,
            "--machine", "falcon",
            "--dsp", "emu",
            "--tos", str(REPO / "third_party/f030dsp3d/tools/tos402.rom"),
            "--patch-tos", "true",
            "--fast-boot", "true",
            "--fast-forward", "true",
            "--sound", "off",
            "--confirm-quit", "false",
            "--run-vbls", str(run_vbls),
            "--log-file", str(directory / "hatari.log"),
            "--parse", str(start_ini),
            str(directory / "F030MXDRV.TOS"),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=environment,
        cwd=REPO,
    )
    (directory / "dumps.txt").write_text(result.stdout, encoding="utf-8")

    records = parse_dumps(result.stdout)
    state_records = sum(1 for record in records if record.kind == STATE_MARKER)
    buffer_records = sum(1 for record in records if record.kind == BUFFER_MARKER)
    expected_states = frames // BLOCK_FRAMES
    expected_buffers = frames // BUFFER_FRAMES
    if state_records != expected_states or buffer_records != expected_buffers:
        raise SystemExit(
            f"error: {name}: captured {state_records}/{expected_states} block dumps "
            f"and {buffer_records}/{expected_buffers} buffer dumps; "
            f"see {directory / 'dumps.txt'} and {directory / 'hatari.log'}"
        )
    return records, events, frames


def reconstruct_rows(name, records, events, frames, symbols):
    raise SystemExit("error: reconstruction is not implemented yet")


def write_vector(path, name, rows):
    raise SystemExit("error: reconstruction is not implemented yet")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tos-image", type=Path, default=REPO / "release/f030mxdrv.tos")
    parser.add_argument("--listing", type=Path, default=REPO / "build/dsp/YM2151.LST")
    parser.add_argument("--build-dir", type=Path, default=REPO / "build/capture")
    parser.add_argument("--output", type=Path, default=REPO / "build/capture/vectors")
    parser.add_argument("--hatari", default="hatari")
    parser.add_argument("--run-vbls", type=int, default=2500)
    parser.add_argument("--scenario", action="append", choices=sorted(SCENARIOS))
    args = parser.parse_args()

    symbols = parse_listing(args.listing)
    names = args.scenario or list(SCENARIOS)
    args.output.mkdir(parents=True, exist_ok=True)
    for name in names:
        records, events, frames = run_scenario(
            name, args.build_dir, args.tos_image, symbols, args.listing, args.hatari, args.run_vbls
        )
        rows = reconstruct_rows(name, records, events, frames, symbols)
        write_vector(args.output / f"{name}.tsv", name, rows)
        print(f"{name}: {frames} frames reconstructed from {len(records)} dumps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
