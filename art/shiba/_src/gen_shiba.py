#!/usr/bin/env python3
"""Generator for typebud's shiba ("Kinako"). Writes every layer in art/shiba/.

usage: python3 art/shiba/_src/gen_shiba.py && python3 scripts/render_art.py shiba

Geometry follows art/SPEC.md; style follows art/STYLE.md. Shapely is only used at build time to
compute clean shapes (fluffy silhouettes, the cream "urajiro" mask clipped to the head, forearms
melting into the chest, headphone band gaps behind the ears, the icon template). The SVGs it writes
are plain paths.
"""
import json
import math
import re
from pathlib import Path

from shapely import affinity
from shapely.geometry import LineString, MultiLineString, MultiPolygon, Point, Polygon
from shapely.ops import unary_union

OUT = Path(__file__).resolve().parent.parent
ACC = OUT / "acc"
SHARED = OUT.parent / "_shared"

# ---------------------------------------------------------------- colors
LINE = "#3B2A1E"
WHITE = "#FFFFFF"
BLUSH, HATCH = "#F4A6A0", "#E07F7A"
CREAM = "#FBE3A0"
MOUTH_IN = "#A2493F"          # open-mouth interior (fixed)
# fur placeholders (themes.json); real colors live in palette.json
MAIN, SHADE, LIGHT, LIGHT_SH, DARK, DARK_SH, FEAT = (
    "#B07A4A", "#8A5A33", "#E8C9A0", "#D4AE80", "#6B4A33", "#553A28", "#E88F7A")
PALETTE = {
    "fur_main": "#E8863F",        # shiba red: a deeper, redder orange than the cat
    "fur_shade": "#CB6A2A",
    "fur_light": "#FFF0D8",       # urajiro cream: cheeks, muzzle, brows, chest, socks, tail underside
    "fur_light_shade": "#F1D6B0",
    "fur_dark": "#C45F24",        # saddle on the tail curl
    "fur_dark_shade": "#A84E1C",
    "feature": "#F48C93",         # tongue, toe beans
}
G_LINE, HP_BAND, HP_CUP, HP_SH, HP_GLOW = "#22252C", "#3B414E", "#474D5A", "#2F333D", "#9FE8FF"


# ---------------------------------------------------------------- helpers
def f(v):
    s = f"{v:.1f}"
    s = s[:-2] if s.endswith(".0") else s
    return "0" if s == "-0" else s


def poly_d(geom, tol=0.15):
    if geom.is_empty:
        return ""
    geom = geom.simplify(tol)
    polys = geom.geoms if hasattr(geom, "geoms") else [geom]
    parts = []
    for p in polys:
        if p.geom_type != "Polygon" or p.is_empty or p.area < 0.5:
            continue
        for ring in [p.exterior, *p.interiors]:
            c = list(ring.coords)[:-1]
            parts.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in c) + "Z")
    return "".join(parts)


def line_d(geom, tol=0.15):
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


def merge_lines(geom):
    from shapely.ops import linemerge
    if geom.is_empty:
        return geom
    if geom.geom_type == "MultiLineString":
        return linemerge(geom)
    return geom


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


def write(path, body, comment):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg(body, comment))


def ellipse_poly(cx, cy, rx, ry, rot=0.0, res=48):
    e = affinity.scale(Point(0, 0).buffer(1, resolution=res), rx, ry)
    if rot:
        e = affinity.rotate(e, rot, origin=(0, 0))
    return affinity.translate(e, cx, cy)


def catmull(pts, n=12, closed=False):
    pts = list(pts)
    if closed:
        ext = [pts[-1]] + pts + [pts[0], pts[1]]
    else:
        ext = [pts[0]] + pts + [pts[-1]]
    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t
                                    + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    if not closed:
        out.append(pts[-1])
    return out


def blob(pts, n=12):
    return Polygon(catmull(pts, n, closed=True)).buffer(0)


def cubic(p0, p1, p2, p3, n=40):
    out = []
    for k in range(n + 1):
        t = k / n
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def tube(pts, r0, r1):
    n = len(pts)
    discs = [Point(p).buffer(r0 + (r1 - r0) * i / (n - 1), resolution=24) for i, p in enumerate(pts)]
    return unary_union([unary_union([discs[i], discs[i + 1]]).convex_hull for i in range(n - 1)])


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


def eye_dot(x, y, rx=4.3, ry=5.4):
    return [f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="{rx}" ry="{ry}" fill="{LINE}"/>',
            f'<circle cx="{f(x - 1.5)}" cy="{f(y - 2.1)}" r="1.6" fill="{WHITE}"/>']


# ---------------------------------------------------------------- head geometry
HX, HY = 148.0, 84.0
# the dropped head stays just above the keyboard's back edge, so the chin never slips under the board
SLEEP_DY = 26
SLEEP_T = f"translate(-3 {SLEEP_DY}) rotate(-8 148 84)"


def sleep_geom(g):
    return affinity.translate(affinity.rotate(g, -8, origin=(148, 84)), -3, SLEEP_DY)


# Fox-like wedge: round crown, cheeks flaring out into two soft fluff tufts, tapering to the muzzle.
HEAD_PTS = [
    (148, 37), (176, 40), (198, 54), (209, 74),
    (213, 88), (223, 94), (214, 101), (219, 109), (204, 113),
    (190, 124), (168, 131), (148, 133), (128, 131), (107, 124),
    (92, 113), (77, 109), (82, 101), (73, 94), (83, 88),
    (87, 74), (98, 54), (120, 40),
]
HEAD = blob(HEAD_PTS, 10)
# soft snout bump under the nose, so the face reads as a little wedge with a muzzle, not a moon
MUZZLE = ellipse_poly(144, 117, 21, 16.5)
FACE = unary_union([HEAD, MUZZLE]).buffer(0)
FACE_D = poly_d(FACE)


