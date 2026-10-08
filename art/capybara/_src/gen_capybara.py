#!/usr/bin/env python3
"""Generator for typebud's capybara ("Yuzu"). Writes every layer in art/capybara/.

usage: python3 art/capybara/_src/gen_capybara.py && python3 scripts/render_art.py capybara

Pose: a long, low capybara loafing belly-down behind a slightly smaller keyboard. The big blocky
head sits on the left in a light 3/4 turn (snout toward the viewer), the barrel body stretches out
to the right along the keyboard's back edge, and two stubby front feet reach forward onto the keys.

Geometry follows art/SPEC.md (anchors in anchors.json); style follows art/STYLE.md. Shapely is only
used at build time to compute clean outlines and clipped shade shapes; the SVGs are plain paths.
"""
import json
import math
import re
from pathlib import Path

from shapely import affinity
from shapely.geometry import LineString, MultiPolygon, Point, Polygon
from shapely.ops import unary_union

OUT = Path(__file__).resolve().parent.parent
ACC = OUT / "acc"
SHARED = OUT.parent / "_shared"

# ---------------------------------------------------------------- colors
LINE = "#3B2A1E"
WHITE = "#FFFFFF"
BLUSH, HATCH = "#F4A6A0", "#E07F7A"
CREAM = "#FBE3A0"
MAIN, SHADE, LIGHT, LIGHT_SH, DARK, DARK_SH, FEAT = (
    "#B07A4A", "#8A5A33", "#E8C9A0", "#D4AE80", "#6B4A33", "#553A28", "#E88F7A")
PALETTE = {
    "fur_main": "#D09860",        # warm caramel
    "fur_shade": "#B57D47",
    "fur_dark": "#A8703F",        # the slightly darker snout, feet, ears
    "fur_dark_shade": "#8F5D33",
    "feature": "#E88F7A",         # tongue, inner ears
}
G_LINE, HP_BAND, HP_CUP, HP_SH, HP_GLOW = "#22252C", "#3B414E", "#474D5A", "#2F333D", "#9FE8FF"

# ---------------------------------------------------------------- keyboard placement (anchors.json)
KB_S, KB_T = 0.94, (6.0, 4.0)


def kbp(x, y):
    """Default keyboard coords -> this animal's keyboard placement."""
    return (30 + (x - 30) * KB_S + KB_T[0], 200 + (y - 200) * KB_S + KB_T[1])


KB_BL, KB_BR, KB_FL, KB_FR = kbp(80, 146), kbp(220, 182), kbp(30, 188), kbp(170, 224)


def back_edge_y(x):
    (x0, y0), (x1, y1) = KB_BL, KB_BR
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)


# region in front of the keyboard's back edge (for keeping hug arms off the keys)
KB_FRONT = Polygon([(0, back_edge_y(0) - 2), (256, back_edge_y(256) - 2), (256, 256), (0, 256)])

# ---------------------------------------------------------------- sleep transform
SLEEP_ROT, SLEEP_C, SLEEP_DX, SLEEP_DY = -6, (128, 96), 2, 7
SLEEP_T = f"translate({SLEEP_DX} {SLEEP_DY}) rotate({SLEEP_ROT} {SLEEP_C[0]} {SLEEP_C[1]})"


def sleep_geom(g):
    return affinity.translate(affinity.rotate(g, SLEEP_ROT, origin=SLEEP_C), SLEEP_DX, SLEEP_DY)


def sleep_pt(p):
    a = math.radians(SLEEP_ROT)
    dx, dy = p[0] - SLEEP_C[0], p[1] - SLEEP_C[1]
    return (SLEEP_C[0] + dx * math.cos(a) - dy * math.sin(a) + SLEEP_DX,
            SLEEP_C[1] + dx * math.sin(a) + dy * math.cos(a) + SLEEP_DY)


# ---------------------------------------------------------------- helpers
def f(v):
    s = f"{v:.1f}"
    s = s[:-2] if s.endswith(".0") else s
    return "0" if s == "-0" else s


def poly_d(geom, tol=0.15):
    if geom.is_empty:
        return ""
    geom = geom.simplify(tol)
    polys = geom.geoms if isinstance(geom, MultiPolygon) else [geom]
    parts = []
    for p in polys:
        if p.is_empty or p.area < 0.8 or p.geom_type != "Polygon":
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
        if ln.geom_type != "LineString" or ln.length < 1.5:
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


def write(path, body, comment):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg(body, comment))


def ellipse_poly(cx, cy, rx, ry, rot=0.0, res=48):
    e = affinity.scale(Point(0, 0).buffer(1, resolution=res), rx, ry)
    if rot:
        e = affinity.rotate(e, rot, origin=(0, 0))
    return affinity.translate(e, cx, cy)


