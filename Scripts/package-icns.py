#!/usr/bin/env python3
"""Pack a macOS iconset's PNG representations into an ICNS container."""

from pathlib import Path
import struct
import sys


iconset = Path(sys.argv[1])
destination = Path(sys.argv[2])
representations = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_16x16@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_128x128@2x.png"),
    ("ic09", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png"),
]
chunks = []
for chunk_type, filename in representations:
    payload = (iconset / filename).read_bytes()
    chunks.append(chunk_type.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload)

body = b"".join(chunks)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
