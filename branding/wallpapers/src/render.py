#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
"""Render the ZeeOS wallpapers (original art, CC-BY-SA-4.0) as Plasma wallpaper packages.

Deterministic: fixed seeds, no network, no third-party assets. Needs numpy and Pillow:
    python3 -m venv .venv && .venv/bin/pip install numpy pillow
    .venv/bin/python branding/wallpapers/src/render.py            # all packages
    .venv/bin/python branding/wallpapers/src/render.py --preview  # small previews only

Writes branding/wallpapers/<Package>/{metadata.json,contents/images*/<W>x<H>.jpg,contents/screenshot.jpg}.
Palette follows desktop/live/overlay/usr/share/color-schemes/ZeeOS*.colors (accent #3D7AE0).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
OUT = HERE.parent
SIZES = [(3840, 2160), (3840, 2400)]  # 16:9 and 16:10; Plasma scales to the screen
PREVIEW = (960, 540)


def hexrgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255.0


ACCENT = hexrgb("#3D7AE0")
VIOLET = hexrgb("#7C5CE6")
TEAL = hexrgb("#24B3A8")
CORAL = hexrgb("#F28C6B")


def grid(w: int, h: int):
    """Aspect-correct coordinates: X spans about [-0.89, 0.89] at 16:9, Y spans [0, 1]."""
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return (xs - w / 2) / h, ys / h


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def glow(X, Y, cx, cy, r):
    return np.exp(-((X - cx) ** 2 + (Y - cy) ** 2) / (r * r))


def lerp(a, b, t):
    t = t[..., None] if np.ndim(t) == 2 else t
    return a + (b - a) * t


def over(dst, color, alpha):
    """Normal alpha compositing of a flat or per-pixel color."""
    a = np.clip(alpha, 0, 1)[..., None]
    return dst * (1 - a) + color * a


def screen(dst, color, alpha):
    a = np.clip(alpha, 0, 1)[..., None]
    return dst + (1 - (1 - dst) * (1 - color) - dst) * a


def noise1d(x, seed, octaves=4):
    """Smooth, deterministic 1-D value noise in [-1, 1]."""
    rng = np.random.default_rng(seed)
    total = np.zeros_like(x)
    amp, freq, norm = 1.0, 1.0, 0.0
    for _ in range(octaves):
        knots = rng.uniform(-1, 1, 512).astype(np.float32)
        p = (x * freq * 6 + 256) % 511
        i = np.floor(p).astype(int)
        f = p - i
        f = f * f * (3 - 2 * f)
        total += amp * (knots[i] * (1 - f) + knots[i + 1] * f)
        norm += amp
        amp *= 0.5
        freq *= 2.1
    return total / norm


def finish(img, seed):
    """Fine grain (fights banding in 8-bit gradients), then quantize."""
    rng = np.random.default_rng(seed)
    img = img + rng.normal(0, 1.1 / 255, img.shape).astype(np.float32)
    return Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")


# --- ZeeOS (default): luminous ribbons over a soft bloom -------------------------------------

def ribbons(w, h, dark):
    X, Y = grid(w, h)
    if dark:
        img = lerp(hexrgb("#0D1016"), hexrgb("#171B26"), Y)
        blend, k = screen, 1.0
    else:
        img = lerp(hexrgb("#F6F8FC"), hexrgb("#E2E8F4"), Y)
        blend, k = over, 0.55
    # Soft blooms behind everything.
    img = blend(img, ACCENT, (0.55 if dark else 0.30) * glow(X, Y, 0.42, 0.30, 0.55))
    img = blend(img, VIOLET, (0.45 if dark else 0.22) * glow(X, Y, -0.55, 0.78, 0.60))
    img = blend(img, TEAL, (0.30 if dark else 0.16) * glow(X, Y, 0.10, 1.05, 0.45))
    # Four broad silk ribbons sweeping up from lower left: a smooth translucent body that
    # fades toward its lower edge, and a thin bright highlight along the upper edge.
    specs = [  # y at centre, tilt, amplitude, frequency, phase, half-thickness, colours, seed
        (0.70, -0.16, 0.070, 0.42, 0.05, 0.150, (VIOLET, ACCENT), 11),
        (0.74, -0.20, 0.060, 0.50, 0.30, 0.110, (ACCENT, TEAL), 23),
        (0.80, -0.12, 0.050, 0.36, 0.62, 0.085, (TEAL, ACCENT), 37),
        (0.84, -0.22, 0.045, 0.55, 0.85, 0.060, (CORAL, VIOLET), 41),
    ]
    xs = X[0]
    for base, tilt, amp, freq, phase, half, (c1, c2), seed in specs:
        yc = base + tilt * xs + amp * np.sin(2 * np.pi * (freq * xs + phase)) + 0.012 * noise1d(xs * 0.4, seed, 2)
        th = half * (0.80 + 0.20 * np.sin(2 * np.pi * (0.6 * xs + phase * 3)))
        d = (Y - yc[None, :]) / th[None, :]           # -1 at the upper edge, +1 at the lower edge
        body = smoothstep(-1.0, -0.75, d) * (1 - smoothstep(-0.2, 1.0, d))
        rim = np.exp(-((d + 0.95) / 0.035) ** 2)
        col = lerp(c1, c2, smoothstep(-0.9, 0.9, X))
        img = blend(img, col, (0.62 if dark else 0.42) * body)
        img = blend(img, np.ones(3, np.float32), (0.50 if dark else 0.70) * rim)
    # Gentle vignette keeps panels and icons readable at the edges.
    vig = smoothstep(0.35, 1.25, np.sqrt(X ** 2 + (Y - 0.5) ** 2))
    img = img * (1 - (0.35 if dark else 0.08) * vig[..., None])
    return img


# --- ZeeOS Horizon: layered ridges, dawn (light) / dusk (dark) --------------------------------

def horizon(w, h, dark):
    X, Y = grid(w, h)
    if dark:
        sky = lerp(hexrgb("#0A0E1C"), hexrgb("#2B2457"), smoothstep(0.0, 0.62, Y))
        sky = screen(sky, hexrgb("#E0739B"), 0.35 * glow(X, Y, 0.25, 0.62, 0.35))
        layers = ["#2A2A5C", "#22224C", "#1A1B3D", "#13152E", "#0C0E1F"]
    else:
        sky = lerp(hexrgb("#9DBDF3"), hexrgb("#FFE3CF"), smoothstep(0.0, 0.62, Y))
        sky = screen(sky, hexrgb("#FFF4E8"), 0.65 * glow(X, Y, 0.25, 0.55, 0.22))
        layers = ["#B9C3EE", "#97A6E4", "#7486D6", "#5466C2", "#3A4AA3"]
    img = sky
    if dark:  # stars, only in the upper sky
        rng = np.random.default_rng(7)
        n = 900
        sx = rng.uniform(X.min(), X.max(), n).astype(np.float32)
        sy = rng.uniform(0.0, 0.5, n).astype(np.float32)
        size = rng.uniform(0.0006, 0.0016, n).astype(np.float32)
        bright = rng.uniform(0.3, 1.0, n).astype(np.float32)
        stars = np.zeros(X.shape, np.float32)
        px = ((sx * h) + w / 2).astype(int)
        py = (sy * h).astype(int)
        r = 6
        yy, xx = np.mgrid[-r:r + 1, -r:r + 1].astype(np.float32) / h
        for i in range(n):
            x0, y0 = px[i], py[i]
            if not (r <= x0 < w - r and r <= y0 < h - r):
                continue
            stars[y0 - r:y0 + r + 1, x0 - r:x0 + r + 1] += bright[i] * np.exp(-(xx ** 2 + yy ** 2) / size[i] ** 2)
        img = screen(img, np.ones(3, np.float32), np.clip(stars, 0, 1) * (1 - smoothstep(0.35, 0.55, Y)))
    xs = X[0]
    for i, col in enumerate(layers):
        base = 0.52 + i * 0.085
        ridge = base - (0.07 - i * 0.008) * (1 + noise1d(xs * (0.8 + i * 0.25), 100 + i, 5)) \
            + 0.02 * np.sin(2 * np.pi * (0.35 * xs + i * 0.21))
        mask = smoothstep(-0.0015, 0.0015, Y - ridge[None, :])
        c = hexrgb(col)
        # Atmospheric haze: back layers lean toward the sky glow.
        haze = (0.18 if dark else 0.30) * (1 - i / len(layers))
        c = c * (1 - haze) + (hexrgb("#E0739B") if dark else hexrgb("#FFE3CF")) * haze
        shade = 1 - 0.10 * smoothstep(ridge[None, :], ridge[None, :] + 0.25, Y)
        img = over(img, c[None, None, :] * shade[..., None], mask)
    return img


# --- ZeeOS Tiles: rounded glass tiles in a snap-layout arrangement ----------------------------

def rounded_rect(X, Y, cx, cy, hw, hh, r):
    qx = np.abs(X - cx) - (hw - r)
    qy = np.abs(Y - cy) - (hh - r)
    outside = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2)
    return outside + np.minimum(np.maximum(qx, qy), 0) - r


def tiles(w, h, dark):
    X, Y = grid(w, h)
    if dark:
        img = lerp(hexrgb("#12151D"), hexrgb("#1B2030"), Y)
        img = screen(img, ACCENT, 0.35 * glow(X, Y, 0.35, 0.40, 0.65))
        glass, edge, shadow_a = hexrgb("#262C3B"), 0.10, 0.45
    else:
        img = lerp(hexrgb("#EEF2FA"), hexrgb("#DCE4F3"), Y)
        img = screen(img, hexrgb("#FFFFFF"), 0.6 * glow(X, Y, -0.3, 0.2, 0.7))
        glass, edge, shadow_a = hexrgb("#FFFFFF"), 0.55, 0.12
    g, r = 0.018, 0.028  # gutter and corner radius, in screen heights
    # Snap-layout composition, centred: one tall tile, two stacked, one wide, three small.
    L, T, Wd, Ht = -0.62, 0.20, 1.24, 0.60
    cols = [L, L + 0.48, L + 0.86, L + Wd]
    rows = [T, T + 0.32, T + Ht]
    rects = [
        (cols[0], rows[0], cols[1], rows[2], ACCENT),                # tall
        (cols[1], rows[0], cols[3], rows[1], None),                  # wide
        (cols[1], rows[1], cols[2], rows[2], None),
        (cols[2], rows[1], cols[3], rows[1] + (rows[2] - rows[1]) / 2, VIOLET),
        (cols[2], rows[1] + (rows[2] - rows[1]) / 2, cols[3], rows[2], TEAL),
    ]
    for x0, y0, x1, y1, tint in rects:
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hw, hh = (x1 - x0) / 2 - g / 2, (y1 - y0) / 2 - g / 2
        sd = rounded_rect(X, Y, cx, cy, hw, hh, r)
        # Drop shadow only outside the tile, so it never shows through the translucent glass.
        sd_shadow = rounded_rect(X, Y - 0.012, cx, cy, hw, hh, r)
        outside = smoothstep(-0.0012, 0.0012, sd)
        img = over(img, np.zeros(3, np.float32), shadow_a * np.exp(-np.maximum(sd_shadow, 0) / 0.02) * outside)
        inside = smoothstep(0.0012, -0.0012, sd)
        fill = glass if tint is None else (glass * 0.35 + tint * 0.65)
        sheen = 0.08 * (1 - smoothstep(y0, (y0 + y1) / 2, Y))  # top-lit glass, no hard line
        col = np.clip(fill[None, None, :] + sheen[..., None], 0, 1)
        img = over(img, col, inside * (0.80 if dark else 0.72))
        rim = np.exp(-(sd / 0.0012) ** 2)
        img = over(img, np.ones(3, np.float32), edge * 0.6 * rim)
    return img


PACKAGES = {
    "ZeeOS": ("ZeeOS", ribbons, 1),
    "ZeeOS-Horizon": ("ZeeOS Horizon", horizon, 2),
    "ZeeOS-Tiles": ("ZeeOS Tiles", tiles, 3),
}


def render(pkg: str, preview: bool) -> list[Path]:
    name, fn, seed = PACKAGES[pkg]
    root = OUT / pkg
    written = []
    sizes = [PREVIEW] if preview else SIZES
    for dark in (False, True):
        sub = "images_dark" if dark else "images"
        for w, h in sizes:
            path = root / "contents" / sub / (f"preview-{w}x{h}.jpg" if preview else f"{w}x{h}.jpg")
            path.parent.mkdir(parents=True, exist_ok=True)
            finish(fn(w, h, dark), seed * 10 + int(dark)).save(path, quality=92, subsampling=0, optimize=True)
            written.append(path)
    if not preview:
        shot = finish(fn(640, 400, False), seed)
        shot.save(root / "contents" / "screenshot.jpg", quality=90, subsampling=0, optimize=True)
        meta = {"KPlugin": {"Id": pkg, "Name": name,
                            "Authors": [{"Name": "ZeeOS contributors"}],
                            "License": "CC-BY-SA-4.0"}}
        (root / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
    return written


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--preview", action="store_true", help="render small previews only")
    ap.add_argument("packages", nargs="*", default=list(PACKAGES))
    a = ap.parse_args()
    for pkg in a.packages:
        for p in render(pkg, a.preview):
            print(p.relative_to(OUT.parent.parent))


if __name__ == "__main__":
    main()