def cubic(p0, p1, p2, p3, n=40):
    out = []
    for k in range(n + 1):
        t = k / n
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def smooth(pts, closed=True, k=1.0):
    """Catmull-Rom through pts -> (SVG cubic path data, dense point list)."""
    n = len(pts)
    segs = range(n) if closed else range(n - 1)
    d = [f"M{f(pts[0][0])} {f(pts[0][1])}"]
    dense = []
    for i in segs:
        p0 = pts[(i - 1) % n] if closed or i > 0 else pts[0]
        p1, p2 = pts[i], pts[(i + 1) % n]
        p3 = pts[(i + 2) % n] if closed or i + 2 < n else pts[-1]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6 * k, p1[1] + (p2[1] - p0[1]) / 6 * k)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6 * k, p2[1] - (p3[1] - p1[1]) / 6 * k)
        d.append(f"C{f(c1[0])} {f(c1[1])} {f(c2[0])} {f(c2[1])} {f(p2[0])} {f(p2[1])}")
        dense += cubic(p1, c1, c2, p2, 16)[:-1]
    if closed:
        d.append("Z")
    else:
        dense.append(pts[-1])
    return "".join(d), dense


def smooth_poly(pts, k=1.0):
    d, dense = smooth(pts, True, k)
    return d, Polygon(dense).buffer(0)


def tube(pts, r0, r1):
    n = len(pts)
    discs = [Point(p).buffer(r0 + (r1 - r0) * i / (n - 1), resolution=24) for i, p in enumerate(pts)]
    return unary_union([unary_union([discs[i], discs[i + 1]]).convex_hull for i in range(n - 1)])


def shade_of(poly, dx, dy, clip=None):
    s = poly.difference(affinity.translate(poly, dx, dy))
    return s.intersection(clip) if clip is not None else s


# ---------------------------------------------------------------- head
# light 3/4 turn: the snout faces the viewer on the left, the cheek and back of the head show on the right
HEAD_PTS = [(62, 40), (100, 33), (134, 35), (157, 46), (167, 72), (166, 104), (155, 130),
            (134, 148), (98, 153), (62, 150), (42, 136), (36, 110), (38, 78), (46, 54)]
HEAD_D, HEAD = smooth_poly(HEAD_PTS)
HEAD_ALL = HEAD  # silhouette used for clipping arms

# the snout: a tall, blunt, slightly darker block that is the star of the face
MUZZLE_PTS = [(40, 96), (54, 79), (80, 72), (104, 77), (119, 96), (124, 124), (112, 148), (76, 154), (46, 146), (34, 120)]
MUZZLE_D, MUZZLE_P = smooth_poly(MUZZLE_PTS)
MUZZLE = MUZZLE_P.intersection(HEAD)
MUZZLE_SHADE = shade_of(MUZZLE, -5, -5, Polygon([(96, 60), (140, 60), (140, 160), (60, 160), (60, 140)]))
HEAD_SHADE = shade_of(HEAD, -9, -7, Polygon([(150, 30), (200, 30), (200, 170), (110, 170), (120, 120)]))
CROWN_TUFT = "M106 35 Q104 27 110 23 M114 35 Q115 28 121 26"

EYE_L, EYE_R = (60, 66), (118, 63)


def ear(side):
    """Small, round, high-set ears. L = far ear (mostly behind the crown), R = near ear."""
    if side == "L":
        d, p = smooth_poly([(56, 46), (54, 33), (64, 26), (76, 30), (80, 42)])
        di = "M61 38 Q63 31 70 32"
    else:
        d, p = smooth_poly([(132, 38), (140, 25), (154, 22), (163, 32), (160, 48)])
        di = "M142 36 Q146 28 155 29"
    return d, p, di


EARS = unary_union([ear(s)[1] for s in "LR"])


def head_layers(eyes="content", mouth="smile"):
    out = []
    for s in "LR":
        d, _, di = ear(s)
        out += [outlined(d, DARK, 5), stroke(di, 3.5, DARK_SH)]
    out += [fill(HEAD_D, MAIN), fill(poly_d(HEAD_SHADE), SHADE),
            fill(poly_d(MUZZLE), DARK), fill(poly_d(MUZZLE_SHADE), DARK_SH),
            stroke(HEAD_D, 5), stroke(CROWN_TUFT, 3.5)]
    out += face(eyes, mouth)
    return out


