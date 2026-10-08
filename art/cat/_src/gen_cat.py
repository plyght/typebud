#!/usr/bin/env python3
"""Generator for typebud's cat ("Mochi", an orange tabby). Writes every layer in art/cat/.

usage: python3 art/cat/_src/gen_cat.py && python3 scripts/render_art.py cat

Geometry follows art/SPEC.md; style follows art/STYLE.md. Shapely is only used at build time to
compute clean outlines (forearms tucked under the chin, stripes clipped to the head, headphone band
gaps behind the ears, the icon silhouette). The SVGs it writes are plain paths.
"""
import json
import math
from pathlib import Path

from shapely import affinity
from shapely.geometry import LineString, MultiLineString, MultiPolygon, Point, Polygon
from shapely.ops import unary_union

OUT = Path(__file__).resolve().parent.parent
ACC = OUT / "acc"

# ---------------------------------------------------------------- colors
LINE = "#3B2A1E"
WHITE = "#FFFFFF"
BLUSH, HATCH = "#F4A6A0", "#E07F7A"
CREAM = "#FBE3A0"
# fur placeholders (themes.json); real colors live in palette.json
MAIN, SHADE, LIGHT, LIGHT_SH, DARK, DARK_SH, FEAT = (
    "#B07A4A", "#8A5A33", "#E8C9A0", "#D4AE80", "#6B4A33", "#553A28", "#E88F7A")
PALETTE = {
    "fur_main": "#F4A257",        # warm marmalade orange
    "fur_shade": "#DC8540",
    "fur_light": "#FFEBCB",       # cream muzzle, chest, socks
    "fur_light_shade": "#F2D2A4",
    "fur_dark": "#CF6B2C",        # tabby stripes
    "fur_dark_shade": "#B45A22",
    "feature": "#F28F98",         # nose, inner ears, toe beans
}
# gear tokens
G_LINE, HP_BAND, HP_CUP, HP_SH, HP_GLOW = "#22252C", "#3B414E", "#474D5A", "#2F333D", "#9FE8FF"

SLEEP_T = "translate(-4 12) rotate(-6 152 80)"
HX, HY, HRX, HRY = 152.0, 82.0, 60.0, 47.0


# ---------------------------------------------------------------- helpers
def f(v):
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def poly_d(geom, tol=0.12):
    """SVG path data for a (Multi)Polygon, exterior + holes."""
    if geom.is_empty:
        return ""
    geom = geom.simplify(tol)
    polys = geom.geoms if isinstance(geom, MultiPolygon) else [geom]
    parts = []
    for p in polys:
        if p.is_empty or p.area < 0.5:
            continue
        for ring in [p.exterior, *p.interiors]:
            c = list(ring.coords)[:-1]
            parts.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in c) + "Z")
    return "".join(parts)


def line_d(geom, tol=0.12):
    """SVG path data for open (Multi)LineStrings."""
    if geom.is_empty:
        return ""
    geom = geom.simplify(tol)
    lines = geom.geoms if hasattr(geom, "geoms") else [geom]
    parts = []
    for ln in lines:
        if ln.geom_type != "LineString" or ln.length < 1.0:
            continue
        parts.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in ln.coords))
    return "".join(parts)


def fill(d, color, extra=""):
    return f'<path d="{d}" fill="{color}"{extra}/>' if d else ""


def stroke(d, w, color=LINE, extra=""):
    if not d:
        return ""
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" '
            f'stroke-linecap="round" stroke-linejoin="round"{extra}/>')


def outlined(d, color, w=5, line=LINE):
    return (f'<path d="{d}" fill="{color}" stroke="{line}" stroke-width="{w}" '
            f'stroke-linejoin="round" stroke-linecap="round"/>')


def svg(body, comment):
    lines = "\n  ".join(x for x in body if x)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">\n'
            f'  <!-- {comment} -->\n  {lines}\n</svg>\n')


def ellipse_poly(cx, cy, rx, ry, rot=0.0, res=48):
    e = affinity.scale(Point(0, 0).buffer(1, resolution=res), rx, ry)
    if rot:
        e = affinity.rotate(e, rot, origin=(0, 0))
    return affinity.translate(e, cx, cy)


