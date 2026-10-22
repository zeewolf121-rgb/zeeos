#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Gating screenshot diff. Arch-neutral: baselines are data under build/arch/<arch>/baselines/.

  imgdiff_gate.py BASELINE_DIR SHOT_DIR [--threshold PCT]

For every SHOT_DIR/screenshot-<step>.ppm that has BASELINE_DIR/<step>.ppm, compare the two with the
masked regions blanked out. A step without a baseline is skipped (nothing to gate). Exit 1 if any
compared step differs in more than PCT percent of the unmasked pixels (default 1.0), 2 on bad input.
Prints one "step status pct" line per step (status: pass, fail, skip).

Masks (clock, cursor) are read from BASELINE_DIR/masks.txt, one per line: `STEP|* X Y W H`.
Negative X/Y count from the right/bottom edge (so a corner clock is resolution-independent).
Blank lines and `#` comments are ignored. A pixel counts as different when any channel differs
by more than CHANNEL_TOL, to absorb anti-aliasing noise.
"""
import os
import sys

CHANNEL_TOL = 8
DEFAULT_THRESHOLD = 1.0


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
        raise ValueError(f"{path}: only 8-bit P6 PPM is supported")
    w, h = int(fields[1]), int(fields[2])
    pix = data[pos + 1 : pos + 1 + w * h * 3]
    if len(pix) != w * h * 3:
        raise ValueError(f"{path}: truncated pixel data")
    return w, h, pix


def read_masks(path, step):
    masks = []
    if not os.path.exists(path):
        return masks
    for line in open(path):
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        if len(line) != 5:
            raise ValueError(f"{path}: bad mask line {' '.join(line)!r}")
        if line[0] in ("*", step):
            masks.append(tuple(int(v) for v in line[1:]))
    return masks


def spans(w, h, masks):
    """Yield (row, x0, x1) ranges to ignore."""
    for x, y, mw, mh in masks:
        x = x + w if x < 0 else x
        y = y + h if y < 0 else y
        x0, x1 = max(0, x), min(w, x + mw)
        if x0 < x1:
            for r in range(max(0, y), min(h, y + mh)):
                yield r, x0, x1


def diff_pct(a, b, masks):
    """Percentage of unmasked pixels that differ."""
    w, h, pa = a
    if b[:2] != (w, h):
        raise ValueError(f"size mismatch {w}x{h} vs {b[0]}x{b[1]}")
    pa, pb = bytearray(pa), bytearray(b[2])
    ignored = 0
    for r, x0, x1 in spans(w, h, masks):
        s, e = (r * w + x0) * 3, (r * w + x1) * 3
        pa[s:e] = pb[s:e] = bytes(e - s)
        ignored += x1 - x0
    total = w * h - ignored
    if total <= 0:
        return 0.0
    bad = 0
    for r in range(h):
        ra, rb = pa[r * w * 3 : (r + 1) * w * 3], pb[r * w * 3 : (r + 1) * w * 3]
        if ra == rb:
            continue
        for i in range(0, w * 3, 3):
            if ra[i : i + 3] != rb[i : i + 3] and any(
                abs(ra[i + c] - rb[i + c]) > CHANNEL_TOL for c in range(3)
            ):
                bad += 1
    return 100.0 * bad / total


def main(argv):
    threshold = DEFAULT_THRESHOLD
    args = list(argv)
    if "--threshold" in args:
        i = args.index("--threshold")
        threshold = float(args[i + 1])
        del args[i : i + 2]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    base_dir, shot_dir = args
    failed = False
    try:
        for name in sorted(os.listdir(shot_dir)):
            if not (name.startswith("screenshot-") and name.endswith(".ppm")):
                continue
            step = name[len("screenshot-") : -len(".ppm")]
            base = os.path.join(base_dir, step + ".ppm")
            if not os.path.isfile(base):
                print(f"{step} skip -")
                continue
            masks = read_masks(os.path.join(base_dir, "masks.txt"), step)
            pct = diff_pct(load(os.path.join(shot_dir, name)), load(base), masks)
            ok = pct <= threshold
            failed |= not ok
            print(f"{step} {'pass' if ok else 'fail'} {pct:.2f}")
    except (OSError, ValueError) as e:
        print(f"imgdiff_gate: {e}", file=sys.stderr)
        return 2
    return 1 if failed else 0


sys.exit(main(sys.argv[1:]))