def face(eyes, mouth):
    out = []
    # blush on the cheeks, outside the snout
    out += [f'<ellipse cx="136" cy="80" rx="8" ry="4.5" fill="{BLUSH}"/>',
            f'<ellipse cx="45" cy="81" rx="5" ry="4" fill="{BLUSH}"/>',
            stroke("M132 82 L134 78 M135.5 82.5 L137.5 78.5 M139 82 L141 78", 1.6, HATCH)]
    (lx, ly), (rx, ry) = EYE_L, EYE_R

    def content(x, y, w=7):
        return f"M{f(x - w)} {f(y)} Q{f(x)} {f(y + 1.5)} {f(x + w)} {f(y)}"

    def happy(x, y):
        return f"M{f(x - 7)} {f(y + 3)} Q{f(x)} {f(y - 7)} {f(x + 7)} {f(y + 3)}"

    def sleepy(x, y):
        return f"M{f(x - 7)} {f(y - 2)} Q{f(x)} {f(y + 5)} {f(x + 7)} {f(y - 2)}"

    def open_eye(x, y):
        return [f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="3.6" ry="4.6" fill="{LINE}"/>',
                f'<circle cx="{f(x - 1.2)}" cy="{f(y - 1.8)}" r="1.4" fill="{WHITE}"/>']

    if eyes == "content":
        out.append(stroke(content(lx, ly) + content(rx, ry), 4.5))
    elif eyes == "open":
        out += open_eye(lx, ly) + open_eye(rx, ry)
    elif eyes == "happy":
        out.append(stroke(happy(lx, ly) + happy(rx, ry), 4.5))
    elif eyes == "sleepy":
        out.append(stroke(sleepy(lx, ly) + sleepy(rx, ry), 4.5))
    elif eyes == "wake":
        out += open_eye(lx, ly)
        out.append(stroke(sleepy(rx, ry), 4.5))
    # nostrils: two soft slanted commas high on the snout
    out.append(f'<ellipse cx="67" cy="92" rx="3.4" ry="2.4" transform="rotate(-20 67 92)" fill="{LINE}"/>'
               f'<ellipse cx="91" cy="92" rx="3.4" ry="2.4" transform="rotate(20 91 92)" fill="{LINE}"/>')
    # mouth: short philtrum + a tiny capybara "w"
    if mouth == "open":
        out.append(f'<path d="M71 118 Q75 121 79 118.5 Q83 121 87 118 Q87 129 79 129 Q71 129 71 118Z" '
                   f'fill="{FEAT}" stroke="{LINE}" stroke-width="3.5" stroke-linejoin="round"/>')
        out.append(stroke("M79 106 L79 118.5", 3.5))
    else:
        out.append(stroke("M79 106 L79 116 M71 116 Q75 121 79 116 Q83 121 87 116", 3.5))
    return out


# ---------------------------------------------------------------- body
BODY_PTS = [(150, 84), (192, 94), (222, 110), (238, 138), (238, 168), (228, 192), (210, 203),
            (170, 206), (110, 206), (66, 200), (52, 176), (58, 150)]
BODY_D, BODY = smooth_poly(BODY_PTS)
BODY_SHADE = shade_of(BODY, -12, -10, Polygon([(170, 40), (256, 40), (256, 256), (60, 256), (60, 196)]))
# folded hind leg: the haunch line + a little dark foot by the keyboard corner
HAUNCH = "M208 134 C193 146 191 172 201 191"
HAUNCH_SHADE_PTS = [(208, 134), (195, 146), (192, 170), (201, 191), (210, 170), (212, 148)]
HIND_FOOT = (225, 197)
CHIN_SHADOW = affinity.translate(HEAD, 3, 9)  # the head's cast shadow on the chest and shoulder
FUR_TICKS = "M186 101 L191 96 M196 104 L201 99 M225 142 L231 139 M226 154 L232 152"


def body_layers():
    hs_d, hs = smooth_poly(HAUNCH_SHADE_PTS)
    fx, fy = HIND_FOOT
    out = [fill(BODY_D, MAIN), fill(poly_d(BODY_SHADE), SHADE),
           fill(poly_d(CHIN_SHADOW.intersection(BODY)), SHADE),
           fill(poly_d(hs.intersection(BODY)), SHADE),
           stroke(BODY_D, 5), stroke(HAUNCH, 3.5), stroke(FUR_TICKS, 3, SHADE),
           f'<ellipse cx="{fx}" cy="{fy}" rx="11" ry="7.5" transform="rotate(-8 {fx} {fy})" '
           f'fill="{DARK}" stroke="{LINE}" stroke-width="4.5"/>',
           stroke(f"M{fx - 4} {fy + 2.5} L{fx - 3.5} {fy + 6} M{fx + 3} {fy + 1.5} L{fx + 3.5} {fy + 5}", 2.5)]
    return out


# ---------------------------------------------------------------- paws
REST = {"L": (92, 172), "R": (134, 182)}
KB_TILT = math.degrees(math.atan2(KB_FR[1] - KB_FL[1], KB_FR[0] - KB_FL[0]))
SHOULDER = {"L": (82, 134), "R": (126, 140)}
PAW_RX, PAW_RY = 12.5, 8.5