def ear(side, perk=False):
    # tall triangles set wide on the crown, tips leaning out a little
    if side == "L":
        tip = (91, 15) if perk else (95, 20)
        pts = [(90, 76), tip, (134, 43)]
    else:
        tip = (206, 16) if perk else (202, 21)
        pts = [(162, 43), tip, (207, 77)]
    d, poly = rounded(pts, [3, 8, 3])
    # cream fluffy inner ear: shrink toward a point near the base middle
    cx = (pts[0][0] + pts[2][0]) / 2 * 0.6 + pts[1][0] * 0.4
    cy = (pts[0][1] + pts[2][1]) / 2 * 0.6 + pts[1][1] * 0.4 + 5
    inner = [(cx + (x - cx) * 0.55, cy + (y - cy) * 0.55) for x, y in pts]
    di, ipoly = rounded(inner, [2, 5, 2])
    # inner shade on the side away from the light
    sh = ipoly.difference(affinity.translate(ipoly, -3, 2))
    return d, poly, di, ipoly, sh


EARS_ALL = unary_union([ear(s, p)[1] for s in "LR" for p in (False, True)])

# Urajiro: cream cheeks + muzzle below a line that runs under each eye and climbs into a "V" at the
# orange nose bridge.
MASK_TOP = catmull([(40, 96), (84, 97), (106, 99), (122, 99.5), (133, 96), (139, 100), (144, 106),
                    (149, 100), (155, 95), (166, 97.5), (184, 97), (206, 95), (250, 94)], 8)
MASK = Polygon(MASK_TOP + [(250, 200), (40, 200)]).intersection(FACE.buffer(-0.01))
BROWS = [ellipse_poly(119, 69.5, 6.2, 4.4, -12), ellipse_poly(166, 67.5, 6.2, 4.4, 12)]
FACE_SHADE = FACE.difference(affinity.translate(FACE, -7, -5)).intersection(
    Polygon([(160, 30), (250, 30), (250, 160), (150, 160)]))
CHEEK_SHADE = MASK.intersection(FACE_SHADE)
FACE_SHADE = FACE_SHADE.difference(MASK)

EYE_L, EYE_R = (122.5, 87.0), (165.5, 86.0)
NOSE_D = "M136 104 Q144 100.5 152 104 Q151.5 109.5 144 112 Q136.5 109.5 136 104Z"


def head_layers(eyes="content", mouth="smile", perk=False):
    out = []
    for s in "LR":
        d, _, di, _, sh = ear(s, perk)
        out += [outlined(d, MAIN, 5), fill(di, LIGHT), fill(poly_d(sh), LIGHT_SH)]
    out += [fill(FACE_D, MAIN), fill(poly_d(FACE_SHADE), SHADE), fill(poly_d(MASK), LIGHT),
            fill(poly_d(CHEEK_SHADE), LIGHT_SH),
            fill(poly_d(unary_union(BROWS)), LIGHT), stroke(FACE_D, 5)]
    out += face(eyes, mouth)
    return out


def face(eyes, mouth):
    out = ['<ellipse cx="107" cy="106" rx="8.5" ry="4.8" fill="#F4A6A0"/>',
           '<ellipse cx="183" cy="105" rx="8.5" ry="4.8" fill="#F4A6A0"/>',
           stroke("M102.5 108 L104.5 104 M106 108.5 L108 104.5 M109.5 108 L111.5 104 "
                  "M178.5 107 L180.5 103 M182 107.5 L184 103.5 M185.5 107 L187.5 103", 1.6, HATCH)]
    (lx, ly), (rx, ry) = EYE_L, EYE_R
    if eyes == "content":
        out.append(stroke(f"M{lx - 7.5} {ly} Q{lx} {ly + 1.5} {lx + 7.5} {ly} "
                          f"M{rx - 7.5} {ry} Q{rx} {ry + 1.5} {rx + 7.5} {ry}", 4.5))
    elif eyes == "open":
        out += eye_dot(lx, ly) + eye_dot(rx, ry)
    elif eyes == "happy":
        out.append(stroke(f"M{lx - 7} {ly + 3} Q{lx} {ly - 7} {lx + 7} {ly + 3} "
                          f"M{rx - 7} {ry + 3} Q{rx} {ry - 7} {rx + 7} {ry + 3}", 4.5))
    elif eyes == "sleepy":
        out.append(stroke(f"M{lx - 7} {ly - 2} Q{lx} {ly + 6} {lx + 7} {ly - 2} "
                          f"M{rx - 7} {ry - 2} Q{rx} {ry + 6} {rx + 7} {ry - 2}", 4.5))
    elif eyes == "wake":
        out += eye_dot(lx, ly)
        out.append(stroke(f"M{rx - 7} {ry - 2} Q{rx} {ry + 6} {rx + 7} {ry - 2}", 4.5))
    # mouth
    if mouth == "grin":
        # big open grin with the tongue lolling out
        g = "M127 114.5 Q135.5 118.5 144 114 Q152.5 118.5 161 114.5 Q160 131 144 132 Q128 131 127 114.5Z"
        out.append(f'<path d="{g}" fill="{MOUTH_IN}"/>')
        out.append(f'<path d="M134 127.5 Q136 121 144 121.5 Q152 121 154 127.5 Q151 133 144 133 Q137 133 134 127.5Z" fill="{FEAT}"/>')
        out.append(stroke("M144 123.5 L144 128.5", 2.2, "#D86F78"))
        out.append(f'<path d="{g}" fill="none" stroke="{LINE}" stroke-width="3.5" stroke-linejoin="round"/>')
        out.append(stroke("M144 111.5 L144 114", 3.5))
    else:
        # smug little smile: a wide "w" whose corners curl up into the cheeks
        out.append(stroke("M144 111 L144 114.5 M131 113 Q134 119.5 140 118.5 Q143 117.5 144 114.5 "
                          "Q145 117.5 148 118.5 Q154 119.5 157 113", 3.5))
    out.append(f'<path d="{NOSE_D}" fill="{LINE}" stroke="{LINE}" stroke-width="2.5" stroke-linejoin="round"/>')
    out.append(f'<ellipse cx="140.8" cy="104.3" rx="2.4" ry="1.4" transform="rotate(-10 140.8 104.3)" fill="{WHITE}"/>')
    return out


