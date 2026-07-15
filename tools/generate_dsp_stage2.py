#!/usr/bin/env python3
"""Convert DSP56001 LOD files into an embedded two-stage loader image."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


DATA_RE = re.compile(r"^_DATA\s+([PXY])\s+([0-9A-Fa-f]+)\s*$")
END_RE = re.compile(r"^_END\s+([0-9A-Fa-f]+)\s*$")
WORD_RE = re.compile(r"^[0-9A-Fa-f]{6}$")

STAGE2_MAGIC = 0x4D584C
STAGE2_REPLY_OK = 0x4C4F41
LOADER_FIRST = 0x0040
LOADER_LIMIT = 0x0080
BOOT_LIMIT = 512


@dataclass
class Section:
    space: str
    address: int
    words: list[int]

    @property
    def limit(self) -> int:
        return self.address + len(self.words)


def parse_lod(path: Path) -> tuple[list[Section], int]:
    sections: list[Section] = []
    current: Section | None = None
    entry: int | None = None

    for line_number, raw_line in enumerate(
        path.read_text(errors="strict").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line:
            continue
        data_match = DATA_RE.match(line)
        if data_match:
            current = Section(
                data_match.group(1).upper(), int(data_match.group(2), 16), []
            )
            sections.append(current)
            continue
        end_match = END_RE.match(line)
        if end_match:
            entry = int(end_match.group(1), 16)
            current = None
            continue
        if current is None:
            raise SystemExit(f"error: {path}:{line_number}: data outside a section")
        for token in line.split():
            if not WORD_RE.fullmatch(token):
                raise SystemExit(
                    f"error: {path}:{line_number}: invalid DSP word {token!r}"
                )
            current.words.append(int(token, 16))

    if entry is None or not sections:
        raise SystemExit(f"error: {path} is not a complete DSP LOD file")
    if any(not section.words for section in sections):
        raise SystemExit(f"error: {path} contains an empty data section")
    return sections, entry


def merge_sections(sections: list[Section]) -> list[Section]:
    merged: list[Section] = []
    for section in sections:
        if merged and section.space == merged[-1].space and section.address == merged[-1].limit:
            merged[-1].words.extend(section.words)
        else:
            merged.append(Section(section.space, section.address, section.words.copy()))
    return merged


def make_boot_image(path: Path) -> list[int]:
    sections, entry = parse_lod(path)
    if entry != 0:
        raise SystemExit(f"error: bootstrap entry must be P:$0000, got ${entry:04x}")
    if any(section.space != "P" for section in sections):
        raise SystemExit("error: bootstrap may initialize only P memory")

    image: dict[int, int] = {}
    for section in sections:
        for offset, word in enumerate(section.words):
            address = section.address + offset
            if address in image:
                raise SystemExit(f"error: overlapping bootstrap word P:${address:04x}")
            image[address] = word
    if not image or min(image) != 0:
        raise SystemExit("error: bootstrap must begin at P:$0000")
    words = [image.get(address, 0) for address in range(max(image) + 1)]
    if len(words) > BOOT_LIMIT:
        raise SystemExit(
            f"error: bootstrap is {len(words)} words ({BOOT_LIMIT} maximum)"
        )
    if len(words) > LOADER_LIMIT:
        raise SystemExit(
            "error: bootstrap overlaps the final program above reserved "
            f"P:${LOADER_LIMIT - 1:04x}"
        )
    return words


def make_program_stream(
    path: Path,
    program_limit: int | None = None,
    island: tuple[int, int] | None = None,
) -> tuple[list[int], int, int]:
    sections, entry = parse_lod(path)
    sections = merge_sections(sections)
    if entry != 0:
        raise SystemExit(f"error: stage-two entry must be P:$0000, got ${entry:04x}")
    if any(section.space != "P" for section in sections):
        raise SystemExit("error: stage-two loader currently accepts P-memory sections only")
    if len(sections) > 0xFFFF:
        raise SystemExit("error: stage-two stream has too many sections")

    for section in sections:
        if section.address > 0xFFFF or section.limit > 0x10000:
            raise SystemExit("error: stage-two section lies outside 16-bit P memory")
        if len(section.words) > 0xFFFF:
            raise SystemExit("error: stage-two section exceeds the hardware-loop limit")
        if section.address < LOADER_LIMIT and section.limit > LOADER_FIRST:
            raise SystemExit(
                "error: final program overlaps reserved loader gap "
                f"P:${LOADER_FIRST:04x}-P:${LOADER_LIMIT - 1:04x}"
            )
        # A section must either stay below the Y-aliased table boundary or sit
        # entirely inside the declared free island above the external-Y
        # reservation; Falcon external P aliases external Y word for word.
        below_tables = program_limit is None or section.limit <= program_limit
        inside_island = island is not None and (
            section.address >= island[0] and section.limit <= island[1]
        )
        if not (below_tables or inside_island):
            raise SystemExit(
                f"error: final program section P:${section.address:04x}-"
                f"${section.limit - 1:04x} overlaps the reserved table region "
                f"at P:${program_limit:04x} and lies outside the free island"
                + (
                    f" P:${island[0]:04x}-${island[1] - 1:04x}"
                    if island is not None
                    else ""
                )
            )

    stream = [STAGE2_MAGIC, len(sections)]
    for section in sections:
        stream.extend((section.address, len(section.words)))
        stream.extend(section.words)
    initialized_words = sum(len(section.words) for section in sections)
    return stream, len(sections), initialized_words


def format_values(directive: str, values: list[int], digits: int, width: int) -> list[str]:
    lines: list[str] = []
    for offset in range(0, len(values), width):
        chunk = values[offset : offset + width]
        rendered = ",".join(f"${value:0{digits}x}" for value in chunk)
        lines.append(f"        {directive}    {rendered}")
    return lines


def emit_include(
    bootstrap: Path,
    program: Path,
    program_limit: int | None = None,
    island: tuple[int, int] | None = None,
) -> str:
    boot_words = make_boot_image(bootstrap)
    stream, section_count, initialized_words = make_program_stream(
        program, program_limit, island
    )

    boot_bytes: list[int] = []
    for word in boot_words:
        boot_bytes.extend(((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF))

    lines = [
        "; Generated by tools/generate_dsp_stage2.py; do not edit.",
        f"DSP_BOOT_WORDS equ {len(boot_words)}",
        f"DSP_STAGE2_TRANSFER_WORDS equ {len(stream)}",
        f"DSP_STAGE2_SECTION_COUNT equ {section_count}",
        f"DSP_STAGE2_PROGRAM_WORDS equ {initialized_words}",
        f"DSP_STAGE2_REPLY_OK equ ${STAGE2_REPLY_OK:06x}",
        "",
        "dsp_bootstrap_image:",
    ]
    lines.extend(format_values("dc.b", boot_bytes, 2, 12))
    lines.extend(["        even", "", "dsp_program_image:"])
    lines.extend(format_values("dc.l", stream, 8, 4))
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--program", type=Path, required=True)
    parser.add_argument("--program-limit", type=lambda value: int(value, 0))
    parser.add_argument(
        "--island",
        nargs=2,
        type=lambda value: int(value, 0),
        metavar=("START", "LIMIT"),
        help="allow P sections inside [START, LIMIT), a physically free "
        "window above the external-Y reservation",
    )
    arguments = parser.parse_args()
    island = tuple(arguments.island) if arguments.island else None
    print(
        emit_include(
            arguments.bootstrap,
            arguments.program,
            arguments.program_limit,
            island,
        ),
        end="",
    )


if __name__ == "__main__":
    main()
