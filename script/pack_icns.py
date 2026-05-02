#!/usr/bin/env python3
"""Pack an app iconset into an ICNS without recompressing PNG entries."""

from __future__ import annotations

import argparse
import os
import struct
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

CHUNKS = (
    ("icp4", "icon_16x16.png", 16, 16),
    ("ic11", "icon_16x16@2x.png", 32, 32),
    ("icp5", "icon_32x32.png", 32, 32),
    ("ic12", "icon_32x32@2x.png", 64, 64),
    ("ic07", "icon_128x128.png", 128, 128),
    ("ic13", "icon_128x128@2x.png", 256, 256),
    ("ic08", "icon_256x256.png", 256, 256),
    ("ic14", "icon_256x256@2x.png", 512, 512),
    ("ic09", "icon_512x512.png", 512, 512),
    ("ic10", "icon_512x512@2x.png", 1024, 1024),
)


def png_size(data: bytes) -> tuple[int, int]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG")
    if data[12:16] != b"IHDR":
        raise ValueError("missing PNG IHDR")
    return struct.unpack(">II", data[16:24])


def build_icns(iconset: Path) -> bytes:
    parts: list[bytes] = []
    for chunk_type, filename, expected_width, expected_height in CHUNKS:
        source = iconset / filename
        data = source.read_bytes()
        width, height = png_size(data)
        if (width, height) != (expected_width, expected_height):
            expected = f"{expected_width}x{expected_height}"
            actual = f"{width}x{height}"
            raise ValueError(f"{source} is {actual}, expected {expected}")
        parts.append(
            chunk_type.encode("ascii")
            + struct.pack(">I", len(data) + 8)
            + data
        )

    size = 8 + sum(len(part) for part in parts)
    return b"icns" + struct.pack(">I", size) + b"".join(parts)


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.tmp")
    tmp_path.write_bytes(data)
    os.replace(tmp_path, path)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pack optimized PNG iconset entries directly into an ICNS."
    )
    parser.add_argument("iconset", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    write_atomic(args.output, build_icns(args.iconset))


if __name__ == "__main__":
    main()