# ---------------------------------------------------------------- body + tail
BODY_PTS = [
    (118, 120), (106, 124), (98, 132), (95, 142), (95, 151), (92, 166), (87, 184), (90, 198),
    (106, 205), (152, 210), (198, 208), (213, 201), (217, 187), (212, 166), (211, 150), (208, 134),
    (199, 124), (184, 118),
]
BODY = blob(BODY_PTS, 10)
BODY_D = poly_d(BODY)
# puffed cream chest (neck ruff) with a fluffy scalloped lower edge
BIB = blob([(118, 120), (176, 120), (186, 134), (186, 152), (180, 166), (172, 172), (166, 167),
            (158, 176), (150, 170), (142, 178), (134, 170), (126, 174), (120, 164), (112, 154),
            (110, 136)], 10).intersection(BODY)
BODY_SHADE = BODY.difference(affinity.translate(BODY, -9, -3)).intersection(
    Polygon([(160, 100), (240, 100), (240, 230), (160, 230)]))
BIB_SHADE = BIB.difference(affinity.translate(BIB, -7, -2)).intersection(Point(190, 150).buffer(40))
# fluffy shadow of the head on the ruff
CHIN_SHADOW = blob([(116, 122), (180, 122), (182, 132), (172, 138), (163, 135), (154, 141),
                    (145, 136), (136, 141), (127, 136), (117, 134)], 8).intersection(BIB)
RUFF_LINES = "M101 178 Q96 190 104 199 M205 187 Q208.5 194 201 200"
# feet and the bottom of the body stay behind the foreshortened keyboard (they still read with the
# keyboard turned off)
FEET = [(126, 207), (190, 207)]


def body_layers():
    return [fill(BODY_D, MAIN), fill(poly_d(BODY_SHADE), SHADE), fill(poly_d(BIB), LIGHT),
            fill(poly_d(BIB_SHADE), LIGHT_SH), fill(poly_d(CHIN_SHADOW), LIGHT_SH), stroke(BODY_D, 5),
            stroke(RUFF_LINES, 3.5)] + [
        f'<ellipse cx="{x}" cy="{y}" rx="14" ry="8" fill="{LIGHT}" stroke="{LINE}" stroke-width="4.5"/>'
        for x, y in FEET] + [stroke(" ".join(f"M{x - 4} {y + 2} L{x - 3.5} {y + 6} M{x + 4} {y + 2} L{x + 3.5} {y + 6}"
                                              for x, y in FEET), 2.5)]


# The iconic tight curl: a fluffy "cinnamon roll" lying on the back, over the right flank.
TAIL_PIVOT = (214, 182)
TAIL_C, TAIL_R = (214, 150), 20.5
TAIL_POSE = {
    "idle": 0, "peek": 0, "hold": 0, "sip": 0,
    "type_left": 3, "type_right": -3, "type_both": 0,
    "excited": 9, "sleep": -5, "wake": -5,
}
# the excited wag also slides the curl in a little so it stays inside the x <= 240 safe edge
TAIL_SHIFT = {"excited": (-3.5, 0)}


def tail_geom(rot, shift=(0, 0)):
    cx, cy = TAIL_C
    n = 16
    pts = []
    for k in range(n):
        a = 2 * math.pi * k / n
        r = TAIL_R + (1.6 if k % 2 == 0 else -0.5)      # soft fluffy scallops
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    disc = blob(pts, 6)
    base = tube(cubic((204, 196), (212, 186), (222, 178), (226, 164), 20), 9, 10)
    t = unary_union([disc, base])
    # spiral from the centre outward, 1.3 turns
    sp = []
    for k in range(60):
        u = k / 59
        a = math.radians(200) + u * 2 * math.pi * 1.25
        r = 2.5 + u * 13
        sp.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    spiral = LineString(sp)
    cream = Point(cx - 1, cy + 1).buffer(11).intersection(disc)
    rotf = lambda g: affinity.translate(affinity.rotate(g, rot, origin=TAIL_PIVOT), *shift)
    return rotf(t), rotf(disc), rotf(cream), rotf(spiral)


def tail(frame):
    t, disc, cream, spiral = tail_geom(TAIL_POSE[frame], TAIL_SHIFT.get(frame, (0, 0)))
    # the base hides behind the body; only the curl lies over the flank. The base stops at the outer
    # edge of the body outline, so that line stays whole and meets the curl without a notch.
    outside = t.difference(BODY.buffer(2.0)).difference(disc)
    vis = unary_union([disc, outside])
    # shade offset from a smooth round copy, so its inner edge doesn't zig-zag with the fluff scallops
    c = disc.centroid
    smooth = unary_union([Point(c.x, c.y).buffer(TAIL_R + 1.6, resolution=32), outside])
    shade = vis.difference(affinity.translate(smooth, -6, -5)).difference(cream)
    d = poly_d(vis)
    edge = unary_union([disc.boundary.difference(t.difference(BODY).difference(disc).buffer(0.6)),
                        outside.boundary.difference(BODY.buffer(2.4)).difference(disc.buffer(0.6))])
    return [fill(d, MAIN), fill(poly_d(shade), SHADE), fill(poly_d(cream), LIGHT),
            fill(poly_d(cream.difference(affinity.translate(cream, -3, -3))), LIGHT_SH),
            stroke(line_d(merge_lines(edge)), 5), stroke(line_d(spiral), 3.5)]