def catmull(pts, n=12):
    """Smooth curve through pts (Catmull-Rom), returned as a dense point list."""
    pts = [pts[0]] + list(pts) + [pts[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t
                                    + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    out.append(pts[-2])
    return out


def cubic(p0, p1, p2, p3, n=40):
    out = []
    for k in range(n + 1):
        t = k / n
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def tube(pts, r0, r1):
    """Union of discs along a curve, radius r0 -> r1: a soft tapered tube."""
    n = len(pts)
    discs = [Point(p).buffer(r0 + (r1 - r0) * i / (n - 1), resolution=24) for i, p in enumerate(pts)]
    segs = []
    for i in range(n - 1):
        ra = r0 + (r1 - r0) * i / (n - 1)
        rb = r0 + (r1 - r0) * (i + 1) / (n - 1)
        segs.append(unary_union([discs[i], discs[i + 1]]).convex_hull)
    return unary_union(segs)


def rounded(points, radii):
    """Rounded polygon: SVG path data (quadratic corners) + a sampled shapely Polygon."""
    n = len(points)
    if not isinstance(radii, (list, tuple)):
        radii = [radii] * n
    d, samples = [], []
    for i in range(n):
        v = points[i]
        a, b = points[i - 1], points[(i + 1) % n]
        r = radii[i]

        def toward(p, q, r):
            dx, dy = q[0] - p[0], q[1] - p[1]
            L = math.hypot(dx, dy)
            return (p[0] + dx / L * r, p[1] + dy / L * r)
        s, e = toward(v, a, r), toward(v, b, r)
        d.append(("M" if i == 0 else "L") + f"{f(s[0])} {f(s[1])} Q{f(v[0])} {f(v[1])} {f(e[0])} {f(e[1])}")
        for k in range(9):
            t = k / 8
            samples.append(((1 - t) ** 2 * s[0] + 2 * t * (1 - t) * v[0] + t * t * e[0],
                            (1 - t) ** 2 * s[1] + 2 * t * (1 - t) * v[1] + t * t * e[1]))
    return "".join(d) + "Z", Polygon(samples)


def sleep_geom(g):
    return affinity.translate(affinity.rotate(g, -6, origin=(152, 80)), -4, 12)


# ---------------------------------------------------------------- head
HEAD = ellipse_poly(HX, HY, HRX, HRY, res=64)
HEAD_D = (f"M{f(HX - HRX)} {f(HY)} A{f(HRX)} {f(HRY)} 0 1 1 {f(HX + HRX)} {f(HY)} "
          f"A{f(HRX)} {f(HRY)} 0 1 1 {f(HX - HRX)} {f(HY)}Z")


def ear_pts(side, perk=False):
    if side == "L":
        tip = (101, 25.5) if perk else (104, 29)
        return [(99, 64), tip, (141, 44)]
    tip = (199, 25.5) if perk else (196, 28.5)
    return [(163, 43), tip, (207, 64)]


def ear(side, perk=False):
    pts = ear_pts(side, perk)
    d, poly = rounded(pts, [2, 6.5, 2])
    # inner ear: shrink toward a point near the base middle
    cx = (pts[0][0] + pts[2][0]) / 2 * 0.62 + pts[1][0] * 0.38
    cy = (pts[0][1] + pts[2][1]) / 2 * 0.62 + pts[1][1] * 0.38 + 4
    inner_pts = [(cx + (x - cx) * 0.56, cy + (y - cy) * 0.56) for x, y in pts]
    di, ipoly = rounded(inner_pts, [1.5, 4, 1.5])
    return d, poly, di


EARS_ALL = unary_union([ear(s, p)[1] for s in "LR" for p in (False, True)])


def tapered(a, b, r0, r1):
    return tube([a, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), b], r0, r1)


HEAD_STRIPES = unary_union([
    tapered((146, 30), (147, 55), 5.2, 1.2),
    tapered((129, 33), (134.5, 52), 4.4, 1.0),
    tapered((164, 31), (159.5, 51), 4.4, 1.0),
    tapered((88, 73), (104, 76), 3.6, 1.0),
    tapered((88, 84), (102, 85.5), 3.2, 0.9),
    tapered((216, 71), (201, 74), 3.6, 1.0),
    tapered((216, 82), (203, 83.5), 3.2, 0.9),
]).intersection(HEAD)

MUZZLE_D = ("M125 101 C125 92.5 133 89.5 144 90.5 C155 89.5 163 92.5 163 101 C163 108.5 157.5 111 152 110.5 "
            "C148.5 110 145.5 108.5 144 106.5 C142.5 108.5 139.5 110 136 110.5 C130.5 111 125 108.5 125 101Z")
HEAD_SHADE = HEAD.difference(affinity.translate(HEAD, -6, -6)).intersection(
    Polygon([(160, 82), (240, 60), (240, 140), (150, 140)]))


def head_layers(eyes="content", mouth="w", perk=False):
    out = []
    for s in "LR":
        d, _, di = ear(s, perk)
        out += [outlined(d, MAIN, 5), fill(di, FEAT)]
    out += [fill(HEAD_D, MAIN), fill(poly_d(HEAD_SHADE), SHADE), fill(poly_d(HEAD_STRIPES), DARK),
            fill(MUZZLE_D, LIGHT), stroke(HEAD_D, 5)]
    out += face(eyes, mouth)
    return out


def face(eyes, mouth):
    out = []
    # blush
    out += ['<ellipse cx="110" cy="102" rx="8" ry="4.5" fill="#F4A6A0"/>',
            '<ellipse cx="178" cy="100" rx="8" ry="4.5" fill="#F4A6A0"/>',
            stroke("M106 104 L108 100 M109.5 104.5 L111.5 100.5 M113 104 L115 100 "
                   "M174 102 L176 98 M177.5 102.5 L179.5 98.5 M181 102 L183 98", 1.6, HATCH)]
    # whiskers: two short strokes per side, poking past the cheek
    out.append(stroke("M101 97 L86 94.5 M101.5 103 L87 104.5 M194 95 L211 92 M194.5 101 L210 102.5", 3))
    L, R = (122.5, 87), (165.5, 85)
    if eyes == "content":
        out.append(stroke("M115 87 Q122.5 88.5 130 87 M158 85 Q165.5 86.5 173 85", 4.5))
    elif eyes == "open":
        for (x, y) in (L, R):
            out += [f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="4.3" ry="5.4" fill="{LINE}"/>',
                    f'<circle cx="{f(x - 1.5)}" cy="{f(y - 2.1)}" r="1.6" fill="{WHITE}"/>']
    elif eyes == "happy":
        out.append(stroke("M115 90 Q122.5 80 130 90 M158 88 Q165.5 78 173 88", 4.5))
    elif eyes == "sleepy":
        out.append(stroke("M115.5 85 Q122.5 92.5 129.5 85 M158.5 83 Q165.5 90.5 172.5 83", 4.5))
    elif eyes == "wake":
        x, y = L
        out += [f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="4.3" ry="5.4" fill="{LINE}"/>',
                f'<circle cx="{f(x - 1.5)}" cy="{f(y - 2.1)}" r="1.6" fill="{WHITE}"/>',
                stroke("M158.5 83 Q165.5 90.5 172.5 83", 4.5)]
    # nose + mouth
    nose = "M139.8 94 Q144 92.6 148.2 94 Q147.2 97.6 144 98.6 Q140.8 97.6 139.8 94Z"
    if mouth == "open":
        out.append(f'<path d="M137 101 Q140.5 104.5 144 101.5 Q147.5 104.5 151 101 Q150.5 111.5 144 111.5 '
                   f'Q137.5 111.5 137 101Z" fill="{FEAT}" stroke="{LINE}" stroke-width="3.5" stroke-linejoin="round"/>')
        out.append(stroke("M144 98.6 L144 101.5", 3))
    else:
        out.append(stroke("M144 98.6 L144 101 M137 100.5 Q140.5 105 144 101 Q147.5 105 151 100.5", 3.5))
    out.append(f'<path d="{nose}" fill="{FEAT}" stroke="{LINE}" stroke-width="3" stroke-linejoin="round"/>')
    return out


# ---------------------------------------------------------------- body + tail
BODY_D = "M108 112 C91 136 89 178 99 203 Q153 216 207 207 C217 180 219 137 198 110Z"
BODY = Polygon(cubic((108, 112), (91, 136), (89, 178), (99, 203)) + cubic((207, 207), (217, 180), (219, 137), (198, 110)))
BIB_D = "M124 114 C121 138 128 160 146 168 C164 170 178 152 180 116Z"
BODY_SHADE_D = "M197 122 C209 144 211 176 205 205 L186 205 C195 178 196 150 185 128Z"
BODY_STRIPES = unary_union([
    tapered((222, 132), (199, 129), 4.2, 1.0),
    tapered((222, 150), (201, 148), 4.0, 1.0),
    tapered((86, 150), (101, 147), 3.6, 1.0),
]).intersection(BODY)
CHIN_SHADOW_D = "M126 120 C134 133 160 137 178 122 L178 116 L126 116Z"

TAILS = {
    "idle": [(116, 190), (90, 186), (77, 164), (78, 140), (88, 125), (102, 122)],
    "type_left": [(116, 190), (90, 186), (77, 164), (77, 138), (82, 120), (93, 112)],
    "type_right": [(116, 190), (90, 186), (75, 164), (72, 140), (75, 123), (84, 114)],
    "type_both": [(116, 190), (90, 186), (77, 164), (79, 142), (90, 129), (104, 127)],
    "excited": [(116, 190), (90, 186), (76, 164), (74, 134), (77, 112), (87, 100)],
    "sleep": [(116, 190), (88, 188), (76, 170), (79, 151), (92, 141), (104, 140)],
}
TAILS["peek"] = TAILS["hold"] = TAILS["sip"] = TAILS["idle"]
TAILS["wake"] = TAILS["sleep"]


def tail(frame):
    pts = catmull(TAILS[frame], 10)
    t = tube(pts, 9.5, 7.6)
    d = poly_d(t)
    # two tabby rings near the tip
    n = len(pts)
    rings = []
    for fr in (0.68, 0.86):
        i = int(fr * (n - 1))
        (x0, y0), (x1, y1) = pts[i - 1], pts[i + 1]
        dx, dy = x1 - x0, y1 - y0
        L = math.hypot(dx, dy)
        nx, ny = -dy / L, dx / L
        cx, cy = pts[i]
        rings.append(LineString([(cx - nx * 14 - dx / L * 2, cy - ny * 14 - dy / L * 2),
                                 (cx + nx * 14 + dx / L * 2, cy + ny * 14 + dy / L * 2)]).buffer(2.6))
    rd = poly_d(unary_union(rings).intersection(t))
    return [fill(d, MAIN), fill(rd, DARK), stroke(d, 5)]


def body_layers():
    return [fill(BODY_D, MAIN), fill(BIB_D, LIGHT), fill(CHIN_SHADOW_D, LIGHT_SH), fill(BODY_SHADE_D, SHADE),
            fill(poly_d(BODY_STRIPES), DARK), stroke(BODY_D, 5)]


# ---------------------------------------------------------------- paws
REST = {"L": (122, 168), "R": (160, 180)}
PAW_RX, PAW_RY = 13.5, 9.5


def paw_state(state, side):
    x, y = REST[side]
    if state == "rest":
        return (x, y), 14, PAW_RX, PAW_RY, "toes"
    if state == "pressed":
        return (x, y + 3), 14, PAW_RX * 1.06, PAW_RY * 0.85, "toes"
    if state == "raised":
        return (x + 2, y - 10), 0, PAW_RX, PAW_RY + 0.5, "beans"
    if state == "excited":
        return (x, y - 12), 0, PAW_RX, PAW_RY + 0.5, "beans"
    raise ValueError(state)


SHOULDER = {"L": (121, 133), "R": (185, 140)}


def arm_curve(side, paw, kind="type"):
    sx, sy = SHOULDER[side]
    px, py = paw
    if kind == "type":
        # short curled forearms: L bows out to the left "(", R bows out to the right ")"
        if side == "L":
            return cubic((sx, sy), (sx - 11, sy + 10), (px - 9, py - 8), (px, py), 24)
        return cubic((sx, sy), (sx + 4, sy + 16), (px + 13, py - 8), (px, py), 24)
    if kind == "hug":
        if side == "L":
            return cubic((113, 130), (106, 150), (124, 160), paw, 24)
        return cubic((200, 130), (206, 148), (196, 154), paw, 24)
    if kind == "sip":
        if side == "L":
            return cubic((116, 149), (111, 140), (121, 134), paw, 24)
        return cubic((200, 140), (210, 150), (188, 134), paw, 24)
    raise ValueError(kind)


def paw_shape(c, rot, rx, ry, deco):
    out = []
    cx, cy = c
    tr = f' transform="rotate({f(rot)} {f(cx)} {f(cy)})"' if rot else ""
    out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="{LIGHT}"/>')
    pe = ellipse_poly(cx, cy, rx, ry, rot)
    sh = pe.difference(affinity.translate(pe, -3.5, -3.5))
    out.append(fill(poly_d(sh), LIGHT_SH))
    if deco == "beans":
        out.append(f'<ellipse cx="{f(cx + 0.5)}" cy="{f(cy + 2.4)}" rx="4.6" ry="3.6" fill="{FEAT}"/>')
        out.append(f'<path d="M{f(cx - 6.6)} {f(cy - 2.4)} a2 2.2 0 1 0 0.01 0Z'
                   f'M{f(cx - 0.4)} {f(cy - 4.8)} a2 2.2 0 1 0 0.01 0Z'
                   f'M{f(cx + 6.6)} {f(cy - 3)} a2 2.2 0 1 0 0.01 0Z" fill="{FEAT}"/>')
    out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="none" stroke="{LINE}" stroke-width="4.5"/>')
    if deco == "toes":
        a = math.radians(rot)
        pts = []
        for ox in (-4.0, 4.0):
            # toe lines on the front (lower) edge of the paw
            x0, y0 = ox, ry - 4.2
            x1, y1 = ox + 0.6, ry - 0.6
            for (u, v) in ((x0, y0), (x1, y1)):
                pts.append((cx + u * math.cos(a) - v * math.sin(a), cy + u * math.sin(a) + v * math.cos(a)))
        out.append(stroke(f"M{f(pts[0][0])} {f(pts[0][1])} L{f(pts[1][0])} {f(pts[1][1])} "
                          f"M{f(pts[2][0])} {f(pts[2][1])} L{f(pts[3][0])} {f(pts[3][1])}", 2.5))
    return out


def arm(side, curve, head_clip, r0=14.0, r1=12.0, stripe_at=(0.45,), below_kb=False):
    poly = tube(curve, r0, r1)
    sx, sy = curve[0]
    root = Point(sx, sy).buffer(r0 + 1.2)
    if head_clip is not None:
        poly = poly.difference(head_clip.buffer(2.0))
    if below_kb:
        # hug/sip arms melt into the body above the keyboard's back edge, never over the keys
        poly = poly.difference(Polygon([(0, 146 + 0.257 * -80 - 3), (256, 146 + 0.257 * 176 - 3), (256, 256), (0, 256)]))
    # stripes across the forearm
    stripes = []
    n = len(curve)
    for fr in stripe_at:
        i = int(fr * (n - 1))
        (x0, y0), (x1, y1) = curve[max(i - 1, 0)], curve[min(i + 1, n - 1)]
        dx, dy = x1 - x0, y1 - y0
        L = math.hypot(dx, dy)
        nx, ny = -dy / L, dx / L
        cx, cy = curve[i]
        stripes.append(LineString([(cx - nx * 16 + dx / L * 3, cy - ny * 16 + dy / L * 3),
                                   (cx + nx * 16 - dx / L * 1, cy + ny * 16 - dy / L * 1)]).buffer(2.8))
    stripe = unary_union(stripes).intersection(poly) if stripes else Polygon()
    shade = poly.difference(affinity.translate(poly, -5, -2))
    if side == "L":
        shade = shade.intersection(Point(curve[-1]).buffer(16))
    edge = poly.boundary.difference(root)
    if below_kb:
        edge = edge.difference(Polygon([(0, 146 + 0.257 * -80 - 4), (256, 146 + 0.257 * 176 - 4), (256, 256), (0, 256)]))
    if head_clip is not None:
        edge = edge.difference(head_clip.buffer(3.4))
    d = poly_d(poly)
    return [fill(d, MAIN), fill(poly_d(shade), SHADE), fill(poly_d(stripe), DARK), stroke(line_d(edge), 5)]


def paws_layer(lstate, rstate, sleeping=False):
    head = sleep_geom(HEAD) if sleeping else HEAD
    out = []
    for side, st in (("L", lstate), ("R", rstate)):
        c, rot, rx, ry, deco = paw_state(st, side)
        out += arm(side, arm_curve(side, c), head)
    for side, st in (("L", lstate), ("R", rstate)):
        c, rot, rx, ry, deco = paw_state(st, side)
        out += paw_shape(c, rot, rx, ry, deco)
    return out


def hug_paws(kind):
    if kind == "hug":
        pl, pr = (148, 152), (182, 146)
        rl, rr = -20, 20
        clip = HEAD
    else:
        pl, pr = SIP_PAWS
        rl, rr = -30, 15
        clip = None
    out = []
    out += arm("L", arm_curve("L", pl, kind), clip, 13.5, 11.5, stripe_at=(0.4,), below_kb=True)
    out += arm("R", arm_curve("R", pr, kind), clip, 13.5, 11.5, stripe_at=(0.4,), below_kb=True)
    for c, rot in ((pl, rl), (pr, rr)):
        cx, cy = c
        out.append(f'<ellipse cx="{cx}" cy="{cy}" rx="11.5" ry="9.5" transform="rotate({rot} {cx} {cy})" '
                   f'fill="{LIGHT}" stroke="{LINE}" stroke-width="4.5"/>')
    (lx, ly), (rx_, ry_) = pl, pr
    out.append(stroke(f"M{lx + 4} {ly - 4} L{lx + 7.5} {ly - 5} M{lx + 5} {ly + 2.5} L{lx + 8.5} {ly + 2} "
                      f"M{rx_ - 4} {ry_ - 4} L{rx_ - 7.5} {ry_ - 4.5} M{rx_ - 4.5} {ry_ + 2.5} L{rx_ - 8} {ry_ + 2.5}", 2.5))
    return out


SIP_ANCHOR = (147, 116, -24)
SIP_PAWS = ((134, 132), (168, 124))


# ---------------------------------------------------------------- frames
FRAMES = {
    # frame: (eyes, mouth, perk, sleeping, paws)
    "idle": ("content", "w", False, False, ("rest", "rest")),
    "peek": ("open", "w", False, False, None),
    "type_left": ("content", "w", False, False, ("pressed", "raised")),
    "type_right": ("content", "w", False, False, ("raised", "pressed")),
    "type_both": ("content", "w", False, False, ("pressed", "pressed")),
    "excited": ("happy", "open", True, False, ("excited", "excited")),
    "sleep": ("sleepy", "w", False, True, ("rest", "rest")),
    "wake": ("wake", "w", False, True, None),
    "hold": ("content", "w", False, False, "hug"),
    "sip": ("happy", "w", False, False, "sip"),
}


def write(path, body, comment):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg(body, comment))