def paw_state(state, side):
    x, y = REST[side]
    if state == "rest":
        return (x, y), KB_TILT, PAW_RX, PAW_RY, "toes"
    if state == "pressed":
        return (x, y + 3), KB_TILT, PAW_RX * 1.06, PAW_RY * 0.85, "toes"
    if state == "raised":
        return (x + 1, y - 10), 0, PAW_RX, PAW_RY + 0.5, "pads"
    if state == "excited":
        return (x - 6 if side == "L" else x + 6, y - 9), 0, PAW_RX, PAW_RY + 0.5, "pads"
    raise ValueError(state)


def paw_shape(c, rot, rx, ry, deco):
    out = []
    cx, cy = c
    tr = f' transform="rotate({f(rot)} {f(cx)} {f(cy)})"' if rot else ""
    out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="{DARK}"/>')
    pe = ellipse_poly(cx, cy, rx, ry, rot)
    out.append(fill(poly_d(shade_of(pe, -3.5, -3)), DARK_SH))
    if deco == "pads":
        out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy + 1.5)}" rx="5.5" ry="3.2" fill="{DARK_SH}"/>')
    out.append(f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="none" '
               f'stroke="{LINE}" stroke-width="4.5"/>')
    if deco == "toes":
        a = math.radians(rot)
        segs = []
        for ox in (-3.8, 3.8):
            pts = []
            for (u, v) in ((ox, ry - 4.0), (ox + 0.5, ry - 0.6)):
                pts.append((cx + u * math.cos(a) - v * math.sin(a), cy + u * math.sin(a) + v * math.cos(a)))
            segs.append(f"M{f(pts[0][0])} {f(pts[0][1])} L{f(pts[1][0])} {f(pts[1][1])}")
        out.append(stroke("".join(segs), 2.5))
    return out


def arm(curve, head_clip, r0=13.5, r1=12.0, below_kb=False, shaded=True):
    poly = tube(curve, r0, r1)
    root = Point(curve[0]).buffer(r0 + 1.2)
    if head_clip is not None:
        poly = poly.difference(head_clip.buffer(2.0))
    if below_kb:
        poly = poly.difference(KB_FRONT)
    shade = shade_of(poly, -5, -2).intersection(Point(curve[-1]).buffer(18))
    edge = poly.boundary.difference(root)
    if below_kb:
        edge = edge.difference(KB_FRONT.buffer(-1.0))
    if head_clip is not None:
        edge = edge.difference(head_clip.buffer(3.4))
    d = poly_d(poly)
    return [fill(d, DARK), fill(poly_d(shade), DARK_SH) if shaded else "", stroke(line_d(edge), 5)]


def type_curve(side, paw):
    sx, sy = SHOULDER[side]
    px, py = paw
    if side == "L":
        return cubic((sx, sy), (sx - 8, sy + 14), (px - 6, py - 10), (px, py), 24)
    return cubic((sx, sy), (sx + 6, sy + 14), (px + 6, py - 10), (px, py), 24)


def paws_layer(lstate, rstate, sleeping=False):
    head = sleep_geom(HEAD_ALL) if sleeping else HEAD_ALL
    out = []
    states = [("L", lstate), ("R", rstate)]
    for side, st in states:
        c, *_ = paw_state(st, side)
        out += arm(type_curve(side, c), head)
    for side, st in states:
        out += paw_shape(*paw_state(st, side))
    return out


# hug: the item rests against the chest just right of the snout
HOLD_ANCHOR = (147, 138, 6)
HUG_PAWS = ((130, 154), (166, 149))
SIP_ANCHOR = (100, 126, -22)
SIP_PAWS = ((94, 148), (120, 141))


def hug_curve(side, paw, kind):
    if kind == "hug":
        if side == "L":
            return cubic((124, 190), (125, 178), (127, 166), paw, 24)
        return cubic((172, 190), (172, 176), (169, 162), paw, 24)
    if side == "L":
        return cubic((88, 176), (89, 166), (91, 156), paw, 24)
    return cubic((128, 178), (127, 166), (123, 152), paw, 24)