# ---------------------------------------------------------------- paws
KB_DY = 6
REST = {"L": (123, 168 + KB_DY), "R": (161, 179 + KB_DY)}
PAW_RX, PAW_RY = 13.5, 9.8
SHOULDER = {"L": (124, 134), "R": (180, 138)}


def paw_state(state, side):
    x, y = REST[side]
    if state == "rest":
        return (x, y), 14, PAW_RX, PAW_RY, "toes"
    if state == "pressed":
        return (x, y + 3), 14, PAW_RX * 1.06, PAW_RY * 0.85, "toes"
    if state == "raised":
        return (x + 2, y - 10), 0, PAW_RX, PAW_RY + 0.5, "beans"
    if state == "excited":
        return (x - 1 if side == "L" else x + 1, y - 13), 0, PAW_RX, PAW_RY + 0.5, "beans"
    if state == "sleep":
        return ((128, 172) if side == "L" else (160, 182)), 14, PAW_RX, PAW_RY, "toes"
    raise ValueError(state)


def arm_curve(side, paw, kind="type"):
    sx, sy = SHOULDER[side]
    px, py = paw
    if kind == "type":
        # straight, sturdy shiba front legs coming down off the puffed chest
        if side == "L":
            return cubic((sx, sy), (sx - 6, sy + 12), (px - 4, py - 12), (px, py), 24)
        return cubic((sx, sy), (sx + 3, sy + 14), (px + 7, py - 12), (px, py), 24)
    if kind == "hug":
        if side == "L":
            return cubic((122, 135), (113, 153), (124, 163), paw, 24)
        return cubic((194, 136), (197, 150), (186, 154), paw, 24)
    if kind == "sip":
        # forearms folded up from elbows tucked against the chest
        if side == "L":
            return cubic((122, 135), (112, 151), (118, 157), paw, 24)
        return cubic((194, 136), (198, 152), (176, 156), paw, 24)
    raise ValueError(kind)


KB_BACK = lambda off: Polygon([(0, 146 + KB_DY + 0.257 * -80 + off), (256, 146 + KB_DY + 0.257 * 176 + off), (256, 256), (0, 256)])


def arm(curve, head_clip, r0=14.0, r1=12.5, sock=True, below_kb=False, tail_disc=None, in_body=False, cap_only=False):
    poly = tube(curve, r0, r1)
    if in_body:
        # hugging arms stay inside the body silhouette, so the body outline doubles as their outer edge
        poly = poly.intersection(BODY.buffer(-1.0))
    sx, sy = curve[0]
    root = Point(sx, sy).buffer(r0 + 1.2)
    if cap_only:
        # folded forearm: keep the whole contour; the head, body and tail cuts below end it cleanly
        root = Polygon()
    if head_clip is not None:
        poly = poly.difference(head_clip.buffer(2.0))
    full = poly
    if tail_disc is not None:
        # the shoulder tucks behind the tail curl, so the arm contour ends on the curl's outline
        # instead of running alongside it
        poly = poly.difference(tail_disc.buffer(2.5))
    if below_kb:
        poly = poly.difference(KB_BACK(-3))
    # cream socks on the lower leg (urajiro)
    sk = poly.intersection(Point(curve[-1]).buffer(15)) if sock else Polygon()
    shade = full.difference(affinity.translate(full, -5, -2)).difference(sk).intersection(poly)
    edge = poly.boundary.difference(root)
    if below_kb:
        edge = edge.difference(KB_BACK(-4))
    if head_clip is not None:
        edge = edge.difference(head_clip.buffer(3.4))
    if tail_disc is not None:
        edge = edge.difference(tail_disc.buffer(2.6))
    if in_body:
        edge = edge.difference(BODY.exterior.buffer(2.2))
    sk_line = Point(curve[-1]).buffer(15).exterior.intersection(poly.buffer(-2.6)) if sock else None
    d = poly_d(poly)
    out = [fill(d, MAIN), fill(poly_d(shade), SHADE), fill(poly_d(sk), LIGHT)]
    if sock:
        out.append(fill(poly_d(sk.difference(affinity.translate(sk, -4, -1))), LIGHT_SH))
    # drop leftover nubs of contour (a few units long) that read as stray marks
    edge = merge_lines(edge)
    if edge.geom_type == "MultiLineString":
        edge = MultiLineString([g for g in edge.geoms if g.length >= 5])
    out.append(stroke(line_d(edge), 5))
    return out


