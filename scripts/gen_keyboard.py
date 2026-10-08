#!/usr/bin/env python3
"""Generate art/_shared/keyboard.svg from the shared keyboard geometry in art/SPEC.md.

The keyboard is a 60% board seen in 3/4 view. Every point is mapped through one affine
transform: P(s, t) = origin + s*u + t*v, with s in key units along the board (left -> right) and
t in rows from the front edge (0) to the back edge. Re-run after changing the numbers below.
usage: scripts/gen_keyboard.py
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "art" / "_shared" / "keyboard.svg"

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

ROW_LAYOUT = [            # front (space row) to back (number row)
    [1.25, 1.25, 1.25, 6.25, 1.25, 1.25, 1.25, 1.25],
    [2.25] + [1] * 10 + [2.75],
    [1.75] + [1] * 11 + [2.25],
    [1.5] + [1] * 12 + [1.5],
    [1] * 13 + [2],
]

LINE_MAIN, LINE_KEY, LINE_LEGEND = 4.5, 2.0, 1.6
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
    for row, widths in enumerate(ROW_LAYOUT):
        s = 0.0
        t0, t1 = row + GAP, row + 1 - GAP
        for i, w in enumerate(widths):
            s0, s1 = s + GAP, s + w - GAP
            skirts.append(rounded([P(s0, t0), P(s1, t0), P(s1, t1), P(s0, t1)], 1.2))
            ti = 0.10
            tops.append(rounded([P(s0 + ti, t0 + 0.26, -CAP_RISE), P(s1 - ti, t0 + 0.26, -CAP_RISE),
                                 P(s1 - ti, t1 - 0.04, -CAP_RISE), P(s0 + ti, t1 - 0.04, -CAP_RISE)], 1.0))
            cs, ct = (s0 + s1) / 2, (t0 + t1) / 2 + 0.12
            if w == 1:
                # alternate tiny glyph strokes so the board reads as "legends", not a grid of dots
                k = (row * 7 + i * 3) % 4
                if k == 0:
                    a, b = P(cs - 0.18, ct, -CAP_RISE), P(cs + 0.18, ct, -CAP_RISE)
                elif k == 1:
                    a, b = P(cs, ct - 0.18, -CAP_RISE), P(cs, ct + 0.18, -CAP_RISE)
                elif k == 2:
                    a, b = P(cs - 0.14, ct - 0.14, -CAP_RISE), P(cs + 0.14, ct + 0.14, -CAP_RISE)
                else:
                    a = b = P(cs, ct, -CAP_RISE)
                legends.append(f"M{f(a)} L{f(b)}")
            elif row in (1, 2, 3) or (row == 4 and i == len(widths) - 1):
                # modifier keys: a short stroke near the outer edge
                a, b = P(s0 + 0.35, ct, -CAP_RISE), P(s0 + 0.85, ct, -CAP_RISE)
                legends.append(f"M{f(a)} L{f(b)}")
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
  <path d="{''.join(skirts)}" fill="{KEYCAP_SIDE}" stroke="{GEAR_LINE}" stroke-width="{LINE_KEY}" stroke-linejoin="round"/>
  <path d="{''.join(tops)}" fill="{KEYCAP}"/>
  <path d="{''.join(legends)}" fill="none" stroke="{KEYCAP_LEGEND}" stroke-width="{LINE_LEGEND}" stroke-linecap="round"/>
  <path d="{silhouette}" fill="none" stroke="{GEAR_LINE}" stroke-width="{LINE_MAIN}" stroke-linejoin="round"/>
</svg>
'''
    OUT.write_text(out)
    print(f"wrote {OUT} (BR={f(BR)}, bottom-right={f(BRb)}, front-right-bottom={f(FRb)})")


if __name__ == "__main__":
    main()