def hug_paws(kind):
    pl, pr = HUG_PAWS if kind == "hug" else SIP_PAWS
    rl, rr = (-24, 22) if kind == "hug" else (-30, 18)
    clip = HEAD_ALL if kind == "hug" else None
    out = []
    for side, p in (("L", pl), ("R", pr)):
        r = (13.5, 12.5)
        out += arm(hug_curve(side, p, kind), clip, *r, below_kb=True, shaded=False)
    for (cx, cy), rot in ((pl, rl), (pr, rr)):
        out.append(f'<ellipse cx="{cx}" cy="{cy}" rx="10.5" ry="8.5" transform="rotate({rot} {cx} {cy})" '
                   f'fill="{DARK}" stroke="{LINE}" stroke-width="4.5"/>')
    (lx, ly), (rx_, ry_) = pl, pr
    out.append(stroke(f"M{lx + 3} {ly - 4} L{lx + 6.5} {ly - 5} M{lx + 4} {ly + 2.5} L{lx + 7.5} {ly + 2} "
                      f"M{rx_ - 3} {ry_ - 4} L{rx_ - 6.5} {ry_ - 4.5} M{rx_ - 3.5} {ry_ + 2.5} L{rx_ - 7} {ry_ + 2.5}",
                      2.5))
    return out


# ---------------------------------------------------------------- frames
FRAMES = {
    "idle": ("content", "smile", False, ("rest", "rest")),
    "peek": ("open", "smile", False, None),
    "type_left": ("content", "smile", False, ("pressed", "raised")),
    "type_right": ("content", "smile", False, ("raised", "pressed")),
    "type_both": ("content", "smile", False, ("pressed", "pressed")),
    "excited": ("happy", "open", False, ("excited", "excited")),
    "sleep": ("sleepy", "smile", True, ("rest", "rest")),
    "wake": ("wake", "smile", True, None),
    "hold": ("content", "smile", False, "hug"),
    "sip": ("happy", "smile", False, "sip"),
}
TAG = "typebud capybara (Yuzu)"


def build_frames():
    for name, (eyes, mouth, sleeping, paws) in FRAMES.items():
        body = body_layers()
        head = head_layers(eyes, mouth)
        if sleeping:
            body += [f'<g transform="{SLEEP_T}">'] + head + ["</g>"]
        else:
            body += head
        write(OUT / f"{name}.svg", body, f"{TAG}: {name}. Body, hind foot, head, ears, face; no forelegs (see {name}_paws.svg).")
        if paws is None:
            continue
        pb = hug_paws(paws) if paws in ("hug", "sip") else paws_layer(*paws, sleeping=sleeping)
        write(OUT / f"{name}_paws.svg", pb, f"{TAG}: forelegs + feet for {name}, drawn after the keyboard.")


# ---------------------------------------------------------------- head items
HP_RING = """<defs>
    <linearGradient id="hp-ring" gradientUnits="userSpaceOnUse" x1="0" y1="62" x2="0" y2="100">
      <stop offset="0" stop-color="#4FC3F7"/>
      <stop offset="0.25" stop-color="#7C6CFF"/>
      <stop offset="0.45" stop-color="#E86BD8"/>
      <stop offset="0.62" stop-color="#FF5C6C"/>
      <stop offset="0.8" stop-color="#FFE45C"/>
      <stop offset="1" stop-color="#5EE08A"/>
    </linearGradient>
  </defs>"""


