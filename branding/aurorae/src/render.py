#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the ZeeOS Aurorae window decoration themes (standard library only).

Four themes, each a directory under branding/aurorae/ that installs to /usr/share/aurorae/themes/:
  ZeeOS-Light, ZeeOS-Dark              round traffic-light buttons (Mac and Hybrid layouts)
  ZeeOS-Plain-Light, ZeeOS-Plain-Dark  flat full-height buttons (Windows layout)
Everything is drawn from scratch here from plain geometry: no traced or borrowed art.

  python3 branding/aurorae/src/render.py             # write the themes
  python3 branding/aurorae/src/render.py --preview   # also write src/preview.svg (see README for the PNG step)
"""
import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Frame geometry (px). Borders and the corner radius match so each corner piece is drawn 1:1, unscaled.
BORDER = 6
TITLE_H = 36

PALETTES = {
    "Light": dict(
        bar="#F6F7F9", bar_off="#FBFBFC", line="#0000002E", line_off="#00000020",
        text="#1E2229", text_off="#7A808A", ink="#0000008C", ink_dark="#00000099",
        dot_off="#C9CDD3", dot_dis="#E1E4E8", hover="#00000012", press="#00000024",
        accent="#3D7AE0", body="#FFFFFF", fg="#1E2229",
    ),
    "Dark": dict(
        bar="#2A2D33", bar_off="#25272C", line="#FFFFFF24", line_off="#FFFFFF16",
        text="#ECEEF2", text_off="#8A9099", ink="#000000A6", ink_dark="#000000B3",
        dot_off="#4A4E56", dot_dis="#383B41", hover="#FFFFFF16", press="#FFFFFF28",
        accent="#6B9BF0", body="#1B1D21", fg="#ECEEF2",
    ),
}
# Traffic-light colours are ZeeOS's own (not sampled from any other system).
LIGHTS = dict(close="#E8574F", minimize="#E9B53A", maximize="#4CB868")
LIGHTS_DARK = dict(close="#E0645C", minimize="#D9A93A", maximize="#52B36C")

BUTTONS = ["close", "minimize", "maximize", "restore", "alldesktops", "keepabove", "keepbelow", "shade", "help"]
STATES = ["active", "inactive", "deactivated", "hover", "pressed"]


def svg(w, h, body):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n{body}</svg>\n')


def glyph(name, c):
    """Small symbol centred in a 14x14 box, drawn with `c` ink."""
    s = f'fill="none" stroke="{c}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"'
    f = f'fill="{c}"'
    return {
        "close": f'<path {s} d="M4.6 4.6 L9.4 9.4 M9.4 4.6 L4.6 9.4"/>',
        "minimize": f'<path {s} d="M4.2 7 H9.8"/>',
        "maximize": f'<path {f} d="M4.4 4.4 H8.2 L4.4 8.2 Z M9.6 9.6 H5.8 L9.6 5.8 Z"/>',
        "restore": f'<path {f} d="M6.2 6.2 H3.6 L6.2 3.6 Z M7.8 7.8 H10.4 L7.8 10.4 Z"/>',
        "alldesktops": f'<circle cx="7" cy="7" r="2" {f}/>',
        "keepabove": f'<path {s} d="M4.6 8.6 L7 6.2 L9.4 8.6"/>',
        "keepbelow": f'<path {s} d="M4.6 5.4 L7 7.8 L9.4 5.4"/>',
        "shade": f'<path {s} d="M4.4 5.2 H9.6 M4.4 8.8 H9.6"/>',
        "help": f'<path {s} d="M5.4 5.6 C5.4 3.9 8.6 3.9 8.6 5.7 C8.6 7 7 7 7 8.3"/><circle cx="7" cy="10.2" r=".5" {f}/>',
    }[name]


def traffic_button(name, state, p, dark):
    """14x14 round button: a plain dot, with the symbol on hover and press."""
    lights = LIGHTS_DARK if dark else LIGHTS
    base = lights.get(name, p["accent"] if name in ("alldesktops", "keepabove") else p["dot_off"])
    if name == "restore":
        base = lights["maximize"]
    fill = {"active": base, "inactive": p["dot_off"], "deactivated": p["dot_dis"],
            "hover": base, "pressed": base}[state]
    ring = "#00000040" if dark else "#00000026"
    out = f'<rect width="14" height="14" fill="none"/><circle cx="7" cy="7" r="6" fill="{fill}"/>'
    out += f'<circle cx="7" cy="7" r="5.75" fill="none" stroke="{ring}" stroke-width=".5"/>'
    if state in ("hover", "pressed"):
        out += glyph(name, p["ink_dark"] if state == "pressed" else p["ink"])
        if state == "pressed":
            out += '<circle cx="7" cy="7" r="6" fill="#00000026"/>'
    return out


def plain_button(name, state, p, dark):
    """36x36 flat button: the symbol is centred; hover/pressed paint a tile (close turns red)."""
    ink = p["text_off"] if state == "inactive" else p["dot_dis"] if state == "deactivated" else p["fg"]
    tile = ""
    if state in ("hover", "pressed"):
        if name == "close":
            tile = f'<rect width="36" height="36" fill="{"#D9453D" if state == "hover" else "#B8362F"}"/>'
            ink = "#FFFFFF"
        else:
            tile = f'<rect width="36" height="36" fill="{p["hover"] if state == "hover" else p["press"]}"/>'
    g = glyph(name, ink).replace('stroke-width="1.6"', 'stroke-width="1.0"')
    return f'<rect width="36" height="36" fill="none"/>{tile}<g transform="translate(7.5 7.5) scale(1.5)">{g}</g>'


def button_sheet(kind, name, p, dark):
    size = 14 if kind == "traffic" else 36
    draw = traffic_button if kind == "traffic" else plain_button
    parts = [f'<g id="{st}-center" transform="translate({i * (size + 4)} 0)">{draw(name, st, p, dark)}</g>\n'
             for i, st in enumerate(STATES)]
    return svg(len(STATES) * (size + 4), size, "".join(parts))


def frame_pieces(active, p):
    """The eight frame elements of one window state, each as (id, w, h, inner svg)."""
    bar = p["bar"] if active else p["bar_off"]
    ln = p["line"] if active else p["line_off"]
    b, t = BORDER, TITLE_H
    st = f'fill="none" stroke="{ln}" stroke-width="1"'
    fl = f'fill="{bar}"'
    h = b - .5
    return [
        ("top", 16, t, f'<rect width="16" height="{t}" {fl}/><path {st} d="M0 .5 H16"/>'),
        ("topleft", b, t, f'<path {fl} d="M{b} 0 A{b} {b} 0 0 0 0 {b} V{t} H{b} Z"/>'
                          f'<path {st} d="M{b} .5 A{h} {h} 0 0 0 .5 {b} V{t}"/>'),
        ("topright", b, t, f'<path {fl} d="M0 0 A{b} {b} 0 0 1 {b} {b} V{t} H0 Z"/>'
                           f'<path {st} d="M0 .5 A{h} {h} 0 0 1 {b - .5} {b} V{t}"/>'),
        ("left", b, 16, f'<rect width="{b}" height="16" {fl}/><path {st} d="M.5 0 V16"/>'),
        ("right", b, 16, f'<rect width="{b}" height="16" {fl}/><path {st} d="M{b - .5} 0 V16"/>'),
        ("bottom", 16, b, f'<rect width="16" height="{b}" {fl}/><path {st} d="M0 {b - .5} H16"/>'),
        ("bottomleft", b, b, f'<path {fl} d="M0 0 H{b} V{b} A{b} {b} 0 0 1 0 0 Z"/>'
                             f'<path {st} d="M.5 0 A{h} {h} 0 0 0 {b} {b - .5}"/>'),
        ("bottomright", b, b, f'<path {fl} d="M{b} 0 H0 V{b} A{b} {b} 0 0 0 {b} 0 Z"/>'
                              f'<path {st} d="M{b - .5} 0 A{h} {h} 0 0 1 0 {b - .5}"/>'),
    ]


def decoration_sheet(p):
    parts, y = [], 0
    for active in (True, False):
        prefix = "decoration" if active else "decoration-inactive"
        x = 0
        for name, w, _h, inner in frame_pieces(active, p):
            parts.append(f'<g id="{prefix}-{name}" transform="translate({x} {y})">{inner}</g>\n')
            x += w + 4
        y += TITLE_H + 4
    return svg(240, 2 * (TITLE_H + 4), "".join(parts))


def rc(kind, p, label):
    if kind == "traffic":
        bw, bh, sp, mt = 14, 14, 8, 11
    else:
        bw, bh, sp, mt = 36, 36, 0, 0
    edge = 14 if kind == "traffic" else BORDER
    return (f"[General]\nName={label}\nActiveTextColor={p['text'][:7]}\nInactiveTextColor={p['text_off'][:7]}\n"
            f"Shadow=true\nAnimation=0\nTitleAlignment=AlignHCenter\nTitleVerticalAlignment=AlignVCenter\n"
            f"HaloDrawn=false\n\n"
            f"[Layout]\nBorderLeft={BORDER}\nBorderRight={BORDER}\nBorderBottom={BORDER}\n"
            f"TitleEdgeTop=0\nTitleEdgeBottom=0\nTitleEdgeLeft={edge}\nTitleEdgeRight={BORDER}\n"
            f"TitleHeight={TITLE_H}\nTitleBorderLeft=8\nTitleBorderRight=8\n"
            f"ButtonWidth={bw}\nButtonHeight={bh}\nButtonSpacing={sp}\nButtonMarginTop={mt}\n"
            f"ExplicitButtonSpacer=6\nPaddingTop=0\nPaddingLeft=0\nPaddingRight=0\nPaddingBottom=0\n")


def theme(kind, mode):
    dark = mode == "Dark"
    p = PALETTES[mode]
    name = "ZeeOS-" + ("" if kind == "traffic" else "Plain-") + mode
    d = ROOT / name
    d.mkdir(exist_ok=True)
    label = name.replace("-", " ")
    (d / "metadata.json").write_text(json.dumps({"KPlugin": {
        "Id": name, "Name": label, "Authors": [{"Name": "ZeeOS contributors"}],
        "Description": "Original ZeeOS window decoration, "
                       + ("round traffic-light" if kind == "traffic" else "flat") + " buttons",
        "License": "CC-BY-SA-4.0"}}, indent=2) + "\n")
    (d / (name + "rc")).write_text(rc(kind, p, label))
    (d / "decoration.svg").write_text(decoration_sheet(p))
    for b in BUTTONS:
        (d / f"{b}.svg").write_text(button_sheet(kind, b, p, dark))
    return name


# ---- preview (a mock-up built from the same button functions; not what KWin renders) -----------------

def window(kind, mode, active):
    p = PALETTES[mode]
    dark = mode == "Dark"
    w, h = 330, 150
    bar = p["bar"] if active else p["bar_off"]
    ln = p["line"] if active else p["line_off"]
    txt = p["text"] if active else p["text_off"]
    uid = f"c{kind}{mode}{int(active)}"
    state = "active" if active else "inactive"
    out = [f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg">',
           f'<defs><clipPath id="{uid}"><rect width="{w}" height="{h}" rx="{BORDER}"/></clipPath></defs>',
           f'<g clip-path="url(#{uid})"><rect width="{w}" height="{h}" fill="{bar}"/>'
           f'<rect x="{BORDER}" y="{TITLE_H}" width="{w - 2 * BORDER}" height="{h - TITLE_H - BORDER}" fill="{p["body"]}"/></g>',
           f'<rect x=".5" y=".5" width="{w - 1}" height="{h - 1}" rx="{BORDER - .5}" fill="none" stroke="{ln}"/>',
           f'<text x="{w / 2}" y="23" text-anchor="middle" font-family="sans-serif" font-size="13" fill="{txt}">ZeeOS</text>']
    if kind == "traffic":
        for n, x in zip(["close", "minimize", "maximize"], [14, 36, 58]):
            out.append(f'<g transform="translate({x} 11)">{traffic_button(n, state, p, dark)}</g>')
    else:
        for i, n in enumerate(["minimize", "maximize", "close"]):
            s = "hover" if (n == "close" and active) else state
            out.append(f'<g transform="translate({w - 108 + i * 36} 0)">{plain_button(n, s, p, dark)}</g>')
    out.append(f'<text x="{BORDER + 10}" y="{TITLE_H + 28}" font-family="sans-serif" font-size="12" fill="{p["fg"]}" '
               f'opacity=".7">{"active" if active else "inactive"} window</text></svg>')
    return "".join(out)


def state_strip(kind, mode):
    p = PALETTES[mode]
    dark = mode == "Dark"
    size = 14 if kind == "traffic" else 36
    draw = traffic_button if kind == "traffic" else plain_button
    names = ["close", "minimize", "maximize", "restore"]
    cell = size + 10
    rows = [f'<g transform="translate({6 + c * cell} {6 + r * (size + 8)})">{draw(n, s, p, dark)}</g>'
            for r, n in enumerate(names) for c, s in enumerate(STATES)]
    w, h = 12 + len(STATES) * cell, 12 + len(names) * (size + 8)
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg">'
            f'<rect width="{w}" height="{h}" rx="6" fill="{p["bar"]}"/>{"".join(rows)}</svg>')


def preview():
    """One SVG (rendered to PNG by the README's command) with all four themes."""
    out, W, H = [], 1480, 1280
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
    for i, (kind, mode) in enumerate([(k, m) for k in ("traffic", "plain") for m in ("Light", "Dark")]):
        x, y = (i % 2) * 740, (i // 2) * 640
        bgc, col = ("#E4E7EC", "#1E2229") if mode == "Light" else ("#101114", "#ECEEF2")
        label = f'ZeeOS-{"" if kind == "traffic" else "Plain-"}{mode}'
        out.append(f'<g transform="translate({x} {y})"><rect width="740" height="640" fill="{bgc}"/>'
                   f'<text x="20" y="30" font-family="sans-serif" font-size="16" fill="{col}">{label}</text>'
                   f'<g transform="translate(20 50)">{window(kind, mode, True)}</g>'
                   f'<g transform="translate(370 50)">{window(kind, mode, False)}</g>'
                   f'<text x="20" y="240" font-family="sans-serif" font-size="12" fill="{col}">states left to right: active, inactive, '
                   f'deactivated, hover, pressed; rows: close, minimize, maximize, restore</text>'
                   f'<g transform="translate(20 256) scale(2)">{state_strip(kind, mode)}</g></g>')
    out.append('</svg>')
    (ROOT / "src" / "preview.svg").write_text("".join(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true", help="also write src/preview.svg")
    a = ap.parse_args()
    for kind in ("traffic", "plain"):
        for mode in ("Light", "Dark"):
            print("wrote", theme(kind, mode))
    if a.preview:
        preview()
        print("wrote src/preview.svg")
    return 0


if __name__ == "__main__":
    sys.exit(main())