def paw_shape(c, rot, rx, ry, deco):
    out = []
    cx, cy = c
    tr = f' transform="rotate({f(rot)} {f(cx)} {f(cy)})"' if rot else ""
    out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="{LIGHT}"/>')
    pe = ellipse_poly(cx, cy, rx, ry, rot)
    out.append(fill(poly_d(pe.difference(affinity.translate(pe, -3.5, -3.5))), LIGHT_SH))
    if deco == "beans":
        out.append(f'<ellipse cx="{f(cx + 0.5)}" cy="{f(cy + 2.4)}" rx="4.8" ry="3.7" fill="{FEAT}"/>')
        out.append(f'<path d="M{f(cx - 6.6)} {f(cy - 2.4)} a2 2.2 0 1 0 0.01 0Z'
                   f'M{f(cx - 0.4)} {f(cy - 4.8)} a2 2.2 0 1 0 0.01 0Z'
                   f'M{f(cx + 6.6)} {f(cy - 3)} a2 2.2 0 1 0 0.01 0Z" fill="{FEAT}"/>')
    out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="none" stroke="{LINE}" stroke-width="4.5"/>')
    if deco == "toes":
        a = math.radians(rot)
        pts = []
        for ox in (-4.0, 4.0):
            for (u, v) in ((ox, ry - 4.2), (ox + 0.6, ry - 0.6)):
                pts.append((cx + u * math.cos(a) - v * math.sin(a), cy + u * math.sin(a) + v * math.cos(a)))
        out.append(stroke(f"M{f(pts[0][0])} {f(pts[0][1])} L{f(pts[1][0])} {f(pts[1][1])} "
                          f"M{f(pts[2][0])} {f(pts[2][1])} L{f(pts[3][0])} {f(pts[3][1])}", 2.5))
    return out


def tail_disc(frame):
    return tail_geom(TAIL_POSE[frame], TAIL_SHIFT.get(frame, (0, 0)))[1]


def paws_layer(lstate, rstate, frame, sleeping=False):
    head = sleep_geom(FACE) if sleeping else FACE
    out = []
    states = (("L", lstate), ("R", rstate))
    for side, st in states:
        c, *_ = paw_state(st, side)
        out += arm(arm_curve(side, c), head, tail_disc=tail_disc(frame) if side == "R" else None)
    for side, st in states:
        out += paw_shape(*paw_state(st, side))
    return out


HUG_PAWS = ((136, 156), (170, 150))
SIP_PAWS = ((126, 146), (157, 140))
HOLD_T = "translate(152 146) rotate(8)"
SIP_T = (140, 138, -12)     # lid just under the nose, at the mouth; the nose and eyes stay clear


def hug_paws(kind):
    if kind == "hug":
        (pl, pr), (rl, rr), clip = HUG_PAWS, (-20, 20), FACE
    else:
        (pl, pr), (rl, rr), clip = SIP_PAWS, (-30, 15), FACE
    out = []
    out += arm(arm_curve("L", pl, kind), clip, 13.5, 11.5, sock=False, below_kb=True, in_body=True,
               cap_only=kind == "sip")
    out += arm(arm_curve("R", pr, kind), clip, 13.5, 11.5, sock=False, below_kb=True, tail_disc=tail_disc("hold"),
               in_body=True, cap_only=kind == "sip")
    for (cx, cy), rot in ((pl, rl), (pr, rr)):
        out.append(f'<ellipse cx="{cx}" cy="{cy}" rx="11.5" ry="9.5" transform="rotate({rot} {cx} {cy})" '
                   f'fill="{LIGHT}" stroke="{LINE}" stroke-width="4.5"/>')
    (lx, ly), (rx_, ry_) = pl, pr
    out.append(stroke(f"M{lx + 4} {ly - 4} L{lx + 7.5} {ly - 5} M{lx + 5} {ly + 2.5} L{lx + 8.5} {ly + 2} "
                      f"M{rx_ - 4} {ry_ - 4} L{rx_ - 7.5} {ry_ - 4.5} M{rx_ - 4.5} {ry_ + 2.5} L{rx_ - 8} {ry_ + 2.5}", 2.5))
    return out


# ---------------------------------------------------------------- frames
FRAMES = {
    "idle": ("content", "smile", False, False, ("rest", "rest")),
    "peek": ("open", "smile", False, False, None),
    "type_left": ("content", "smile", False, False, ("pressed", "raised")),
    "type_right": ("content", "smile", False, False, ("raised", "pressed")),
    "type_both": ("content", "smile", False, False, ("pressed", "pressed")),
    "excited": ("happy", "grin", True, False, ("excited", "excited")),
    "sleep": ("sleepy", "smile", False, True, ("sleep", "sleep")),
    "wake": ("wake", "smile", False, True, None),
    "hold": ("content", "smile", False, False, "hug"),
    "sip": ("happy", "smile", False, False, "sip"),
}


def build_frames():
    for name, (eyes, mouth, perk, sleeping, paws) in FRAMES.items():
        body = body_layers() + tail(name)
        head = head_layers(eyes, mouth, perk)
        if sleeping:
            body += [f'<g transform="{SLEEP_T}">'] + head + ["</g>"]
        else:
            body += head
        write(OUT / f"{name}.svg", body,
              f"typebud shiba (Kinako): {name}. Tail, body, head, ears, face; no forearms (see {name}_paws.svg).")
        if paws is None:
            continue
        pb = hug_paws(paws) if paws in ("hug", "sip") else paws_layer(*paws, name, sleeping=sleeping)
        write(OUT / f"{name}_paws.svg", pb,
              f"typebud shiba (Kinako): forearms + paws for {name}, drawn after the keyboard.")


# ---------------------------------------------------------------- head items
HP_RING = """<defs>
    <linearGradient id="hp-ring" gradientUnits="userSpaceOnUse" x1="0" y1="78" x2="0" y2="112">
      <stop offset="0" stop-color="#4FC3F7"/>
      <stop offset="0.25" stop-color="#7C6CFF"/>
      <stop offset="0.45" stop-color="#E86BD8"/>
      <stop offset="0.62" stop-color="#FF5C6C"/>
      <stop offset="0.8" stop-color="#FFE45C"/>
      <stop offset="1" stop-color="#5EE08A"/>
    </linearGradient>
  </defs>"""


