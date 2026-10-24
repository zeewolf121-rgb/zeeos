#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render original GRUB art and illustrative layout previews. Requires Pillow."""
from pathlib import Path
import math
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "src/NotoSans-Regular.ttf"


def background(width: int, height: int) -> Image.Image:
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            u, v = x / width, y / height
            bloom = math.exp(-((u - 0.92) ** 2 / 0.16 + (v - 0.14) ** 2 / 0.4))
            ribbon = math.exp(-((v - (0.95 - 0.24 * u)) / 0.018) ** 2)
            pixels[x, y] = (
                round(16 + 7 * bloom + 4 * ribbon),
                round(26 + 19 * bloom + 12 * ribbon),
                round(48 + 30 * bloom + 24 * ribbon),
            )
    return image


def crop_background(source: Image.Image, width: int, height: int) -> Image.Image:
    # Match GRUB's centered crop: trim the source to the destination aspect ratio,
    # then scale proportionally. Integer divisions match bitmap_scale.c.
    sw, sh = source.size
    if sw * height < width * sh:
        cropped_height = sw * height // width
        top = (sh - cropped_height) // 2
        source = source.crop((0, top, sw, top + cropped_height))
    else:
        cropped_width = sh * width // height
        left = (sw - cropped_width) // 2
        source = source.crop((left, 0, left + cropped_width, sh))
    return source.resize((width, height), Image.Resampling.BILINEAR)


def preview(width: int, height: int) -> None:
    # A design mockup, not a GRUB screenshot. Keep positions aligned with theme.txt.
    with Image.open(ROOT / "background.png") as source:
        image = crop_background(source, width, height)
    draw = ImageDraw.Draw(image)
    def label(x: int, y: int, text: str, size: int, color: str) -> None:
        draw.text((x, y), text, font=ImageFont.truetype(str(FONT), size), fill=color)
    left = round(width * 0.08)
    label(left, round(height * 0.12), "Choose your system", 32, "#f2f5fc")
    label(left, round(height * 0.23), "A clear start. Your choice.", 20, "#bdcce7")
    for i, text in enumerate(("ZeeOS", "Windows Boot Manager", "Advanced options", "UEFI Firmware Settings")):
        top = round(height * 0.36) + 54 * i
        if i == 0:
            draw.rounded_rectangle((left, top, width - left, top + 46), radius=8,
                                   fill="#234b82", outline="#659be7", width=2)
        label(left + 12, top + 8, text, 20, "#ffffff" if i == 0 else "#d8e1f2")
    label(left, round(height * 0.80), "Starting the selected system in 5 seconds", 16, "#bdcce7")
    label(left, round(height * 0.90), "Up / Down: select    Enter: start    Esc: back", 16, "#bdcce7")
    image.save(ROOT / f"preview-{width}x{height}.png")


def main() -> None:
    background(1600, 1200).save(ROOT / "background.png")
    # GRUB styled boxes use nine tiles: corners, edges and center.
    tile = Image.new("RGB", (24, 24), "#234b82")
    ImageDraw.Draw(tile).rounded_rectangle((0, 0, 23, 23), radius=8, outline="#659be7", width=2)
    for row, y in zip(("n", "c", "s"), (0, 8, 16)):
        for col, x in zip(("w", "c", "e"), (0, 8, 16)):
            name = row + col if row != "c" and col != "c" else (col if row == "c" else row)
            tile.crop((x, y, x + 8, y + 8)).save(ROOT / f"selection_{name}.png")
    preview(800, 600)
    preview(1600, 900)
    for path in ROOT.glob("*.png"):
        path.with_name(path.name + ".license").write_text(
            "SPDX-" "FileCopyrightText: 2026 ZeeOS contributors\n"
            "SPDX-" "License-Identifier: CC-BY-SA-4.0\n"
        )


if __name__ == "__main__":
    main()
