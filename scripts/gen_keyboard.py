#!/usr/bin/env python3
"""Generate art/_shared/keyboard.svg from the shared keyboard geometry in art/SPEC.md.

The keyboard is a 60% board seen in 3/4 view. Every point is mapped through one affine
transform: P(s, t) = origin + s*u + t*v, with s in key units along the board (left -> right) and
t in rows from the front edge (0) to the back edge. Re-run after changing the numbers below.
usage: scripts/gen_keyboard.py
"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "art" / "_shared" / "keyboard.svg"
KEYS_OUT = OUT.with_name("keyboard_keys.json")

# Case top face corners (see SPEC "Canvas geometry").
FL = (30.0, 188.0)        # front-left
FR = (170.0, 224.0)       # front-right
BL = (80.0, 146.0)        # back-left
DEPTH = 12.0              # case thickness (front and right faces drop straight down)
# Key grid inside the case, in key units.
COLS, ROWS = 15.0, 5.0
MARGIN_S, MARGIN_FRONT, MARGIN_BACK = 0.42, 0.42, 0.30
SPAN_S = COLS + 2 * MARGIN_S
SPAN_T = ROWS + MARGIN_FRONT + MARGIN_BACK
U = ((FR[0] - FL[0]) / SPAN_S, (FR[1] - FL[1]) / SPAN_S)
V = ((BL[0] - FL[0]) / SPAN_T, (BL[1] - FL[1]) / SPAN_T)
GAP = 0.10                # half gap between keys (key units)
CAP_RISE = 3.0            # how far a keycap top sits above its footprint (viewBox units)
CAP_FRONT = 0.16          # key units of front lip left visible below the cap top

# The keyboard faces the animal (who sits behind it), so from the viewer the space row is at the
# BACK and every row runs right-to-left. Layouts/legends below are written from the typist's side
# (space row first, left to right) and flipped in main().
ROW_LAYOUT = [            # typist's near row (space) to far row (number row)
    [1.25, 1.25, 1.25, 6.25, 1.25, 1.25, 1.25, 1.25],
    [2.25] + [1] * 10 + [2.75],
    [1.75] + [1] * 11 + [2.25],
    [1.5] + [1] * 12 + [1.5],
    [1] * 13 + [2],
]

# Keycap legends, front (space row) to back (number row). They are drawn with a real font at
# runtime (assets/fonts), not in the SVG. Per-OS overrides for the modifier row.
LEGENDS = [
    ["ctrl", "win", "alt", "", "alt", "fn", "menu", "ctrl"],
    ["shift", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "shift"],
    ["caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "enter"],
    ["tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"],
    ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "delete"],
]
LEGENDS_OS = {
    "macos": {0: ["ctrl", "opt", "cmd", "", "cmd", "opt", "fn", "ctrl"]},
    "linux": {0: ["ctrl", "super", "alt", "", "alt", "fn", "menu", "ctrl"]},
}
LEGEND_EM_CHAR, LEGEND_EM_WORD = 0.34, 0.20   # font size in key units (1-char keys, word keys)

LINE_MAIN, LINE_KEY = 4.5, 2.0
# theme token placeholders (art/_shared/themes.json)
GEAR_LINE, KB_CASE, KB_CASE_HI, KB_SIDE, KB_SIDE_DARK = "#22252C", "#3A3F4B", "#4A505E", "#262A33", "#1E2129"
KEYCAP, KEYCAP_SIDE, KEYCAP_LEGEND = "#454B59", "#2C313B", "#B8C0CC"


def P(s, t, dy=0.0):
    """Key-unit coordinates (s from the left key edge, t from the front key edge) to viewBox."""
    s += MARGIN_S
    t += MARGIN_FRONT
    return (FL[0] + s * U[0] + t * V[0], FL[1] + s * U[1] + t * V[1] + dy)


def case(s, t, dy=0.0):
    """Case-unit coordinates (0..1 along each case edge) to viewBox."""
    return (FL[0] + s * SPAN_S * U[0] + t * SPAN_T * V[0],
            FL[1] + s * SPAN_S * U[1] + t * SPAN_T * V[1] + dy)


def f(p):
    return f"{p[0]:.1f} {p[1]:.1f}"


def poly(pts):
    return "M" + " L".join(f(p) for p in pts) + "Z"


def rounded(pts, r):
    """Closed polygon with corners rounded by quadratic curves cutting r units from each corner."""
    out = []
    n = len(pts)
    for i in range(n):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]

        def toward(p, q):
            dx, dy = q[0] - p[0], q[1] - p[1]
            d = (dx * dx + dy * dy) ** 0.5
            k = min(r, d / 2) / d
            return (p[0] + dx * k, p[1] + dy * k)
        p1, p2 = toward(b, a), toward(b, c)
        out.append(("M" if i == 0 else "L") + f(p1) + " Q" + f(b) + " " + f(p2))
    return " ".join(out) + "Z"


def main():
    BR = case(1, 1)
    FRb, BRb, FLb = case(1, 0, DEPTH), case(1, 1, DEPTH), case(0, 0, DEPTH)
    flt, frt, brt, blt = case(0, 0), case(1, 0), case(1, 1), case(0, 1)

    silhouette = rounded([blt, brt, BRb, FRb, FLb, flt], 3.5)
    top = rounded([flt, frt, brt, blt], 3.0)
    front = poly([flt, frt, FRb, FLb])
    right = poly([frt, brt, BRb, FRb])
    # Underglow: a band along the lower part of the front and right faces.
    g0, g1 = 0.40, 0.80   # fraction of DEPTH where the band starts / ends
    glow = (poly([case(0, 0, DEPTH * g0), case(1, 0, DEPTH * g0), case(1, 0, DEPTH * g1), case(0, 0, DEPTH * g1)])
            + poly([case(1, 0, DEPTH * g0), case(1, 1, DEPTH * g0), case(1, 1, DEPTH * g1), case(1, 0, DEPTH * g1)]))
    # Top-face highlight rim along the front edge of the case top.
    rim = poly([case(0.02, 0.0), case(0.98, 0.0), case(0.98, 0.05), case(0.02, 0.05)])

    skirts, tops, legends = [], [], []
    for trow, twidths in enumerate(ROW_LAYOUT):
        # viewer row 0 (front) is the typist's far row; viewer left-to-right is typist right-to-left
        row = len(ROW_LAYOUT) - 1 - trow
        widths = list(reversed(twidths))
        s = 0.0
        t0, t1 = row + GAP, row + 1 - GAP
        for i, w in enumerate(widths):
            s0, s1 = s + GAP, s + w - GAP
            # keycap body: from the footprint's front edge up to the raised top's back edge, so only a
            # thin front lip shows under each cap top
            skirts.append(rounded([P(s0, t0), P(s1, t0), P(s1, t1, -CAP_RISE), P(s0, t1, -CAP_RISE)], 1.4))
            ti = 0.06
            tops.append(rounded([P(s0 + ti, t0 + CAP_FRONT, -CAP_RISE), P(s1 - ti, t0 + CAP_FRONT, -CAP_RISE),
                                 P(s1 - ti, t1 - 0.02, -CAP_RISE), P(s0 + ti, t1 - 0.02, -CAP_RISE)], 1.4))
            ti_ = len(widths) - 1 - i          # index in the typist's left-to-right order
            label = LEGENDS[trow][ti_]
            if label:
                # centre of the keycap top face; the glyph's x axis runs along U, its "up" along V
                cx, cy = P((s0 + s1) / 2, (t0 + CAP_FRONT + t1 - 0.02) / 2, -CAP_RISE)
                legends.append({"row": trow, "index": ti_, "label": label,
                                "center": [round(cx, 2), round(cy, 2)],
                                "em": LEGEND_EM_CHAR if len(label) == 1 else LEGEND_EM_WORD,
                                "width": w})
            s += w

    gx0, gx1 = FL[0], BR[0]
    out = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
  <!-- typebud shared keyboard: 60% board, 3/4 view. Generated by scripts/gen_keyboard.py; theme tokens per art/SPEC.md. -->
  <defs>
    <linearGradient id="kb-underglow" gradientUnits="userSpaceOnUse" x1="{gx0:.0f}" y1="0" x2="{gx1:.0f}" y2="0">
      <stop offset="0" stop-color="#4FC3F7"/>
      <stop offset="0.18" stop-color="#7C6CFF"/>
      <stop offset="0.36" stop-color="#E86BD8"/>
      <stop offset="0.52" stop-color="#FF5C6C"/>
      <stop offset="0.68" stop-color="#FFA24C"/>
      <stop offset="0.84" stop-color="#FFE45C"/>
      <stop offset="1" stop-color="#5EE08A"/>
    </linearGradient>
  </defs>
  <path d="{silhouette}" fill="{KB_SIDE}"/>
  <path d="{front}" fill="{KB_SIDE}"/>
  <path d="{right}" fill="{KB_SIDE_DARK}"/>
  <path d="{glow}" fill="url(#kb-underglow)"/>
  <path d="{top}" fill="{KB_CASE}" stroke="{GEAR_LINE}" stroke-width="{LINE_KEY}" stroke-linejoin="round"/>
  <path d="{rim}" fill="{KB_CASE_HI}"/>
  <path d="{''.join(skirts)}" fill="{KEYCAP_SIDE}" stroke="{KB_SIDE}" stroke-width="1.2" stroke-linejoin="round"/>
  <path d="{''.join(tops)}" fill="{KEYCAP}"/>
  <path d="{silhouette}" fill="none" stroke="{GEAR_LINE}" stroke-width="{LINE_MAIN}" stroke-linejoin="round"/>
</svg>
'''
    OUT.write_text(out)
    KEYS_OUT.write_text(json.dumps({
        "about": "Keycap legends for _shared/keyboard.svg, drawn with assets/fonts/Nunito-ExtraBold.ttf. "
                 "A glyph's x axis maps to `u` and its up axis to `v` (viewBox units per key unit; they point toward the animal's right and toward the viewer, since the board faces the animal), "
                 "centred on `center`, font size `em` key units, colour token keycap_legend. "
                 "Apply the animal's anchors.json keyboard transform on top.",
        "font": "assets/fonts/Nunito-ExtraBold.ttf",
        # glyph axes: the legends read upright for the animal, i.e. rotated 180 degrees for the viewer
        "u": [round(-U[0], 4), round(-U[1], 4)],
        "v": [round(-V[0], 4), round(-V[1], 4)],
        "color_token": "keycap_legend",
        "os_overrides": {os_: {str(r): labels for r, labels in rows.items()} for os_, rows in LEGENDS_OS.items()},
        "keys": legends,
    }, indent=1) + "\n")
    print(f"wrote {OUT} (BR={f(BR)}, bottom-right={f(BRb)}, front-right-bottom={f(FRb)})")


if __name__ == "__main__":
    main()