def headphones_body():
    # band ends sit well outside the ear edges, so no thin sliver of band is left between ear and cup
    band = LineString(cubic((77, 86), (76, 28), (220, 22), (218, 82), 80))
    # the far (left) side of the band and its cup sit behind the head: cut them at the outer edge of
    # the head outline so only the part beyond the cheek shows
    behind = FACE.buffer(2.5).intersection(Polygon([(0, 0), (100, 0), (100, 256), (0, 256)]))
    cut = EARS_ALL.buffer(2.6).union(behind).buffer(4).buffer(-4)
    outer = band.buffer(7, cap_style="round").difference(cut)
    inner = band.buffer(3.25, cap_style="round").difference(cut.buffer(3.4))
    # drop slivers left in the corner between the ear and the cheek
    outer = outer.buffer(-2.5).buffer(2.5).intersection(outer)
    inner = inner.buffer(-1.2).buffer(1.2).intersection(inner)
    hl = LineString(cubic((104, 50), (122, 38), (150, 34), (176, 38), 40)).buffer(1.25).intersection(inner)
    far = ellipse_poly(79, 91, 11, 21.5, 6)
    far_vis = far.difference(behind)
    far_edge = far.boundary.difference(FACE.buffer(2.4))
    return [
        fill(poly_d(far_vis), HP_SH), stroke(line_d(merge_lines(far_edge)), 4.5, G_LINE),
        fill(poly_d(outer), G_LINE), fill(poly_d(inner), HP_BAND), fill(poly_d(hl), HP_CUP),
        f'<ellipse cx="206" cy="92" rx="11" ry="22" fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'<ellipse cx="216" cy="93" rx="13" ry="22" fill="{HP_CUP}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'<ellipse cx="218" cy="93" rx="6.5" ry="14" fill="{HP_GLOW}" stroke="url(#hp-ring)" stroke-width="3.5"/>',
        f'<ellipse cx="219" cy="93" rx="3" ry="8.5" fill="{HP_CUP}"/>',
    ]


BEANIE_C, BEANIE_SH, BEANIE_RIB = "#8FB9DA", "#719FC6", "#5E8DB6"   # dusty-blue knit, complements the red fur


def beanie_body():
    # knit beanie with two pointed "ear pockets": the upright ears stay up inside the knit
    cuff_lo = cubic((80, 76), (116, 57), (180, 55), (216, 76), 40)
    cuff_hi = [(x, y - 12) for x, y in cuff_lo]
    dome = ellipse_poly(HX, 74, 60, 38, res=64)
    # soft knit outline drawn as one smooth curve (walls lean in a touch, round pocket tips, a gentle
    # sag to the pompom) instead of ear-shaped pockets with straight sides
    half = [(81.5, 80), (82.5, 58), (84, 38), (86.5, 22), (91.5, 13.5), (100, 14.5), (114, 22.5), (131, 30.5)]
    outline = half + [(148.5, 34)] + [(297 - x, y) for x, y in reversed(half)]
    hat = Polygon(catmull(outline + [(219, 96), (78, 96)], 10, closed=True)).buffer(0)
    hat = unary_union([hat, dome]).intersection(Polygon(cuff_lo + [(240, 0), (56, 0)]))
    assert hat.buffer(0.3).contains(EARS_ALL.buffer(1.2).intersection(Polygon(cuff_lo + [(240, 0), (56, 0)]))), \
        "beanie must cover the ears"
    cuff = Polygon(cuff_lo + cuff_hi[::-1]).buffer(1.2).intersection(hat.buffer(0.6))
    cuff = cuff.buffer(-3.5, join_style="round").buffer(3.5, join_style="round")
    hat = unary_union([hat, cuff])
    shade = hat.difference(affinity.translate(hat, -7, -3)).difference(cuff)
    cuff_sh = cuff.difference(affinity.translate(cuff, -6, -2))
    ribs = []
    for k in range(15):
        i = int((k + 0.5) / 15 * 40)
        x, y = cuff_lo[i]
        ribs.append(LineString([(x, y - 3), (x, y - 9.5)]))
    ribs = MultiLineString(ribs).intersection(cuff.buffer(-1.5))
    # knit seams running up each pocket
    # knit rows following the dome, broken where they would cross the pocket edges
    rows = []
    for k, dy in enumerate((12, 24)):
        rows.append(LineString(cubic((86, 76 - dy), (118, 57 - dy), (178, 55 - dy), (210, 76 - dy), 30)))
    knit = MultiLineString(rows).intersection(hat.buffer(-5).difference(cuff.buffer(2)))
    hd = poly_d(hat)
    return [
        fill(hd, BEANIE_C), fill(poly_d(shade), BEANIE_SH), fill(poly_d(cuff_sh), BEANIE_SH),
        stroke(line_d(ribs), 2.2, BEANIE_RIB), stroke(line_d(knit), 2.4, BEANIE_RIB),
        stroke(poly_d(cuff), 3.5), stroke(hd, 4.5),
        f'<circle cx="148" cy="34" r="7.5" fill="{LIGHT}" stroke="{LINE}" stroke-width="4"/>',
    ]


def party_hat_body():
    d = "M128 49 Q125 46 127 42.5 L144 19 Q147 15.5 150.5 19 L167 41.5 Q169 45 165.5 47 Q147 52 128 49Z"
    cone = Polygon([(128, 49), (127, 42.5), (144, 19), (147, 16.5), (150.5, 19), (167, 41.5), (165.5, 47), (147, 51)])
    stripes = unary_union([LineString([(125, 37), (170, 28)]).buffer(2.6),
                           LineString([(123, 50), (173, 40)]).buffer(2.4)]).intersection(cone.buffer(-0.5))
    shade = cone.difference(affinity.translate(cone, -5, 0))
    return [
        fill(d, "#7FB8C8"), fill(poly_d(shade), "#5F9BAD"), fill(poly_d(stripes), CREAM), stroke(d, 4.5),
        f'<circle cx="147.5" cy="16.5" r="4.6" fill="{CREAM}" stroke="{LINE}" stroke-width="3.5"/>',
        f'<circle cx="139" cy="33" r="1.9" fill="#F7A8C4"/><circle cx="156" cy="37" r="1.9" fill="#F7A8C4"/>',
    ]


def bow_body():
    return ['<g transform="translate(176 52) rotate(16)">'
            '<path d="M-3 -1 Q-10 -12 -17 -9 Q-21 -1 -17 7 Q-10 9 -3 2Z" fill="#7FB8C8" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>'
            '<path d="M3 -1 Q10 -12 17 -9 Q21 -1 17 7 Q10 9 3 2Z" fill="#7FB8C8" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>'
            '<path d="M6 4 Q12 7 16.5 5.5 L17 7 Q10 9 3 2Z M-13 -7.5 Q-11 -3 -6 -1" fill="#5F9BAD"/>'
            '<path d="M-12 -5 Q-9 -6.5 -6.5 -3 M12 -5 Q9 -6.5 6.5 -3" fill="none" stroke="#3B2A1E" stroke-width="2.2" stroke-linecap="round"/>'
            '<ellipse cx="0" cy="0.5" rx="5" ry="5.5" fill="#7FB8C8" stroke="#3B2A1E" stroke-width="4"/>'
            '<circle cx="-1.6" cy="-1.4" r="1.3" fill="#FFFFFF"/>'
            '</g>']


def glasses_body():
    (lx, ly), (rx, ry) = EYE_L, EYE_R
    return [
        f'<circle cx="{lx}" cy="{ly}" r="13" fill="#FFFFFF" fill-opacity="0.28"/>',
        f'<circle cx="{rx}" cy="{ry}" r="13" fill="#FFFFFF" fill-opacity="0.28"/>',
        stroke(f"M{lx - 7.5} {ly - 7} Q{lx - 5} {ly - 9.5} {lx - 1.5} {ly - 10} "
               f"M{rx - 7.5} {ry - 7} Q{rx - 5} {ry - 9.5} {rx - 1.5} {ry - 10}", 2.4, WHITE),
        stroke(f"M{lx + 13} {ly - 1} Q144 {ly - 6.5} {rx - 13} {ry - 1.5} M{rx + 13} {ry - 1} L208 {ry - 6} "
               f"M{lx - 13} {ly + 0.5} L86 {ly - 2}", 4),
        f'<circle cx="{lx}" cy="{ly}" r="13" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
        f'<circle cx="{rx}" cy="{ry}" r="13" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
        f'<circle cx="{lx}" cy="{ly}" r="13" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
        f'<circle cx="{rx}" cy="{ry}" r="13" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
    ]


def build_acc():
    items = {
        "headphones": (headphones_body, HP_RING, "headphones refit to the shiba head; the band runs behind both tall ears."),
        "beanie": (beanie_body, "", "dusty-blue knit beanie with two pointed ear pockets that keep the upright ears up."),
        "party_hat": (party_hat_body, "", "party hat on the crown between the ears."),
        "bow": (bow_body, "", "ribbon bow at the base of the right ear."),
        "glasses": (glasses_body, "", "round glasses over the eyes."),
    }
    for name, (fn, defs, note) in items.items():
        b = fn()
        pre = [defs] if defs else []
        write(ACC / f"{name}.svg", pre + ["<g>"] + b + ["</g>"], f"typebud shiba: {note}")
        write(ACC / f"{name}_sleep.svg", pre + [f'<g transform="{SLEEP_T}">'] + b + ["</g>"],
              f"typebud shiba: {note} Sleep: same drawing in the sleep head transform.")


PLANT_DX, PLANT_DY = -160, -8


def build_props():
    # the curl sits where the shared plant stands: raise the plant so its leaves rise above the tail
    src = (SHARED / "desk_plant.svg").read_text()
    # the tail curl fills the shared spot on the right, so the plant moves to the back left, between
    # the lamp and the shoulder, with its pot just behind the keyboard's back-left edge
    src = src.replace('<g transform="translate(-2 0)">', f'<g transform="translate({PLANT_DX} {PLANT_DY})">', 1)
    src = src.replace("behind the animal on the right of the desk (pot base y=180)",
                      "shiba copy: moved to the back left beside the shoulder (the tail curl fills the right)")
    (ACC / "desk_plant.svg").write_text(src)
    # excited: the shared paw dashes (moved with the keyboard) + two wag marks beside the bouncing curl
    paws_d = ("M101 155 L95 151 M106 146 L102 140 M99 167 L92 167 M181 185 L188 187 M178 196 L183 201 "
              "M175 168 L180 163")
    wag_d = "M228.5 124 L233 118.5 M233.5 173 L239 176.5"
    write(ACC / "motion.svg", [
        f'<g transform="translate(1 {KB_DY})">', stroke(paws_d, 7), stroke(paws_d, 2.6, CREAM), "</g>",
        stroke(wag_d, 7), stroke(wag_d, 2.6, CREAM)],
        "typebud shiba motion marks for excited: the shared paw dashes, moved with the keyboard, plus wag "
        "marks around the curled tail. Outlined strokes (7 outline under a 2.6 cream core).")


def build_hold():
    sx, sy, sr = SIP_T
    for item in ("hold_coffee", "hold_boba", "hold_book"):
        src = (SHARED / f"{item}.svg").read_text()
        tilt = re.search(r'<g transform="translate\([^)]*\) rotate\(([^)]*)\)">', src).group(1)
        hold = re.sub(r'<g transform="translate\([^)]*\) rotate\([^)]*\)">',
                      f'<g transform="{HOLD_T.split(" rotate")[0]} rotate({tilt})">', src, count=1)
        hold = hold.replace("hug position", "shiba hug position (in front of the puffed chest)")
        (ACC / f"{item}.svg").write_text(hold)
        sip = re.sub(r'<g transform="translate\([^)]*\) rotate\([^)]*\)">',
                     f'<g transform="translate({sx} {sy}) rotate({sr})">', src, count=1)
        sip = sip.replace("hug position", "shiba sip position (raised to the muzzle)")
        (ACC / f"sip_{item[5:]}.svg").write_text(sip)


# ---------------------------------------------------------------- icons
def mirror(pts):
    return [(256 - x, y) for x, y in reversed(pts)]


def build_icons():
    """Dedicated front-facing face: tall wide-set ears, fluffy cheek tufts, cream urajiro with the
    orange "V" down to a big dark nose, eyebrow dots. Head fills x 16..240."""
    half = [(128, 64), (168, 68), (198, 88), (212, 118), (218, 146), (233, 158), (219, 168), (228, 182),
            (206, 190), (184, 212), (152, 226)]
    pts = half + [(128, 229)] + mirror(half)[1:]
    head = blob(pts, 10).union(ellipse_poly(128, 206, 40, 27))
    el, lp = rounded([(40, 142), (48, 20), (116, 74)], [6, 18, 6])
    er, rp = rounded([(140, 74), (208, 20), (216, 142)], [6, 18, 6])
    il, ilp = rounded([(62, 118), (60, 50), (102, 84)], [4, 10, 4])
    ir, irp = rounded([(154, 84), (196, 50), (194, 118)], [4, 10, 4])
    sil = unary_union([head, lp, rp])
    mtop = catmull([(0, 160), (40, 162), (70, 167), (96, 167), (110, 161), (119, 170), (128, 176),
                    (137, 170), (146, 161), (160, 167), (186, 167), (216, 162), (256, 160)], 8)
    mask = Polygon(mtop + [(256, 256), (0, 256)]).intersection(head)
    brows = unary_union([ellipse_poly(90, 101, 12, 8, -12), ellipse_poly(166, 101, 12, 8, 12)])
    ey = 137
    eyes_d = f"M68 {ey} Q85 {ey + 4} 102 {ey} M154 {ey} Q171 {ey + 4} 188 {ey}"
    nose = Polygon(catmull([(108, 180), (128, 172), (148, 180), (146, 192), (128, 200), (110, 192)], 8, True))
    mouth_d = "M96 204 Q104 220 118 216 Q126 213 128 202 Q130 213 138 216 Q152 220 160 204"
    hd = poly_d(head)
    face_sh = head.difference(affinity.translate(head, -10, -8)).difference(mask).intersection(
        Polygon([(140, 0), (256, 0), (256, 256), (140, 256)]))
    body = [outlined(el, MAIN, 16), outlined(er, MAIN, 16), fill(il, LIGHT), fill(ir, LIGHT),
            fill(hd, MAIN), fill(poly_d(face_sh), SHADE), fill(poly_d(mask), LIGHT), fill(poly_d(brows), LIGHT),
            '<ellipse cx="58" cy="186" rx="17" ry="10" fill="#F4A6A0"/>',
            '<ellipse cx="198" cy="186" rx="17" ry="10" fill="#F4A6A0"/>',
            stroke(hd, 16), stroke(eyes_d, 18), stroke(mouth_d, 11),
            fill(poly_d(nose.buffer(3)), LINE),
            '<ellipse cx="119" cy="180" rx="6" ry="3.5" transform="rotate(-10 119 180)" fill="#FFFFFF"/>']
    write(OUT / "icon.svg", body, "typebud shiba icon: front face only, outline 16, eyes 18; reads at 16 px.")
    # template: black silhouette; inner ears, eyes and the cream urajiro cut out; the nose stays as
    # a black island. Brow dots and the smile blur into the eyes and the nose at 16 px, so they are
    # left out here.
    outer = sil.buffer(8, join_style="round")
    eyes = unary_union([LineString(cubic((68, ey), (79, ey + 2.7), (91, ey + 2.7), (102, ey), 12)).buffer(9),
                        LineString(cubic((154, ey), (165, ey + 2.7), (177, ey + 2.7), (188, ey), 12)).buffer(9)])
    holes = unary_union([eyes, ilp.buffer(-2), irp.buffer(-2), mask.intersection(head.buffer(-15))])
    tmpl = outer.difference(holes).union(nose.buffer(7))
    write(OUT / "icon_template.svg", [f'<path d="{poly_d(tmpl)}" fill="#000000" fill-rule="evenodd"/>'],
          "typebud shiba icon template: black silhouette; inner ears, eyes and the cream urajiro cut out, "
          "nose left as an island (even-odd).")


ANCHORS = {
    "keyboard": {"translate": [0, KB_DY], "scale": 1.0},
    # z's clear of the dropped left ear (and the beanie); notes clear of the tall right ear
    "overlays": {"zzz": [-21, -12], "music_notes": [8, -8]},
    "paws": {"left": list(REST["L"]), "right": list(REST["R"])},
    "head": {"cx": 148, "cy": 86, "rx": 70, "ry": 48},
}

if __name__ == "__main__":
    build_frames()
    build_acc()
    build_hold()
    build_props()
    build_icons()
    (OUT / "palette.json").write_text(json.dumps(PALETTE, indent=2) + "\n")
    (OUT / "anchors.json").write_text(json.dumps(ANCHORS, indent=2) + "\n")
    print("shiba: wrote frames, paws, acc/, icons, palette.json, anchors.json")
