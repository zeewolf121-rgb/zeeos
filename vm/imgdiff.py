#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Report-only image diff: imgdiff.py A.ppm B.ppm prints the percentage of differing pixels."""
import sys


def load(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:  # magic, width, height, maxval
        while data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        end = pos
        while not data[end : end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6" or fields[3] != b"255":
        sys.exit("imgdiff: only 8-bit P6 PPM is supported")
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos + 1 : pos + 1 + w * h * 3]


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    if a[:2] != b[:2]:
        sys.exit("imgdiff: size mismatch")
    n = a[0] * a[1]
    pa, pb = a[2], b[2]
    same = sum(pa[i : i + 3] == pb[i : i + 3] for i in range(0, n * 3, 3))
    print(f"{100 * (n - same) / n:.2f}")


main()
