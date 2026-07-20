#!/usr/bin/env python3
"""Capture the realtime DSP kernel's block-boundary state under Hatari.

For every perceptual scenario this harness compiles the exact trace into a
CAPTURE.SCN consumed by the TTP's capture mode, replays it through the
protocol-v22 realtime stream inside Hatari, and collects DSP state dumps from
debugger breakpoints at every 64-frame block entry and at every completed
1024-frame buffer. A reconstruction pass turns those dumps into the
per-codec-frame TSV rows accepted by tools/compare_ym2151_realtime.py.
"""

from __future__ import annotations

import argparse
import bisect
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
    "detune": ("perceptual_detune.trace", 8192, None, None),
    "timing": ("perceptual_timing.trace", 2048, None, None),
    "envelope": ("perceptual_envelope.trace", 8192, None, None),
    "lfo": ("perceptual_lfo.trace", 8192, None, None),
    "noise": ("noise_channel7.trace", 8192, None, None),
    "noise-slow": ("noise_channel7_slow.trace", 8192, None, None),
    **{
        f"algorithm-{index}": ("perceptual_topology.trace", 4096, index, 4)
        for index in range(8)
    },
    "feedback-0": ("perceptual_topology.trace", 4096, 0, 0),
    "feedback-7": ("perceptual_topology.trace", 4096, 0, 7),
    # Two real CON4 voices sustained at feedback level 7 for forty periods:
    # the folded kernel's level-7 limit cycle only splices the output after
    # tens of periods, so this scenario runs five times longer than the rest
    # and is gated on its splice count in the comparator.
    "feedback-7-long": ("bisect_two_bom_fb7.trace", 40960, None, None),
}

# Emulated-time floors for scenarios that outrun the default --run-vbls.
SCENARIO_RUN_VBLS = {"feedback-7-long": 6000}