def build_frames():
    for name, (eyes, mouth, perk, sleeping, paws) in FRAMES.items():
        body = tail(name) + body_layers()
        head = head_layers(eyes, mouth, perk)
        if sleeping:
            body.append(f'<g transform="{SLEEP_T}">')
            body += head
            body.append("</g>")
        else:
            body += head
        write(OUT / f"{name}.svg", body,
              f"typebud cat (Mochi): {name}. Body, tail, head, ears, face; no forearms (see {name}_paws.svg).")
        if paws is None:
            continue
        if paws in ("hug", "sip"):
            pb = hug_paws(paws)
        else:
            pb = paws_layer(*paws, sleeping=sleeping)
        write(OUT / f"{name}_paws.svg", pb,
              f"typebud cat (Mochi): forearms + paws for {name}, drawn after the keyboard.")


# ---------------------------------------------------------------- headphones
HP_RING = """<defs>
    <linearGradient id="hp-ring" gradientUnits="userSpaceOnUse" x1="0" y1="75" x2="0" y2="109">
      <stop offset="0" stop-color="#4FC3F7"/>
      <stop offset="0.25" stop-color="#7C6CFF"/>
      <stop offset="0.45" stop-color="#E86BD8"/>
      <stop offset="0.62" stop-color="#FF5C6C"/>
      <stop offset="0.8" stop-color="#FFE45C"/>
      <stop offset="1" stop-color="#5EE08A"/>
    </linearGradient>
  </defs>"""