def headphones_body():
    band = LineString(cubic((46, 62), (40, 8), (160, 0), (160, 66), 80))
    cut = EARS.buffer(2.6)
    outer = band.buffer(7, cap_style="round").difference(cut)
    inner = band.buffer(3.25, cap_style="round").difference(cut.buffer(3.4))
    hl = LineString(cubic((62, 36), (78, 22), (104, 17), (128, 19), 40)).buffer(1.25).intersection(inner)
    return [
        # far cup: a crescent peeking out past the forehead
        f'<path d="M48 54 C36 52 30 62 30 72 C30 82 35 90 44 89 C41 82 40 76 40.5 70 C41 63 43.5 58 48 54Z" '
        f'fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5" stroke-linejoin="round"/>',
        fill(poly_d(outer), G_LINE), fill(poly_d(inner), HP_BAND), fill(poly_d(hl), HP_CUP),
        f'<ellipse cx="156" cy="80" rx="11" ry="21" fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'<ellipse cx="166" cy="81" rx="13" ry="21" fill="{HP_CUP}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'<ellipse cx="168" cy="81" rx="6.5" ry="13.5" fill="{HP_GLOW}" stroke="url(#hp-ring)" stroke-width="3.5"/>',
        f'<ellipse cx="169" cy="81" rx="3" ry="8" fill="{HP_CUP}"/>',
    ]


BEANIE_C, BEANIE_SH, BEANIE_RIB = "#7FB8C8", "#5F9BAD", "#4E8798"


def beanie_body():
    cuff_lo = cubic((40, 66), (80, 48), (130, 44), (170, 60), 40)
    cuff_hi = [(x, y - 11) for x, y in cuff_lo]
    top = unary_union([HEAD.buffer(3.5), ellipse_poly(104, 40, 60, 24)])
    dome = top.intersection(Polygon(cuff_lo + [(200, 0), (20, 0)]))
    cuff = Polygon(cuff_lo + cuff_hi[::-1]).buffer(1.5).intersection(top.buffer(0.5))
    hat = unary_union([dome, cuff]).difference(EARS.buffer(1.0))
    cuff = cuff.difference(EARS.buffer(1.0))
    shade = hat.difference(affinity.translate(hat, -7, -3))
    ribs = []
    for k in range(13):
        x, y = cuff_lo[int((k + 0.5) / 13 * 40)]
        ribs.append(LineString([(x, y - 2.5), (x, y - 9)]))
    ribs = unary_union(ribs).intersection(cuff.buffer(-1.5))
    hd = poly_d(hat)
    return [fill(hd, BEANIE_C, ' fill-rule="evenodd"'), fill(poly_d(shade), BEANIE_SH),
            stroke(line_d(ribs), 2.2, BEANIE_RIB), stroke(poly_d(cuff), 3.5), stroke(hd, 4.5),
            f'<circle cx="104" cy="19" r="7" fill="{BEANIE_C}" stroke="{LINE}" stroke-width="4"/>']


def party_hat_body():
    d = "M86 39 Q83 36 85 33 L101 13 Q104 10 107 13 L121 32 Q123 35.5 119 37.5 Q102 41.5 86 39Z"
    cone = Polygon([(86, 39), (85, 33), (101, 13), (104, 11), (107, 13), (121, 32), (119, 37.5), (102, 41)])
    stripes = unary_union([LineString([(84, 27), (125, 20)]).buffer(2.4),
                           LineString([(82, 40), (128, 31)]).buffer(2.2)]).intersection(cone.buffer(-0.5))
    shade = cone.difference(affinity.translate(cone, -5, 0))
    return ['<g transform="translate(0 3)">', fill(d, "#F7A8C4"), fill(poly_d(shade), "#E68AAD"), fill(poly_d(stripes), CREAM), stroke(d, 4.5),
            f'<circle cx="104" cy="12" r="4.4" fill="{CREAM}" stroke="{LINE}" stroke-width="3.5"/>',
            f'<circle cx="96" cy="28" r="1.9" fill="#7FB8C8"/><circle cx="111" cy="30" r="1.9" fill="#7FB8C8"/>', "</g>"]


def bow_body():
    return [('<g transform="translate(130 42) rotate(-12)">'
             '<path d="M-3 -1 Q-10 -12 -17 -9 Q-21 -1 -17 7 Q-10 9 -3 2Z" fill="#F27C93" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>'
             '<path d="M3 -1 Q10 -12 17 -9 Q21 -1 17 7 Q10 9 3 2Z" fill="#F27C93" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>'
             '<path d="M6 4 Q12 7 16.5 5.5 L17 7 Q10 9 3 2Z" fill="#D95E78"/>'
             '<path d="M-12 -5 Q-9 -6.5 -6.5 -3 M12 -5 Q9 -6.5 6.5 -3" fill="none" stroke="#3B2A1E" stroke-width="2.2" stroke-linecap="round"/>'
             '<ellipse cx="0" cy="0.5" rx="5" ry="5.5" fill="#F27C93" stroke="#3B2A1E" stroke-width="4"/>'
             '<circle cx="-1.6" cy="-1.4" r="1.3" fill="#FFFFFF"/>'
             '</g>')]


def glasses_body():
    (lx, ly), (rx, ry) = EYE_L, EYE_R
    r = 12.5
    return [
        f'<circle cx="{lx}" cy="{ly}" r="{r}" fill="#FFFFFF" fill-opacity="0.28"/>',
        f'<circle cx="{rx}" cy="{ry}" r="{r}" fill="#FFFFFF" fill-opacity="0.28"/>',
        stroke(f"M{lx - 7} {ly - 6} Q{lx - 4.5} {ly - 8.5} {lx - 1} {ly - 9} "
               f"M{rx - 7} {ry - 6} Q{rx - 4.5} {ry - 8.5} {rx - 1} {ry - 9}", 2.4, WHITE),
        stroke(f"M{lx + r} {ly - 1} Q{(lx + rx) / 2} {ly - 7} {rx - r} {ry - 1} M{rx + r} {ry - 1} L159 60", 4),
        f'<circle cx="{lx}" cy="{ly}" r="{r}" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
        f'<circle cx="{rx}" cy="{ry}" r="{r}" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
        f'<circle cx="{lx}" cy="{ly}" r="{r}" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
        f'<circle cx="{rx}" cy="{ry}" r="{r}" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
    ]


def yuzu_body():
    """Bonus head item (not in the app's list yet): a yuzu balanced on the crown, onsen style."""
    return [
        f'<path d="M104 30 Q103 23 107 19" fill="none" stroke="{LINE}" stroke-width="3.5" stroke-linecap="round"/>',
        f'<circle cx="104" cy="32" r="12" fill="#F6C443" stroke="{LINE}" stroke-width="4.5"/>',
        f'<path d="M110 22 Q117 26 115 37 Q113 43 106 44 Q114 36 110 22Z" fill="#E3A82E"/>',
        f'<circle cx="104" cy="32" r="12" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
        f'<circle cx="99.5" cy="28" r="2" fill="#FFF3B8"/>',
        f'<path d="M107 20 Q113 12 121 15 Q116 22 107 20Z" fill="#7CC27A" stroke="{LINE}" stroke-width="3.5" stroke-linejoin="round"/>',
    ]


def build_acc():
    items = {
        "headphones": (headphones_body, HP_RING, "headphones fitted to the capybara head; far cup peeks past the forehead."),
        "beanie": (beanie_body, "", "knit beanie on the flat crown, tiny ears poke out."),
        "party_hat": (party_hat_body, "", "party hat on the crown between the ears."),
        "bow": (bow_body, "", "ribbon bow just in front of the near ear."),
        "glasses": (glasses_body, "", "round glasses over the high-set eyes, arm to the near side."),
        "yuzu": (yuzu_body, "", "bonus: a yuzu balanced on the head (not wired in the app yet)."),
    }
    for name, (fn, defs, note) in items.items():
        b = fn()
        pre = [defs] if defs else []
        write(ACC / f"{name}.svg", pre + ["<g>"] + b + ["</g>"], f"typebud capybara: {note}")
        write(ACC / f"{name}_sleep.svg", pre + [f'<g transform="{SLEEP_T}">'] + b + ["</g>"],
              f"typebud capybara: {note} Sleep: same drawing in the sleep head transform.")


# ---------------------------------------------------------------- held items
def build_hold():
    for item in ("hold_coffee", "hold_boba", "hold_book"):
        src = (SHARED / f"{item}.svg").read_text()
        for prefix, (x, y, r), what in (("hold_", HOLD_ANCHOR, "capybara hug position (against the chest, right of the snout)"),
                                        ("sip_", SIP_ANCHOR, "capybara sip position (raised to the mouth)")):
            out = re.sub(r'<g transform="translate\([^)]*\) rotate\([^)]*\)">',
                         f'<g transform="translate({x} {y}) rotate({r})">', src, count=1)
            out = out.replace("hug position", what)
            (ACC / f"{prefix}{item[5:]}.svg").write_text(out)


# ---------------------------------------------------------------- icons
def icon_parts():
    head_d, head = smooth_poly([(50, 56), (128, 44), (206, 56), (226, 110), (228, 180), (206, 228),
                                (128, 240), (50, 228), (28, 180), (30, 110)])
    muz_d, muz = smooth_poly([(56, 152), (88, 122), (128, 116), (168, 122), (200, 152), (212, 196),
                              (190, 236), (128, 246), (66, 236), (44, 196)])
    muz = muz.intersection(head)
    el_d, el = smooth_poly([(50, 64), (52, 42), (70, 33), (86, 40), (90, 54)])
    er_d, er = smooth_poly([(166, 54), (170, 40), (186, 33), (204, 42), (206, 64)])
    return head_d, head, muz, (el_d, el), (er_d, er)


EYES_I = ((58, 98), (86, 98), (170, 98), (198, 98))
NOSTRILS_I = ((100, 158), (156, 158))


def build_icons():
    head_d, head, muz, (el_d, el), (er_d, er) = icon_parts()
    (a, b, c, d) = EYES_I
    eyes = f"M{a[0]} {a[1]} Q72 103 {b[0]} {b[1]} M{c[0]} {c[1]} Q184 103 {d[0]} {d[1]}"
    nos = "".join(f'<ellipse cx="{x}" cy="{y}" rx="9" ry="6.5" fill="{LINE}"/>' for x, y in NOSTRILS_I)
    mouth = "M128 178 L128 200 M110 200 Q119 212 128 200 Q137 212 146 200"
    body = [outlined(el_d, DARK, 16), outlined(er_d, DARK, 16),
            fill(head_d, MAIN), fill(poly_d(muz), DARK),
            '<ellipse cx="54" cy="132" rx="14" ry="9" fill="#F4A6A0"/>',
            '<ellipse cx="202" cy="132" rx="14" ry="9" fill="#F4A6A0"/>',
            stroke(head_d, 16), stroke(eyes, 18), nos, stroke(mouth, 11)]
    write(OUT / "icon.svg", body, "typebud capybara icon: front face, tall dark snout, outline 16, eyes 18; reads at 16 px.")
    sil = unary_union([head, el, er]).buffer(8, join_style="round")
    holes = unary_union([
        LineString(cubic(a, (67, 102), (77, 102), b, 12)).buffer(9),
        LineString(cubic(c, (179, 102), (189, 102), d, 12)).buffer(9),
        *[ellipse_poly(x, y, 9, 6.5) for x, y in NOSTRILS_I],
        LineString([(128, 178), (128, 200)]).buffer(6),
        LineString(cubic((110, 200), (116, 208), (122, 208), (128, 200), 10)
                   + cubic((128, 200), (134, 208), (140, 208), (146, 200), 10)[1:]).buffer(6),
    ])
    write(OUT / "icon_template.svg", [f'<path d="{poly_d(sil.difference(holes))}" fill="#000000" fill-rule="evenodd"/>'],
          "typebud capybara icon template: pure black silhouette, eyes, nostrils and mouth cut out (even-odd).")


# ---------------------------------------------------------------- own overlay: z's rise up-right over the back
def zsh(x, y, w, h):
    rel = [(0, 0), (18, 0), (18, 4), (7, 16), (18, 16), (18, 21), (0, 21), (0, 17), (11, 5), (0, 5)]
    return "M" + " L".join(f"{f(x + u * w / 18)} {f(y + v * h / 21)}" for u, v in rel) + "Z"


def build_zzz():
    body = [f'<g fill="{CREAM}" stroke="{LINE}" stroke-width="3" stroke-linejoin="round">',
            f'<path d="{zsh(176, 34, 18, 21)}"/>', f'<path d="{zsh(200, 18, 12, 14)}"/>',
            f'<path d="{zsh(218, 10, 7, 8)}" stroke-width="2.5"/>', "</g>"]
    write(ACC / "zzz.svg", body, "typebud capybara z's: float up-right from the lowered head, over the back (top-left is the head).")


def build_motion():
    (lx, ly), (rx, ry) = paw_state("excited", "L")[0], paw_state("excited", "R")[0]
    segs = [((-14, -10), (-20, -14)), ((-8, -19), (-11, -25)), ((-17, 2), (-24, 2)),
            ((16, 2), (23, 4)), ((13, 13), (18, 18)), ((11, -12), (16, -17))]
    d = ""
    for i, ((ax, ay), (bx, by)) in enumerate(segs):
        ox, oy = (lx, ly) if i < 3 else (rx, ry)
        d += f"M{f(ox + ax)} {f(oy + ay)} L{f(ox + bx)} {f(oy + by)} "
    d = d.strip()
    write(ACC / "motion.svg", [stroke(d, 7), stroke(d, 2.6, CREAM)],
          "typebud capybara motion marks for excited: dashes radiating from the raised feet (outlined strokes).")


# ---------------------------------------------------------------- desk props moved out from behind the body
def build_desk():
    lamp = (SHARED / "desk_lamp.svg").read_text()
    a, b = lamp.index("<!-- base -->"), lamp.rindex("</svg>")
    lamp = (lamp[:a] + '<g transform="translate(256 -46) scale(-1 1)">\n  ' + lamp[a:b] + "</g>\n" + lamp[b:])
    lamp = re.sub(r"<!-- typebud shared desk lamp[^>]*-->",
                  "<!-- typebud capybara desk lamp: the shared lamp mirrored to the back right, peeking over the "
                  "capybara's back (the head fills the left). Mirroring keeps stroke widths. -->", lamp)
    (ACC / "desk_lamp.svg").write_text(lamp)
    plant = (SHARED / "desk_plant.svg").read_text()
    plant = plant.replace('<g transform="translate(-2 0)">', '<g transform="translate(-191 4)">')
    plant = re.sub(r"<!-- typebud shared desk plant[^>]*-->",
                   "<!-- typebud capybara desk plant: moved to the back left, beside the snout (the body fills the right). -->", plant)
    (ACC / "desk_plant.svg").write_text(plant)


# ---------------------------------------------------------------- anchors
def build_anchors():
    hb = HEAD.bounds
    anchors = {
        "keyboard": {"translate": list(KB_T), "scale": KB_S},
        "overlays": {"music_notes": [4, 0]},
        "paws": {"left": list(REST["L"]), "right": list(REST["R"])},
        "head": {"cx": round((hb[0] + hb[2]) / 2), "cy": round((hb[1] + hb[3]) / 2),
                 "rx": round((hb[2] - hb[0]) / 2), "ry": round((hb[3] - hb[1]) / 2)},
    }
    (OUT / "anchors.json").write_text(json.dumps(anchors, indent=2) + "\n")


if __name__ == "__main__":
    build_frames()
    build_acc()
    build_hold()
    build_icons()
    build_anchors()
    build_zzz()
    build_desk()
    build_motion()
    (OUT / "palette.json").write_text(json.dumps(PALETTE, indent=2) + "\n")
    print("capybara: wrote frames, paws, acc/, icons, anchors.json, palette.json")
