#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""ppm-colors.py FILE.ppm: print the number of distinct colours in a binary P6 PPM (a blank screen has 1)."""
import sys

data = open(sys.argv[1], "rb").read()
tok, pos = [], 0
while len(tok) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    if data[pos:pos + 1] == b"#":
        pos = data.index(b"\n", pos)
        continue
    end = pos
    while not data[end:end + 1].isspace():
        end += 1
    tok.append(data[pos:end])
    pos = end
if tok[0] != b"P6" or tok[3] != b"255":
    sys.exit("not an 8-bit P6 ppm")
px = data[pos + 1:]
print(len({px[i:i + 3] for i in range(0, len(px) - 2, 3)}))