def headphones_body():
    band = LineString(cubic((89, 78), (86, 22), (217, 16), (209, 72), 80))
    cut = EARS_ALL.buffer(2.6)
    outer = band.buffer(7, cap_style="round").difference(cut)
    inner = band.buffer(3.25, cap_style="round").difference(cut.buffer(3.4))
    hl = LineString(cubic((104, 45), (120, 30), (150, 26), (176, 30), 40)).buffer(1.25).difference(cut.buffer(3.0))
    hl = hl.intersection(inner)
    out = [
        # far cup crescent outside the head's left edge
        f'<path d="M95 65 C83 64 78 76 78 86 C78 96 83 106 96 103 C92 96 91 90 91 84 C91 77 92 71 95 65Z" '
        f'fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5" stroke-linejoin="round"/>',
        fill(poly_d(outer), G_LINE), fill(poly_d(inner), HP_BAND), fill(poly_d(hl), HP_CUP),
        f'<ellipse cx="202" cy="88" rx="11" ry="22" fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'<ellipse cx="212" cy="89" rx="13" ry="22" fill="{HP_CUP}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'<ellipse cx="214" cy="89" rx="6.5" ry="14" fill="{HP_GLOW}" stroke="url(#hp-ring)" stroke-width="3.5"/>',
        f'<ellipse cx="215" cy="89" rx="3" ry="8.5" fill="{HP_CUP}"/>',
    ]
    return out


# ---------------------------------------------------------------- other head items
BEANIE_C, BEANIE_SH, BEANIE_RIB = "#7FB8C8", "#5F9BAD", "#4E8798"


def beanie_body():
    cuff_line = cubic((88, 70), (120, 54), (184, 52), (216, 70), 40)
    top = ellipse_poly(HX, HY - 1, HRX + 4, HRY + 3, res=64)
    above = Polygon(cuff_line + [(216, 0), (88, 0)])
    dome = top.intersection(above)
    cuff_lo = cubic((86, 74), (120, 59), (184, 57), (218, 74), 40)
    cuff_hi = [(x, y - 11) for x, y in cubic((86, 74), (120, 59), (184, 57), (218, 74), 40)]
    cuff = Polygon(cuff_lo + cuff_hi[::-1]).buffer(1.5).intersection(top.buffer(0.5))
    hat = unary_union([dome, cuff]).difference(EARS_ALL.buffer(1.0))
    cuff = cuff.difference(EARS_ALL.buffer(1.0))
    shade = hat.difference(affinity.translate(hat, -7, -3))
    ribs = []
    for k in range(13):
        t = (k + 0.5) / 13
        i = int(t * 40)
        x, y = cuff_lo[i]
        ribs.append(LineString([(x, y - 2.5), (x, y - 9)]))
    ribs = MultiLineString(ribs).intersection(cuff.buffer(-1.5))
    knit = MultiLineString([LineString(cubic((112, 52), (122, 46), (130, 42), (140, 40), 10)),
                            LineString(cubic((160, 40), (170, 41), (180, 45), (190, 51), 10))]).difference(EARS_ALL.buffer(4))
    hd = poly_d(hat)
    return [
        fill(hd, BEANIE_C, ' fill-rule="evenodd"'), fill(poly_d(shade), BEANIE_SH),
        stroke(line_d(ribs), 2.2, BEANIE_RIB), stroke(line_d(knit), 2.2, BEANIE_RIB),
        stroke(poly_d(cuff), 3.5), stroke(hd, 4.5),
        # little knitted nub on top
        f'<path d="M146 34 Q147 27 153 27.5 Q158 28.5 157 34Z" fill="{BEANIE_C}" stroke="{LINE}" stroke-width="3.5" stroke-linejoin="round"/>',
    ]


def party_hat_body():
    d = "M132 59.5 Q128.5 56.5 130.5 53 L149 33 Q152 30 155 33 L172 52 Q174 55.5 170 57.5 Q151 62.5 132 59.5Z"
    cone = Polygon([(132, 59.5), (130.5, 53), (149, 33), (152, 31), (155, 33), (172, 52), (170, 57.5), (151, 61.5)])
    stripes = unary_union([LineString([(130, 47), (175, 38)]).buffer(2.6),
                           LineString([(128, 60), (178, 50)]).buffer(2.4)]).intersection(cone.buffer(-0.5))
    shade = cone.difference(affinity.translate(cone, -5, 0))
    return [
        fill(d, "#F7A8C4"), fill(poly_d(shade), "#E68AAD"), fill(poly_d(stripes), CREAM), stroke(d, 4.5),
        f'<circle cx="152" cy="31" r="4.6" fill="{CREAM}" stroke="{LINE}" stroke-width="3.5"/>',
        f'<circle cx="142" cy="45" r="1.9" fill="#7FB8C8"/><circle cx="160" cy="48" r="1.9" fill="#7FB8C8"/>',
    ]


def bow_body():
    g = ('<g transform="translate(183 47) rotate(14)">'
         '<path d="M-3 -1 Q-10 -12 -17 -9 Q-21 -1 -17 7 Q-10 9 -3 2Z" fill="#F27C93" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>'
         '<path d="M3 -1 Q10 -12 17 -9 Q21 -1 17 7 Q10 9 3 2Z" fill="#F27C93" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>'
         '<path d="M6 4 Q12 7 16.5 5.5 L17 7 Q10 9 3 2Z M-13 -7.5 Q-11 -3 -6 -1" fill="#D95E78"/>'
         '<path d="M-12 -5 Q-9 -6.5 -6.5 -3 M12 -5 Q9 -6.5 6.5 -3" fill="none" stroke="#3B2A1E" stroke-width="2.2" stroke-linecap="round"/>'
         '<ellipse cx="0" cy="0.5" rx="5" ry="5.5" fill="#F27C93" stroke="#3B2A1E" stroke-width="4"/>'
         '<circle cx="-1.6" cy="-1.4" r="1.3" fill="#FFFFFF"/>'
         '</g>')
    return [g]


def glasses_body():
    fr = "#3B2A1E"
    return [
        f'<circle cx="122.5" cy="87" r="13" fill="#FFFFFF" fill-opacity="0.28"/>',
        f'<circle cx="165.5" cy="85" r="13" fill="#FFFFFF" fill-opacity="0.28"/>',
        stroke("M115 80 Q117.5 77.5 121 77 M158 78 Q160.5 75.5 164 75", 2.4, WHITE),
        stroke("M135.5 86 Q144 80.5 152.5 84.5 M178.5 84 L206 79 M109.5 87.5 L94 85", 4, fr),
        f'<circle cx="122.5" cy="87" r="13" fill="none" stroke="{fr}" stroke-width="4.5"/>',
        f'<circle cx="165.5" cy="85" r="13" fill="none" stroke="{fr}" stroke-width="4.5"/>',
        f'<circle cx="122.5" cy="87" r="13" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
        f'<circle cx="165.5" cy="85" r="13" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
    ]


def build_acc():
    items = {
        "headphones": (headphones_body, HP_RING, "headphones refit to the cat head (H 152,82; rx 60, ry 47); band gaps behind both ears."),
        "beanie": (beanie_body, "", "knit beanie on the crown, ears poke through two holes."),
        "party_hat": (party_hat_body, "", "party hat on the forehead between the ears."),
        "bow": (bow_body, "", "ribbon bow at the base of the near ear."),
        "glasses": (glasses_body, "", "round glasses over the eyes, arm to the near side."),
    }
    for name, (fn, defs, note) in items.items():
        b = fn()
        pre = [defs] if defs else []
        write(ACC / f"{name}.svg", pre + ["<g>"] + b + ["</g>"], f"typebud cat: {note}")
        write(ACC / f"{name}_sleep.svg", pre + [f'<g transform="{SLEEP_T}">'] + b + ["</g>"],
              f"typebud cat: {note} Sleep: same drawing in the sleep head transform.")


# ---------------------------------------------------------------- held items (sip position)
def build_hold():
    shared = OUT.parent / "_shared"
    sx, sy, sr = SIP_ANCHOR
    for item in ("hold_coffee", "hold_boba", "hold_book"):
        src = (shared / f"{item}.svg").read_text()
        import re
        sip = re.sub(r'<g transform="translate\([^)]*\) rotate\([^)]*\)">',
                     f'<g transform="translate({sx} {sy}) rotate({sr})">', src, count=1)
        sip = sip.replace("hug position", "cat sip position (raised to the mouth)")
        (ACC / f"sip_{item[5:]}.svg").write_text(sip)


# ---------------------------------------------------------------- icons
def icon_geom():
    # front-facing face, head fills x 16..240
    cx, cy, rx, ry = 128, 146, 100, 80
    head = ellipse_poly(cx, cy, rx, ry, res=64)
    el, l_poly = rounded([(34, 130), (40, 34), (102, 72)], [4, 18, 4])
    er, r_poly = rounded([(154, 72), (216, 34), (222, 130)], [4, 18, 4])
    sil = unary_union([head, l_poly, r_poly])
    return cx, cy, rx, ry, head, (el, l_poly), (er, r_poly), sil


def build_icons():
    cx, cy, rx, ry, head, (el, lp), (er, rp), sil = icon_geom()
    hd = (f"M{cx - rx} {cy} A{rx} {ry} 0 1 1 {cx + rx} {cy} A{rx} {ry} 0 1 1 {cx - rx} {cy}Z")
    inner_l = rounded([(56, 112), (52, 62), (90, 86)], [3, 10, 3])[0]
    inner_r = rounded([(166, 86), (204, 62), (200, 112)], [3, 10, 3])[0]
    stripes = unary_union([tapered((128, 60), (128, 100), 11, 3), tapered((98, 66), (106, 96), 9, 2.5),
                           tapered((158, 66), (150, 96), 9, 2.5)]).intersection(head)
    muzzle = ellipse_poly(110, 182, 24, 18).union(ellipse_poly(146, 182, 24, 18)).union(ellipse_poly(128, 170, 22, 14))
    body = [
        outlined(el, MAIN, 16), outlined(er, MAIN, 16), fill(inner_l, FEAT), fill(inner_r, FEAT),
        fill(hd, MAIN), fill(poly_d(stripes), DARK), fill(poly_d(muzzle), LIGHT),
        '<ellipse cx="62" cy="180" rx="16" ry="10" fill="#F4A6A0"/>',
        '<ellipse cx="194" cy="180" rx="16" ry="10" fill="#F4A6A0"/>',
        stroke(hd, 16),
        stroke("M66 146 Q80 150 94 146 M162 146 Q176 150 190 146", 18),
        stroke("M108 180 Q118 192 128 182 Q138 192 148 180", 12),
        f'<path d="M116 160 Q128 156 140 160 Q137 170 128 172 Q119 170 116 160Z" fill="{FEAT}" stroke="{LINE}" stroke-width="8" stroke-linejoin="round"/>',
    ]
    write(OUT / "icon.svg", body, "typebud cat icon: front face only, outline 16, eyes 18; reads at 16 px.")
    # template: silhouette (incl. outline width) with eyes + mouth + nose as even-odd holes
    outer = sil.buffer(8, join_style="round")
    holes = unary_union([
        LineString(cubic((66, 146), (75, 149), (85, 149), (94, 146), 12)).buffer(9),
        LineString(cubic((162, 146), (171, 149), (181, 149), (190, 146), 12)).buffer(9),
        LineString(cubic((108, 180), (114, 190), (122, 190), (128, 182), 12)
                   + cubic((128, 182), (134, 190), (142, 190), (148, 180), 12)[1:]).buffer(6.5),
    ])
    tmpl = outer.difference(holes)
    write(OUT / "icon_template.svg", [f'<path d="{poly_d(tmpl)}" fill="#000000" fill-rule="evenodd"/>'],
          "typebud cat icon template: pure black silhouette, eyes and mouth cut out (even-odd).")


if __name__ == "__main__":
    build_frames()
    build_acc()
    build_hold()
    build_icons()
    (OUT / "palette.json").write_text(json.dumps(PALETTE, indent=2) + "\n")
    print("cat: wrote frames, paws, acc/, icons, palette.json")