# Symbol-anchored dump ranges shared by both breakpoint scripts. Each entry is
# (memory space, first symbol, last symbol, extra words past the last symbol).
STATE_RANGES: tuple[tuple[str, str, str, int], ...] = (
    ("x", "rt5_native_phase", "rt5_timer_status", 0),
    ("x", "rt5_noise_threshold", "rt5_noise_gain", 0),
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


def write_debug_scripts(
    directory: Path, symbols: dict[tuple[str, str], int], listing: Path
) -> Path:
    block_entry = require_symbol(symbols, "P", "rt5_render_runtime_block")
    # Start/refill now acknowledge as soon as the uploaded host payload is
    # owned, allowing the 68030 to prepare the next period in parallel. These
    # explicit symbols remain true render-completion markers for buffer dumps.
    start_done = require_symbol(symbols, "P", "command_rt_start_buffer_ready")
    refill_done = require_symbol(symbols, "P", "command_rt_refill_buffer_ready")

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
    run_vbls = max(run_vbls, SCENARIO_RUN_VBLS.get(name, 0))
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


PHASE48_MODULUS = 1 << 48
LEVEL_MAX = 1023 << 13
# Right-shifting Galois form of the YM2151 x^17+x^14+1 noise LFSR.
LFSR_TAPS = (1 << 16) | (1 << 13)
COLUMNS = (
    ["frame", "native_sample", "event_count", "event_hash", "left", "right",
     "lfo_am", "noise_state"]
    + [f"op{op}_{field}" for op in range(4) for field in ("phase", "env", "state")]
)


def lfsr_step(state: int) -> int:
    low = state & 1
    state >>= 1
    if low:
        state ^= LFSR_TAPS
    return state


def dsp_state_to_ymfm(state: int) -> int:
    # DSP bits 2:0 encode attack=0, decay=%010, sustain=%011, release=%1xx;
    # ymfm numbers the same stages 1-4.
    bits = state & 7
    if bits & 4:
        return 4
    if bits & 2:
        return 3 if bits & 1 else 2
    return 1


def schedule_events(
    events: list[TraceEvent], frames: int
) -> tuple[list[tuple[int, int, int]], list[int]]:
    """Oracle-identical 1280:1007 schedule: per frame (native, count, hash)."""
    schedule: list[tuple[int, int, int]] = []
    natives: list[int] = []
    event_index = 0
    native_sample = 0
    resample_phase = 0
    for _ in range(frames):
        event_count = 0
        event_hash = FNV_OFFSET
        last_native = native_sample
        resample_phase += CODEC_NUMERATOR
        while True:
            resample_phase -= CODEC_DENOMINATOR
            while (
                event_index < len(events)
                and events[event_index].sample == native_sample
            ):
                event = events[event_index]
                event_index += 1
                for value in (event.sample, event.reg, event.data):
                    for shift in (0, 8, 16, 24):
                        event_hash ^= (value >> shift) & 0xFF
                        event_hash = (event_hash * FNV_PRIME) & 0xFFFFFFFF
                event_count += 1
            last_native = native_sample
            native_sample += 1
            if resample_phase < CODEC_DENOMINATOR:
                break
        schedule.append((last_native, event_count, event_hash if event_count else 0))
        natives.append(native_sample)
    return schedule, natives


@dataclass
class Boundary:
    native_count: int
    lfsr: int
    lfo_phase: int
    lfo_am: int  # the kernel's published block m_lfo_am
    phases48: list[int]  # channel-major ch*4+op 48-bit accumulators
    increments: list[int]  # operator-major signed per-frame DDA increments
    levels: list[int]  # operator-major op*8+ch 10.13 attenuation
    env_states: list[int]  # operator-major raw DSP state bits
    env_a: list[int]  # operator-major 0.23 block multiplier
    env_b: list[int]  # operator-major signed 10.13 block addend
    pm_scale: int  # decoded signed PM depth for the block PM offset
    lfo_waveform: int  # waveform bits; bit 0 flips the block PM sign
    noise_threshold: int  # (ymfm frequency+1)*1007; zero while disabled
    noise_counter: int  # 2560-per-frame latch DDA position
    noise_snap: int  # LFSR snapshot at the last latch


def read_boundary(record: Record, symbols: dict[tuple[str, str], int]) -> Boundary:
    def x_addr(name: str) -> int:
        return require_symbol(symbols, "X", name)

    def y_addr(name: str) -> int:
        return require_symbol(symbols, "Y", name)

    def signed24(value: int) -> int:
        return value - 0x1000000 if value & 0x800000 else value

    high = record.array("x", x_addr("rt5_phase"), 32)
    low = record.array("y", y_addr("rt5_phase"), 32)
    return Boundary(
        native_count=record.words[("x", x_addr("ssi_native_sample_count"))],
        lfsr=record.words[("x", x_addr("rt5_noise_lfsr"))],
        lfo_phase=record.words[("x", x_addr("rt5_lfo_phase"))],
        lfo_am=record.words[("x", x_addr("rt5_block_control"))],
        phases48=[(h << 24) | l for h, l in zip(high, low)],
        increments=[
            signed24(v)
            for v in record.array("y", y_addr("rt5_operator_increment"), 32)
        ],
        levels=record.array("x", x_addr("rt5_envelope_level"), 32),
        env_states=record.array("x", x_addr("rt5_env_state"), 32),
        env_a=record.array("y", y_addr("rt5_env_a"), 32),
        env_b=[signed24(v) for v in record.array("y", y_addr("rt5_env_b"), 32)],
        pm_scale=signed24(record.words[("x", x_addr("rt5_pm_scale"))]),
        lfo_waveform=record.words[("x", x_addr("rt5_lfo_waveform"))],
        noise_threshold=record.words[("x", x_addr("rt5_noise_threshold"))],
        noise_counter=record.words[("x", x_addr("rt5_noise_counter"))],
        noise_snap=record.words[("x", x_addr("rt5_noise_state_snap"))],
    )


def read_audio(
    records: list[Record], symbols: dict[tuple[str, str], int], frames: int
) -> list[tuple[int, int]]:
    """Frame-ordered (left, right) 0.23 samples from the completed buffers."""
    buffer_a = require_symbol(symbols, "X", "ssi_buffer_a")
    buffer_b = require_symbol(symbols, "X", "ssi_buffer_b")
    output_addr = require_symbol(symbols, "X", "rt5_runtime_output")

    def signed24(value: int) -> int:
        return value - 0x1000000 if value & 0x800000 else value

    samples: list[tuple[int, int]] = []
    for record in records:
        if record.kind != BUFFER_MARKER:
            continue
        end = record.words[("x", output_addr)]
        base = end - 2 * BUFFER_FRAMES
        if base not in (buffer_a, buffer_b):
            raise SystemExit(
                f"error: buffer dump output pointer {end:#x} matches no SSI buffer"
            )
        words = record.array("x", base, 2 * BUFFER_FRAMES)
        samples += [
            (signed24(words[2 * i]), signed24(words[2 * i + 1]))
            for i in range(BUFFER_FRAMES)
        ]
    if len(samples) != frames:
        raise SystemExit(f"error: captured {len(samples)} audio frames, need {frames}")
    return samples


def load_attack_factors(path: Path) -> list[int]:
    """The generated per-rate full-block attack multipliers (0.23 words)."""
    text = path.read_text(encoding="utf-8")
    section = text[text.index("rt5_attack_factor:"):]
    section = section[: section.index(":", len("rt5_attack_factor:") + 1)]
    values = [int(v, 16) for v in re.findall(r"\$([0-9a-fA-F]+)", section)]
    if len(values) < 64:
        raise SystemExit("error: attack factor table is incomplete")
    return values[:64]


def effective_attack_rate(registers: dict[int, int], op_major: int) -> int:
    """Mirror rt5_env_reload_op's attack-rate derivation."""
    raw_slot = (op_major & 7) | ((op_major & 8) << 1) | ((op_major & 16) >> 1)
    ar_register = registers.get(0x80 + raw_slot, 0)
    rate = ar_register & 0x1F
    if rate == 0:
        return 0
    rate *= 2
    keycode = (registers.get(0x28 + (op_major & 7), 0) >> 2) & 0x1F
    shift = 3 - (ar_register >> 6)
    if shift > 0:
        keycode >>= shift
    return min(63, rate + keycode)


def attack_level(before: int, alpha: float, frames: int) -> int:
    """ymfm's overshooting exponential toward -1024, in 10.13 units."""
    scaled = alpha ** (frames / 64.0)
    level = scaled * (before + (1 << 23)) - (1 << 23)
    return max(0, min(LEVEL_MAX, int(round(level))))


def mid_block_level(before: int, after: int, multiplier: int) -> int:
    """Analytic 32-frame level from the published full-block affine step."""
    if before == after:
        return before
    alpha = multiplier / (1 << 23)
    alpha_half = alpha**0.5
    addend = after - alpha * before
    mid = alpha_half * before + addend / (1.0 + alpha_half)
    return max(0, min(LEVEL_MAX, int(round(mid))))


# Bit-exact mirror of rt5_rebuild_channel_pitch, so segment increments exist
# for spans no boundary dump can expose (a block with both boundary and
# interior events). The tables come from the same vendored ymfm source the
# kernel's are generated from, and every boundary dump cross-checks the
# mirror below.
DT2_DELTA = (0, 384, 500, 608)
RAW_SLOT = (0, 16, 8, 24)  # logical M1,C1,M2,C2 to raw register slots
PITCH_DDA_SCALE = 5352297


def load_pitch_tables(source_path: Path) -> tuple[list[int], list[int]]:
    source = source_path.read_text(encoding="utf-8")

    def initializer(declaration: str) -> str:
        start = source.index(declaration)
        start = source.index("{", start) + 1
        return source[start : source.index("};", start)]

    def integers(body: str) -> list[int]:
        cleaned = re.sub(r"//.*", "", body)
        return [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", cleaned)]

    phase = integers(initializer("static const uint32_t s_phase_step[12*64]"))
    detune = integers(initializer("static uint8_t const s_detune_adjustment[32][4]"))
    if len(phase) != 768 or len(detune) != 128:
        raise SystemExit("error: ymfm pitch table shapes changed")
    return phase, detune


def block_pm_offset(boundary: Boundary) -> int:
    """The block PM offset in increment units, exactly as the support pass
    derives it: the published LFO index byte times the decoded depth through
    the doubling multiply plus one shift, sign-flipped by waveform bit 0,
    then the product's high word."""
    value = (boundary.lfo_phase & 0xFF) * boundary.pm_scale
    value <<= 2
    if boundary.lfo_waveform & 1:
        value = -value
    return value >> 24


def channel_increments(
    regs: dict[int, int],
    channel: int,
    phase_table: list[int],
    detune_table: list[int],
    pm_offset: int = 0,
) -> list[int]:
    kc = regs.get(0x28 + channel, 0) & 0x7F
    kf = (regs.get(0x30 + channel, 0) >> 2) & 0x3F
    block = (kc >> 4) & 7
    note = kc & 15
    position = (note - (note >> 2)) * 64 + kf
    keycode4 = ((kc >> 2) & 0x1F) * 4
    increments = []
    for slot in RAW_SLOT:
        raw = slot + channel
        pos = position + DT2_DELTA[(regs.get(0xC0 + raw, 0) >> 6) & 3]
        blk = block
        if pos >= 768:
            pos -= 768
            blk += 1
            if blk > 7:
                pos, blk = 767, 7
        step = phase_table[pos] >> (7 - blk)
        dtmul = regs.get(0x40 + raw, 0)
        dt1 = (dtmul >> 4) & 7
        delta = detune_table[keycode4 + (dt1 & 3)]
        if dt1 & 4:
            delta = -delta
        step += delta
        mul = dtmul & 15
        mul2 = mul * 2 if mul else 1
        product = (step * mul2) >> 1
        inc = (product * PITCH_DDA_SCALE) >> 19
        inc = (inc + pm_offset) & 0xFFFFFF
        if inc & 0x800000:
            inc -= 0x1000000
        increments.append(inc)
    return increments


def reconstruct_rows(
    name: str,
    records: list[Record],
    events: list[TraceEvent],
    frames: int,
    symbols: dict[tuple[str, str], int],
) -> list[list[int]]:
    del name
    schedule, natives = schedule_events(events, frames)
    audio = read_audio(records, symbols, frames)

    boundaries = [
        read_boundary(record, symbols)
        for record in records
        if record.kind == STATE_MARKER
    ]
    final = [record for record in records if record.kind == BUFFER_MARKER][-1]
    boundaries.append(read_boundary(final, symbols))
    blocks = frames // BLOCK_FRAMES
    if len(boundaries) != blocks + 1:
        raise SystemExit(
            f"error: {len(boundaries)} boundary dumps for {blocks} blocks"
        )

    # The DSP's own bookkeeping must agree with the exact schedule and the
    # published LFSR/phase recurrences; a silent mismatch here would turn the
    # comparator into a test of this script instead of the DSP.
    for index, boundary in enumerate(boundaries):
        expected = natives[index * BLOCK_FRAMES - 1] & 0xFFFF if index else 0
        if boundary.native_count != expected:
            raise SystemExit(
                f"error: boundary {index} native clock {boundary.native_count}, "
                f"DDA expects {expected}"
            )
    # Register mirror at each block boundary, for the attack-rate decode.
    attack_factors = load_attack_factors(
        REPO / "build/generated/envelope_tables.inc"
    )
    registers_by_block: list[dict[int, int]] = []
    mirror: dict[int, int] = {}
    boundary_clocks_pre = [0] + [
        natives[k * BLOCK_FRAMES - 1] for k in range(1, blocks + 1)
    ]
    event_cursor = 0
    for block in range(blocks):
        while (
            event_cursor < len(events)
            and events[event_cursor].sample <= boundary_clocks_pre[block]
        ):
            mirror[events[event_cursor].reg] = events[event_cursor].data
            event_cursor += 1
        registers_by_block.append(dict(mirror))

    # Channel-0 AM sensitivity per block, from the same boundary-drain
    # schedule the kernel uses; the emitted lfo_am column is the kernel's
    # published block m_lfo_am shifted by it, exactly ymfm's channel offset.
    boundary_clocks_all = [0] + [
        natives[k * BLOCK_FRAMES - 1] for k in range(1, blocks + 1)
    ]
    ams_events = [
        (event.sample, event.data & 3) for event in events if event.reg == 0x38
    ]
    ams_by_block: list[int] = []
    ams = 0
    for block in range(blocks):
        while ams_events and ams_events[0][0] <= boundary_clocks_all[block]:
            ams = ams_events.pop(0)[1]
        ams_by_block.append(ams)

    # Every write lands on the first codec frame whose consumed native
    # count reaches its timestamp; the kernel splits blocks at interior
    # landings, so the reconstruction keys everything on landing frames.
    def landing_frame(sample: int) -> int:
        return bisect.bisect_left(natives, sample)

    # A key-on edge zeroes the operator's phase when the drain applies it —
    # at the block boundary or at its interior segment frame. KON bits 3-6
    # key raw rows M1,M2,C1,C2, so logical columns M1,C1,M2,C2 read bits
    # 3,5,4,6.
    key_reset: dict[tuple[int, int], int] = {}
    key_bits = 0
    for event in events:
        if event.reg != 0x08 or (event.data & 7) != 0:
            continue
        edges = (event.data >> 3) & ~(key_bits >> 3) & 0xF
        key_bits = event.data
        if not edges:
            continue
        frame = landing_frame(event.sample)
        if frame >= frames:
            continue
        for column, bit in enumerate((0, 2, 1, 3)):
            if edges & (1 << bit):
                key_reset[(frame // BLOCK_FRAMES, column)] = frame % BLOCK_FRAMES

    # Channel-0 increments per segment: the register mirror advances at
    # landing frames and the pitch mirror decodes it, giving the increments
    # for spans between an interior event and the next boundary that no
    # dump exposes. Each block's final segment is verified against the
    # next boundary dump below, which validates the mirror itself.
    phase_table, detune_table = load_pitch_tables(
        REPO / "third_party/mame/3rdparty/ymfm/src/ymfm_fm.ipp"
    )
    seg_incs: list[list[tuple[int, list[int]]]] = []
    pitch_mirror: dict[int, int] = {}
    cursor = 0
    for block in range(blocks):
        # The dumped increments carry this block's PM offset, derived from
        # the LFO state the support pass published — visible in the next
        # boundary's dump — and shared by every segment's mid-block rebuild.
        pm_offset = block_pm_offset(boundaries[block + 1])
        while cursor < len(events) and landing_frame(events[cursor].sample) <= block * BLOCK_FRAMES:
            pitch_mirror[events[cursor].reg] = events[cursor].data
            cursor += 1
        segments = [
            (0, channel_increments(pitch_mirror, 0, phase_table, detune_table, pm_offset))
        ]
        while cursor < len(events) and landing_frame(events[cursor].sample) < (block + 1) * BLOCK_FRAMES:
            frame = landing_frame(events[cursor].sample)
            while cursor < len(events) and landing_frame(events[cursor].sample) == frame:
                pitch_mirror[events[cursor].reg] = events[cursor].data
                cursor += 1
            segments.append(
                (
                    frame % BLOCK_FRAMES,
                    channel_increments(pitch_mirror, 0, phase_table, detune_table, pm_offset),
                )
            )
        seg_incs.append(segments)

    def segment_at(block: int, offset: int) -> list[int]:
        current = seg_incs[block][0][1]
        for start, incs in seg_incs[block]:
            if start > offset:
                break
            current = incs
        return current

    # The independent-operator render path keeps only the sine-ROM index in
    # the stored accumulator (`and y1,b1` masks it every frame), so dumped
    # phases are meaningful modulo one ROM cycle (2^32 accumulator units) and
    # cannot disambiguate multi-wrap blocks. Phase is reconstructed by
    # accumulating the mirrored per-segment increments; every block is
    # verified against the dumped accumulator modulo one cycle, and every
    # boundary dump's increments must equal the mirror's final segment.
    rom_cycle = 1 << 32
    for index in range(blocks):
        state = boundaries[index].lfsr
        for _ in range(BLOCK_FRAMES):
            state = lfsr_step(state)
        if state != boundaries[index + 1].lfsr:
            raise SystemExit(f"error: LFSR jump mismatch entering block {index}")
        final_incs = seg_incs[index][-1][1]
        for column, (channel_slot, operator_slot) in enumerate(
            ((0, 0), (1, 8), (2, 16), (3, 24))
        ):
            dumped = boundaries[index + 1].increments[operator_slot]
            if dumped != final_incs[column]:
                raise SystemExit(
                    f"error: block {index} operator {column} increment "
                    f"{dumped:#x} disagrees with the decoded {final_incs[column]:#x}"
                )
            reset_offset = key_reset.get((index, column))
            advance = 0
            for position, (start, incs) in enumerate(seg_incs[index]):
                end = (
                    seg_incs[index][position + 1][0]
                    if position + 1 < len(seg_incs[index])
                    else BLOCK_FRAMES
                )
                for offset in range(start, end):
                    if reset_offset is not None and offset == reset_offset:
                        advance = 0
                    advance += incs[column] * 510
            base = (
                0
                if reset_offset is not None
                else boundaries[index].phases48[channel_slot]
            )
            observed = (
                boundaries[index + 1].phases48[channel_slot] - base
            ) % rom_cycle
            if observed != advance % rom_cycle:
                raise SystemExit(
                    f"error: block {index} operator {column} advanced "
                    f"{observed:#x}, segments say {advance % rom_cycle:#x}"
                )

    # Channel-0 logical operators M1,C1,M2,C2: operator-major increment and
    # envelope slots. Phase accumulates unwrapped so the emitted column wraps
    # in ymfm's 2^22 domain rather than at the 256-step ROM cycle.
    env_slots = [0, 8, 16, 24]
    phase_accumulators = [0, 0, 0, 0]

    rows: list[list[int]] = []
    for frame in range(frames):
        block = frame // BLOCK_FRAMES
        offset = frame % BLOCK_FRAMES
        entry = boundaries[block]
        exit_ = boundaries[block + 1]

        native, event_count, event_hash = schedule[frame]
        left, right = audio[frame]

        # Per-frame noise replays the same Galois steps the block jump or
        # the substitution pass composes; bit 16 is the output bit. With
        # noise enabled the reported state is the bit resampled by the
        # kernel's 2560-per-frame latch DDA against the decoded period,
        # seeded from the dumped counter and snapshot at the block entry.
        lfsr = entry.lfsr
        if entry.noise_threshold:
            counter = entry.noise_counter
            snap = entry.noise_snap
            for _ in range(offset):
                lfsr = lfsr_step(lfsr)
                counter += 2560
                while counter >= entry.noise_threshold:
                    counter -= entry.noise_threshold
                    snap = lfsr
            noise_state = (snap >> 16) & 1
        else:
            for _ in range(offset):
                lfsr = lfsr_step(lfsr)
            noise_state = (lfsr >> 16) & 1

        # The kernel publishes each block's true m_lfo_am; ymfm's channel
        # offset shifts it by the decoded AM sensitivity.
        ams = ams_by_block[block]
        lfo_am = (exit_.lfo_am << (ams - 1)) if ams else 0

        row = [frame, native, event_count, event_hash, left >> 8, right >> 8,
               lfo_am, noise_state]
        segment_incs = segment_at(block, offset)
        for op in range(4):
            e_slot = env_slots[op]
            reset_offset = key_reset.get((block, op))
            if reset_offset == offset:
                phase_accumulators[op] = 0
            # The oracle reports each operator's phase after the frame's
            # advance, so accumulate first and emit second. The increment is
            # the mirrored value for this frame's segment, so a mid-block
            # KC/KF/MUL/DT write bends the phase at its landing frame.
            phase_accumulators[op] += segment_incs[op] * 510
            phase = (phase_accumulators[op] >> 22) & 0x3FFFFF

            before = entry.levels[e_slot]
            after = exit_.levels[e_slot]
            if reset_offset is not None:
                # A key-on block's attack multiplier is consumed and reloaded
                # inside the same boundary pass, so no dump exposes it;
                # rebuild it from the published per-rate table and the same
                # effective-rate decode the kernel runs, and emit ymfm's
                # overshooting exponential with a genuine attack state. An
                # interior key holds the entry level until its landing frame
                # and runs the attack over the remaining span.
                span = BLOCK_FRAMES - reset_offset
                mid_offset = reset_offset + span // 2
                rate = effective_attack_rate(registers_by_block[block], e_slot)
                alpha = attack_factors[rate] / float(1 << 23)
                if offset < reset_offset:
                    level = before
                elif offset < mid_offset:
                    level = attack_level(before, alpha, offset - reset_offset)
                else:
                    mid = attack_level(before, alpha, mid_offset - reset_offset)
                    tail = max(1, BLOCK_FRAMES - mid_offset)
                    level = mid + (after - mid) * (offset - mid_offset) // tail
                env = min(1023, max(0, level >> 13))
                state = 1
            else:
                if offset < 32:
                    mid = mid_block_level(before, after, entry.env_a[e_slot])
                    level = before + (mid - before) * offset // 32
                else:
                    mid = mid_block_level(before, after, entry.env_a[e_slot])
                    level = mid + (after - mid) * (offset - 32) // 32
                env = min(1023, max(0, level >> 13))
                state = dsp_state_to_ymfm(exit_.env_states[e_slot])
            row += [phase, env, state]
        rows.append(row)
    return rows


def write_vector(path: Path, name: str, rows: list[list[int]]) -> None:
    trace_name, frames, algorithm, feedback = SCENARIOS[name]
    header = (
        f"# Falcon DSP realtime capture; scenario={name}; trace={trace_name}; "
        f"frames={frames}; ratio={CODEC_NUMERATOR}/{CODEC_DENOMINATOR}"
    )
    if algorithm is not None:
        header += f"; algorithm={algorithm}"
    if feedback is not None:
        header += f"; feedback={feedback}"
    lines = [header, "\t".join(COLUMNS)]
    lines += ["\t".join(str(value) for value in row) for row in rows]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


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
