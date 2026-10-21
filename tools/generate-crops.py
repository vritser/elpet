#!/usr/bin/env python3
"""Measure the union of opaque pixels across each GIF, without editing assets.

Requires ffmpeg and ffprobe.  Run from any directory; Emacs does not need
Python or ffmpeg at runtime.  Hashes prevent applying stale crops to new art.
"""

import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
OUTPUT = ROOT / "crops.json"


def measure(path):
    dimensions = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "stream=width,height",
        "-of", "csv=p=0", str(path),
    ], text=True)
    width, height = map(int, dimensions.strip().split(","))
    size = width * height
    visible = bytearray(size)
    # Decode all composited frames, including GIF disposal operations.
    with subprocess.Popen([
        "ffmpeg", "-v", "error", "-i", str(path),
        "-f", "rawvideo", "-pix_fmt", "rgba", "-",
    ], stdout=subprocess.PIPE) as process:
        while frame := process.stdout.read(size * 4):
            if len(frame) != size * 4:
                raise ValueError(f"Truncated frame: {path}")
            for index, alpha in enumerate(frame[3::4]):
                if alpha:
                    visible[index] = 1
        if process.wait():
            raise RuntimeError(f"ffmpeg failed: {path}")
    pixels = [index for index, alpha in enumerate(visible) if alpha]
    if not pixels:
        return None
    # A two-pixel safety margin protects anti-aliased edges.
    left = max(0, min(i % width for i in pixels) - 2)
    top = max(0, min(i // width for i in pixels) - 2)
    right = min(width, max(i % width for i in pixels) + 3)
    bottom = min(height, max(i // width for i in pixels) + 3)
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": [width, height], "box": [left, top, right-left, bottom-top]}


if __name__ == "__main__":
    result = {path.stem: measure(path) for path in sorted(ASSETS.glob("*.gif"))}
    OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"Measured {len(result)} animations: {OUTPUT}")
