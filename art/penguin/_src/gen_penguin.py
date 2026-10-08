#!/usr/bin/env python3
"""Generator for typebud's penguin ("Pip"). Writes every layer in art/penguin/.

usage: python3 art/penguin/_src/gen_penguin.py && python3 scripts/render_art.py penguin

Geometry follows art/SPEC.md (anchors.json places the keyboard), style follows art/STYLE.md.
Pip is one soft egg: head and body share a single silhouette. For sleep the top of the egg is
warped down (head tucked into the chest) with the smooth warp `sleep_w`; everything that sits on the
head (face, tuft, head items) goes through the same warp so it follows exactly. Shapely is used only
at build time; the SVGs are plain paths.
"""
import json
import math
import re
from pathlib import Path

from shapely import affinity
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
import shapely
from shapely.ops import substring, unary_union

OUT = Path(__file__).resolve().parent.parent
ACC = OUT / "acc"
SHARED = OUT.parent / "_shared"

# ---------------------------------------------------------------- colors
LINE = "#3B2A1E"
WHITE = "#FFFFFF"
BLUSH, HATCH = "#F4A6A0", "#E07F7A"
CREAM = "#FBE3A0"
# fur placeholders (themes.json); real colors in palette.json
MAIN, SHADE, LIGHT, LIGHT_SH, DARK, DARK_SH, FEAT = (
    "#B07A4A", "#8A5A33", "#E8C9A0", "#D4AE80", "#6B4A33", "#553A28", "#E88F7A")
PALETTE = {
    "fur_main": "#4A6699",        # slate-navy back, head and flippers
    "fur_shade": "#3A5283",       # its single shade (right flank)
    "fur_light": "#FBF8F1",       # warm white face and belly
    "fur_light_shade": "#E3E3EA", # cool grey shade on the white
    "fur_dark": "#6B88BC",        # the lighter sheen on the crown and flipper edges
    "fur_dark_shade": "#E58A3C",  # shade on the orange (feet, beak)
    "feature": "#FFAE52",         # beak and feet
}
SHEEN = DARK
ORANGE_SH = DARK_SH
G_LINE, HP_BAND, HP_CUP, HP_SH, HP_GLOW = "#22252C", "#3B414E", "#474D5A", "#2F333D", "#9FE8FF"

# ---------------------------------------------------------------- keyboard placement (anchors.json)
KB_T, KB_S = (30.0, 8.0), 0.76


def kb_pt(x, y):
    return (30 + (x - 30) * KB_S + KB_T[0], 200 + (y - 200) * KB_S + KB_T[1])


def key(s, t):
    """Shared key grid K(s,t) (SPEC) mapped through this animal's keyboard transform."""
    return kb_pt(37.4 + s * 8.84 + t * 8.74, 185.9 + s * 2.27 - t * 7.34)


KB_BACK = [kb_pt(80, 146), kb_pt(220, 182)]       # back edge of the case
DESK_Y = kb_pt(30, 236)[1]


def above_kb(margin=3):
    (x0, y0), (x1, y1) = KB_BACK
    k = (y1 - y0) / (x1 - x0)
    return Polygon([(0, y0 - x0 * k - margin), (256, y0 + (256 - x0) * k - margin), (256, 0), (0, 0)])


# ---------------------------------------------------------------- helpers
def f(v):
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def poly_d(geom, tol=0.12):
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


def line_d(geom, tol=0.12):
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


def pts_d(pts, closed=False):
    d = "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts)
    return d + ("Z" if closed else "")


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


def ellipse_poly(cx, cy, rx, ry, rot=0.0, res=40):
    e = affinity.scale(Point(0, 0).buffer(1, resolution=res), rx, ry)
    if rot:
        e = affinity.rotate(e, rot, origin=(0, 0))
    return affinity.translate(e, cx, cy)


def catmull(pts, n=12, closed=False):
    if closed:
        P = [pts[-1]] + list(pts) + [pts[0], pts[1]]
    else:
        P = [pts[0]] + list(pts) + [pts[-1]]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t
                                    + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    if not closed:
        out.append(P[-2])
    return out


def cubic(p0, p1, p2, p3, n=40):
    out = []
    for k in range(n + 1):
        t = k / n
        a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def vtube(pts, rfun):
    """Union of discs along a curve with radius rfun(t), t in 0..1: a soft tapered shape."""
    n = len(pts)
    discs = [Point(p).buffer(rfun(i / (n - 1)), resolution=20) for i, p in enumerate(pts)]
    return unary_union([unary_union([discs[i], discs[i + 1]]).convex_hull for i in range(n - 1)])


# ---------------------------------------------------------------- warps
IDENT = None


def sleep_w(x, y):
    """Head tucked into the chest: the top of the egg sinks and spreads a little, nothing below y 168
    moves. Smooth, so outlines stay round."""
    t = min(max((y - 30.0) / (168.0 - 30.0), 0.0), 1.0)
    k = (1 - t) ** 1.6
    return (140 + (x - 140) * (1 + 0.08 * k) - 3 * k, y + 27 * k)


def hop_w(x, y):
    return (x, y - 7)


def W(geom, w):
    return geom if w is None else shapely.transform(geom, lambda c: [w(x, y) for x, y in c])


def Wp(p, w):
    return p if w is None else w(*p)


# ---------------------------------------------------------------- the egg
SIL_PTS = [(140, 34), (170, 38), (193, 55), (204, 82), (205, 114), (209, 148), (213, 184),
           (210, 212), (194, 228), (166, 234), (134, 234), (104, 231), (82, 220), (72, 194),
           (73, 156), (76, 118), (78, 84), (89, 55), (111, 38)]
SIL = Polygon(catmull(SIL_PTS, 10, closed=True))
HEAD = dict(cx=138, cy=86, rx=63, ry=54)

# white face mask (a soft heart, the far/left lobe smaller for the 3/4 turn) flowing into the belly
FACE = unary_union([
    Point(116, 89).buffer(22, resolution=32),
    Point(153, 87).buffer(25, resolution=32),
    ellipse_poly(135, 104, 37, 21),
    ellipse_poly(143, 184, 45, 60),
    Polygon([(112, 116), (162, 114), (170, 136), (114, 136)]),
]).buffer(5).buffer(-5).intersection(SIL.buffer(-6.5))


def body_layers(w=None, hop=False):
    ww = (lambda x, y: hop_w(*w(x, y))) if (w and hop) else (hop_w if hop else w)
    sil = W(SIL, ww)
    face = W(FACE, ww)
    # navy shade on the right flank, sheen crescent on the upper-left of the crown
    shade = sil.difference(affinity.translate(sil, -9, -3)).intersection(box(150, 0, 256, 256))
    inner = sil.buffer(-5.5)
    sheen = inner.difference(affinity.translate(inner, 6, 7)).intersection(W(box(0, 0, 150, 96), ww))
    sheen = sheen.buffer(-0.6).buffer(0.6)
    # shade on the white: right side of the belly + a soft chin shadow under the face lobes
    wsh = face.difference(affinity.translate(face, -7, -2)).intersection(box(150, 0, 256, 256))
    chin = W(Polygon(cubic((104, 126), (122, 138), (156, 140), (178, 122), 24)
                     + cubic((178, 128), (156, 146), (122, 146), (104, 132), 24)), ww).intersection(face)
    sd = poly_d(sil)
    return [fill(sd, MAIN), fill(poly_d(sheen), SHEEN), fill(poly_d(shade), SHADE),
            fill(poly_d(face), LIGHT), fill(poly_d(wsh), LIGHT_SH), stroke(sd, 5)]


# tuft: two little feathers curling up from the crown, drawn behind the egg
TUFTS = {
    "rest": [[(137, 42), (134, 30), (128, 23), (122, 22)], [(144, 42), (147, 31), (153, 25), (159, 26)]],
    "perk": [[(137, 42), (134, 28), (130, 19), (125, 15)], [(144, 42), (148, 29), (154, 21), (160, 19)]],
}


def tuft_layers(kind, w):
    shapes = [vtube(catmull(p, 8), lambda t: 4.6 - 2.4 * t) for p in TUFTS[kind]]
    g = W(unary_union(shapes), w)
    d = poly_d(g)
    return [fill(d, MAIN), stroke(d, 4.5)]


def feet_layers(hop=False):
    out = []
    dy = -7 if hop else 0
    for cx, cy, rot in ((110, 229, -8), (180, 231, 10)):
        cy += dy
        toes = unary_union([ellipse_poly(cx + ox, cy + 5, 7.4, 6.4, rot) for ox in (-11, 0, 11)] +
                           [ellipse_poly(cx, cy, 17, 8.5, rot)])
        toes = affinity.rotate(toes, rot, origin=(cx, cy)).buffer(1.2).buffer(-1.2)
        d = poly_d(toes)
        sh = toes.difference(affinity.translate(toes, -5, -3))
        a = math.radians(rot)
        lines = []
        for ox in (-5.5, 5.5):
            p0 = (cx + ox * math.cos(a) - 6 * math.sin(a), cy + ox * math.sin(a) + 6 * math.cos(a))
            p1 = (cx + ox * math.cos(a) - 10.5 * math.sin(a), cy + ox * math.sin(a) + 10.5 * math.cos(a))
            lines.append(f"M{f(p0[0])} {f(p0[1])} L{f(p1[0])} {f(p1[1])}")
        out += [fill(d, FEAT), fill(poly_d(sh), ORANGE_SH), stroke(d, 4.5), stroke(" ".join(lines), 2.5)]
    return out


# ---------------------------------------------------------------- face
EYE_L, EYE_R = (115, 90), (153, 88)
BEAK_C = (134, 101)
BLUSH_L, BLUSH_R = (104, 104), (168.5, 102)


def face_layers(eyes, mouth, w=None, hop=False):
    ww = (lambda x, y: hop_w(*w(x, y))) if (w and hop) else (hop_w if hop else w)
    P = lambda x, y: Wp((x, y), ww)
    out = []
    for (bx, by) in (BLUSH_L, BLUSH_R):
        x, y = P(bx, by)
        out.append(f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="8" ry="4.5" fill="{BLUSH}"/>')
    hatch = []
    for (bx, by) in (BLUSH_L, BLUSH_R):
        x, y = P(bx, by)
        for ox in (-4, -0.5, 3):
            hatch.append(f"M{f(x + ox)} {f(y + 2)} L{f(x + ox + 2)} {f(y - 2)}")
    out.append(stroke(" ".join(hatch), 1.6, HATCH))

    def eye_line(c, kind):
        x, y = P(*c)
        if kind == "content":
            return stroke(f"M{f(x - 7)} {f(y)} Q{f(x)} {f(y + 1.5)} {f(x + 7)} {f(y)}", 4.5)
        if kind == "happy":
            return stroke(f"M{f(x - 7)} {f(y + 3)} Q{f(x)} {f(y - 7)} {f(x + 7)} {f(y + 3)}", 4.5)
        if kind == "sleepy":
            return stroke(f"M{f(x - 7)} {f(y - 2)} Q{f(x)} {f(y + 5.5)} {f(x + 7)} {f(y - 2)}", 4.5)
        if kind == "open":
            return (f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="4.2" ry="5.4" fill="{LINE}"/>'
                    f'<circle cx="{f(x - 1.5)}" cy="{f(y - 2.1)}" r="1.6" fill="{WHITE}"/>')
        raise ValueError(kind)

    if eyes == "wake":
        out += [eye_line(EYE_L, "open"), eye_line(EYE_R, "sleepy")]
    else:
        out += [eye_line(EYE_L, eyes), eye_line(EYE_R, eyes)]

    # beak: a small rounded diamond, pointing a touch to the viewer's left
    bx, by = BEAK_C

    def beak_pts(pts):
        return [P(x, y) for x, y in pts]
    if mouth == "open":
        # upper beak lifts, lower beak drops: little "D" of an open beak with a pink tongue
        inner = Polygon(catmull(beak_pts([(bx - 8, by - 1), (bx, by - 1.5), (bx + 8, by - 1),
                                          (bx + 6, by + 9), (bx - 1, by + 12), (bx - 7, by + 8)]), 8, closed=True))
        tongue = ellipse_poly(*P(bx - 0.5, by + 7.5), 4.6, 3).intersection(inner)
        lower = Polygon(catmull(beak_pts([(bx - 7.5, by + 6.5), (bx + 6.5, by + 6.5), (bx + 4, by + 12),
                                          (bx - 1, by + 14), (bx - 5.5, by + 11)]), 8, closed=True)).intersection(inner.buffer(2.4))
        upper = Polygon(catmull(beak_pts([(bx - 10, by - 3), (bx, by - 7.5), (bx + 10, by - 3.5),
                                          (bx + 3, by + 2.5), (bx - 1, by + 3.5), (bx - 4.5, by + 2)]), 8, closed=True))
        out += [outlined(poly_d(inner), "#7A3B2E", 3.5), fill(poly_d(tongue), BLUSH),
                outlined(poly_d(lower), FEAT, 3.5), outlined(poly_d(upper), FEAT, 3.5)]
    else:
        beak = Polygon(catmull(beak_pts([(bx - 10, by - 3), (bx, by - 6.5), (bx + 10, by - 3.5),
                                         (bx + 4, by + 5), (bx - 1, by + 7.5), (bx - 5, by + 5)]), 8, closed=True))
        sh = beak.difference(affinity.translate(beak, -3, -3)).intersection(box(bx - 1, 0, 256, 256))
        split = [P(bx - 7, by - 0.5), P(bx - 0.5, by + 2.5), P(bx + 7, by - 1)]
        out += [fill(poly_d(beak), FEAT), fill(poly_d(sh), ORANGE_SH), stroke(poly_d(beak), 3.5),
                stroke(f"M{f(split[0][0])} {f(split[0][1])} Q{f(split[1][0])} {f(split[1][1] + 1)} "
                       f"{f(split[2][0])} {f(split[2][1])}", 2.4)]
        hl = P(bx - 4, by - 3.2)
        out.append(f'<ellipse cx="{f(hl[0])}" cy="{f(hl[1])}" rx="2.4" ry="1.3" fill="{WHITE}" fill-opacity="0.85"/>')
    return out


# ---------------------------------------------------------------- flippers
SHOULDER = {"L": (84, 146), "R": (200, 163)}
REST = {"L": key(1.2, 4.3), "R": key(13.2, 4.1)}


def flipper_shape(root, tip, bow, rmax=14.0, rtip=6.5):
    (sx, sy), (px, py) = root, tip
    dx, dy = px - sx, py - sy
    L = math.hypot(dx, dy)
    nx, ny = -dy / L, dx / L
    c1 = (sx + dx * 0.33 + nx * bow, sy + dy * 0.33 + ny * bow)
    c2 = (sx + dx * 0.72 + nx * bow * 0.7, sy + dy * 0.72 + ny * bow * 0.7)
    curve = cubic(root, c1, c2, tip, 26)
    rf = lambda t: (11.5 + (rmax - 11.5) * t / 0.3) if t < 0.3 else (rmax + (rtip - rmax) * ((t - 0.3) / 0.7) ** 1.25)
    return vtube(curve, rf), curve


FLIP_CUT = 12.5
FLIP_FILL = SHEEN


def taper_line(geom, w0=5.0, w1=1.6, keep=0.8):
    """A line drawn as a filled shape that thins from w0 (at its first point) to w1 and stops at
    `keep` of its length, so a flipper's root contour melts into the body instead of ending hard."""
    pts = list(geom.coords)
    ln = LineString(pts)
    n = max(6, int(ln.length * keep / 1.2))
    sub = [ln.interpolate(ln.length * keep * i / n) for i in range(n + 1)]
    return vtube([(q.x, q.y) for q in sub], lambda t: (w0 + (w1 - w0) * t) / 2)


def flipper(side, tip, bow, sleeping=False, clip_kb=False, rmax=14.0, root=None, rtip=6.5, raised=False):
    root = root or SHOULDER[side]
    if sleeping:
        root = sleep_w(*root)
    poly, curve = flipper_shape(root, tip, bow, rmax, rtip)
    sil = W(SIL, sleep_w) if sleeping else SIL
    if raised:
        # flung out past the flank: the flipper comes out from behind the body outline
        poly = poly.difference(sil.buffer(2.5))
    else:
        # hanging against the flank: the body outline is the flipper's outer contour
        poly = poly.intersection(sil.buffer(-2.5))
    if poly.geom_type != "Polygon":
        poly = max(poly.geoms, key=lambda g: g.area)
    if clip_kb:
        poly = poly.intersection(above_kb(2))
    # shade on the side away from the light
    # (it fades in along the flipper instead of stopping square at the shoulder)
    nfade = int(len(curve) * 0.5)
    fade = vtube(curve[:nfade], lambda t: 14.5 - 7.5 * t)
    shade = poly.difference(affinity.translate(poly, -5.5, -3)).difference(fade).buffer(-0.6).buffer(0.6)
    # contour: drop the stretch that lies on the body outline (already drawn), and turn the stretch
    # around the root into a contour that tapers off toward the shoulder
    on_body = (sil.buffer(2.5).exterior if raised else sil.buffer(-2.5).exterior).buffer(0.35)
    rest = poly.exterior.difference(on_body)
    if clip_kb:
        rest = rest.difference(above_kb(2).exterior.buffer(0.35))
    rest = shapely.line_merge(rest) if rest.geom_type == "MultiLineString" else rest
    lines = list(rest.geoms) if hasattr(rest, "geoms") else [rest]
    cut = Point(root).buffer(FLIP_CUT + (4 if raised else 0))
    edge, crease = [], []
    for ln in lines:
        if ln.length < 1:
            continue
        a, b = Point(ln.coords[0]), Point(ln.coords[-1])
        # the upper contour that starts at the body outline by the shoulder tapers off into it
        ends = sorted(((a, list(ln.coords)), (b, list(ln.coords)[::-1])), key=lambda e: e[0].y)[:1]
        for end, pts in ([] if raised else ends):
            if end.within(cut.buffer(0.5)):
                lsr = LineString(pts)
                inner = lsr.intersection(cut)
                pieces = list(inner.geoms) if hasattr(inner, "geoms") else [inner]
                pieces = [q for q in pieces if not q.is_empty and q.distance(end) < 0.05]
                if pieces and pieces[0].length > 1:
                    k = pieces[0].length
                    head = substring(lsr, 0, k)
                    crease.append(taper_line(LineString(list(head.coords)[::-1]), 5.0, 2.6, 1.0))
                    ln = substring(lsr, k, lsr.length)
        edge.append(ln)
    edge = unary_union(edge)
    d = poly_d(poly)
    return [fill(d, FLIP_FILL), fill(poly_d(shade), MAIN), fill(poly_d(unary_union(crease)), LINE) if crease else "",
            stroke(line_d(edge), 5)]


def flip_tip(side, state):
    x, y = REST[side]
    if state == "rest":
        return (x, y)
    if state == "pressed":
        return (x + (0.5 if side == "L" else -0.5), y + 3.5)
    if state == "raised":
        return (x + (-3 if side == "L" else 3), y - 11)
    raise ValueError(state)


def key_touch(tip, state):
    """Tiny contact squish under a pressed flipper tip."""
    if state != "pressed":
        return []
    x, y = tip
    return [stroke(f"M{f(x - 6)} {f(y + 7.5)} Q{f(x)} {f(y + 9.5)} {f(x + 6)} {f(y + 7.5)}", 2.5)]


def paws_layer(ls, rs, sleeping=False):
    out = []
    bows = {"L": -7, "R": 7}
    for side, st in (("L", ls), ("R", rs)):
        tip = flip_tip(side, st)
        if sleeping:
            tip = (tip[0] + (2 if side == "L" else -2), tip[1] + 1)
        out += flipper(side, tip, bows[side] * (1.4 if st == "raised" else 1), sleeping)
    return out


def excited_paws():
    # flippers flung out and up, flapping
    out = []
    out += flipper("L", (54, 112), 6, False, rmax=12, raised=True)
    out += flipper("R", (232, 118), -6, False, rmax=12, raised=True)
    return out


# hold: flippers curl in to hug the item at the chest; sip: raise it to the beak
HOLD_AT = (142, 140, 4)
SIP_AT = (138, 117, -16)


def hug_paws(kind):
    # paddle-shaped (wide root, small tip), roots high enough that the scoop clears the keyboard
    if kind == "hold":
        lt, rt, bl, br, rl, rr = (127, 155), (157, 153), 13, -13, (88, 138), (198, 146)
    else:
        lt, rt, bl, br, rl, rr = (122, 124), (157, 118), 10, -10, (88, 138), (196, 141)
    out = []
    out += flipper("L", lt, bl, clip_kb=True, rmax=12.5, root=rl, rtip=5.5)
    out += flipper("R", rt, br, clip_kb=True, rmax=12.5, root=rr, rtip=5.5)
    return out


# ---------------------------------------------------------------- frames
FRAMES = {
    # name: (eyes, mouth, tuft, sleeping, hop, paws)
    "idle": ("content", "closed", "rest", False, False, ("rest", "rest")),
    "peek": ("open", "closed", "rest", False, False, None),
    "type_left": ("content", "closed", "rest", False, False, ("pressed", "raised")),
    "type_right": ("content", "closed", "rest", False, False, ("raised", "pressed")),
    "type_both": ("content", "closed", "rest", False, False, ("pressed", "pressed")),
    "excited": ("happy", "open", "perk", False, False, "excited"),
    "sleep": ("sleepy", "closed", "rest", True, False, ("rest", "rest")),
    "wake": ("wake", "closed", "rest", True, False, None),
    "hold": ("content", "closed", "rest", False, False, "hold"),
    "sip": ("happy", "closed", "rest", False, False, "sip"),
}


def build_frames():
    for name, (eyes, mouth, tuft, sleeping, hop, paws) in FRAMES.items():
        w = sleep_w if sleeping else None
        tw = (lambda x, y: hop_w(x, y)) if hop else w
        body = tuft_layers(tuft, tw) + body_layers(w, hop) + feet_layers(hop) + face_layers(eyes, mouth, w, hop)
        write(OUT / f"{name}.svg", body,
              f"typebud penguin (Pip): {name}. Egg body + head, tuft, feet, face; no flippers (see {name}_paws.svg).")
        if paws is None:
            continue
        if paws == "excited":
            pb = excited_paws()
        elif paws in ("hold", "sip"):
            pb = hug_paws(paws)
        else:
            pb = paws_layer(*paws, sleeping=sleeping)
            for side, st in zip("LR", paws):
                pb += key_touch(flip_tip(side, st), st)
        write(OUT / f"{name}_paws.svg", pb, f"typebud penguin (Pip): flippers for {name}, drawn after the keyboard.")


# ---------------------------------------------------------------- head items (all built as shapes, warped for sleep)
def hp_ring_defs(y0, y1, gid="hp-ring"):
    stops = ["#4FC3F7", "#7C6CFF", "#E86BD8", "#FF5C6C", "#FFE45C", "#5EE08A"]
    offs = ["0", "0.25", "0.45", "0.62", "0.8", "1"]
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in zip(offs, stops))
    return (f'<defs><linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="0" y1="{f(y0)}" x2="0" y2="{f(y1)}">'
            f'{s}</linearGradient></defs>')


def headphones(w):
    band_c = cubic((84, 90), (78, 22), (206, 16), (203, 88), 80)
    band = W(LineString(band_c), w)
    outer = band.buffer(7, cap_style="round")
    inner = band.buffer(3.25, cap_style="round")
    hl = W(LineString(cubic((100, 50), (114, 34), (140, 28), (166, 31), 30)), w).buffer(1.25).intersection(inner.buffer(-0.3))
    far = W(Polygon(cubic((88, 72), (72, 70), (68, 86), (69, 96)) + cubic((69, 96), (70, 108), (78, 116), (90, 113))
                    + cubic((90, 113), (84, 104), (83, 84), (88, 72))), w)
    cush = W(ellipse_poly(201, 98, 11, 22), w)
    cap = W(ellipse_poly(211, 99, 13, 22), w)
    ring = W(ellipse_poly(213, 99, 6.5, 14), w)
    dot = W(ellipse_poly(214, 99, 3, 8.5), w)
    y0, y1 = ring.bounds[1], ring.bounds[3]
    return [hp_ring_defs(y0, y1), "<g>",
            outlined(poly_d(far), HP_SH, 4.5, G_LINE),
            fill(poly_d(outer), G_LINE), fill(poly_d(inner), HP_BAND), fill(poly_d(hl), HP_CUP),
            outlined(poly_d(cush), HP_SH, 4.5, G_LINE), outlined(poly_d(cap), HP_CUP, 4.5, G_LINE),
            f'<path d="{poly_d(ring)}" fill="{HP_GLOW}" stroke="url(#hp-ring)" stroke-width="3.5"/>',
            fill(poly_d(dot), HP_CUP), "</g>"]


BEANIE_C, BEANIE_SH, BEANIE_RIB = "#F2A65E", "#DB8C45", "#C77B38"
BEANIE_C, BEANIE_SH, BEANIE_RIB = "#E86F6F", "#CF5757", "#B94A4A"


def beanie(w):
    top = SIL.buffer(3.5)
    cuff_lo_c = cubic((74, 76), (110, 60), (172, 56), (208, 74), 40)
    cuff_hi_c = [(x, y - 13) for x, y in cuff_lo_c]
    dome = top.intersection(Polygon(cuff_lo_c + [(256, 0), (0, 0)]))
    cuff = Polygon(cuff_lo_c + cuff_hi_c[::-1]).buffer(2).intersection(top.buffer(1.5))
    hat = W(unary_union([dome, cuff]).buffer(0.5), w)
    cuff = W(cuff, w)
    shade = hat.difference(affinity.translate(hat, -8, -3))
    ribs = []
    for k in range(14):
        i = int((k + 0.5) / 14 * 40)
        x, y = cuff_lo_c[i]
        ribs.append(W(LineString([(x, y - 3), (x, y - 10)]), w))
    ribs = unary_union(ribs).intersection(cuff.buffer(-1.5))
    pom_c = Wp((140, 32), w)
    pom = Point(pom_c).buffer(9, resolution=24)
    pom_sh = pom.difference(affinity.translate(pom, -3, -3))
    hd = poly_d(hat)
    return ["<g>", fill(hd, BEANIE_C), fill(poly_d(shade), BEANIE_SH), stroke(line_d(ribs), 2.2, BEANIE_RIB),
            stroke(poly_d(cuff), 3.5), stroke(hd, 4.5),
            fill(poly_d(pom), "#FFF8EE"), fill(poly_d(pom_sh), "#EADCC8"), stroke(poly_d(pom), 4), "</g>"]


def party_hat(w):
    base_l, base_r, apex = (119, 48), (160, 44), (137, 17)
    cone = Polygon(catmull([base_l, (124, 30), apex, (147, 26), base_r, (139, 50)], 8, closed=True))
    cone = Polygon([base_l, apex, base_r, (139, 49.5)]).buffer(2.5).buffer(-1)
    cone = W(cone, w)
    stripes = W(unary_union([LineString([(110, 34), (170, 22)]).buffer(2.8),
                             LineString([(108, 48), (172, 36)]).buffer(2.6)]), w).intersection(cone.buffer(-0.5))
    shade = cone.difference(affinity.translate(cone, -6, 0))
    ax, ay = Wp(apex, w)
    d = poly_d(cone)
    dots = [Wp(p, w) for p in ((128, 38), (146, 34))]
    return ["<g>", fill(d, "#8DC6E8"), fill(poly_d(shade), "#6FAED6"), fill(poly_d(stripes), CREAM), stroke(d, 4.5),
            f'<circle cx="{f(ax)}" cy="{f(ay)}" r="5" fill="{CREAM}" stroke="{LINE}" stroke-width="3.5"/>',
            "".join(f'<circle cx="{f(x)}" cy="{f(y)}" r="2" fill="#F27C93"/>' for x, y in dots), "</g>"]


def bow(w):
    cx, cy = Wp((176, 50), w)
    return [f'<g transform="translate({f(cx)} {f(cy)}) rotate(22)">',
            '<path d="M-3 -1 Q-10 -12 -17 -9 Q-21 -1 -17 7 Q-10 9 -3 2Z" fill="#F27C93" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>',
            '<path d="M3 -1 Q10 -12 17 -9 Q21 -1 17 7 Q10 9 3 2Z" fill="#F27C93" stroke="#3B2A1E" stroke-width="4.5" stroke-linejoin="round"/>',
            '<path d="M6 4 Q12 7 16.5 5.5 L17 7 Q10 9 3 2Z M-13 -7.5 Q-11 -3 -6 -1" fill="#D95E78"/>',
            '<path d="M-12 -5 Q-9 -6.5 -6.5 -3 M12 -5 Q9 -6.5 6.5 -3" fill="none" stroke="#3B2A1E" stroke-width="2.2" stroke-linecap="round"/>',
            '<ellipse cx="0" cy="0.5" rx="5" ry="5.5" fill="#F27C93" stroke="#3B2A1E" stroke-width="4"/>',
            '<circle cx="-1.6" cy="-1.4" r="1.3" fill="#FFFFFF"/>', "</g>"]


def glasses(w):
    (lx, ly), (rx, ry) = Wp(EYE_L, w), Wp(EYE_R, w)
    r = 13
    bridge = W(LineString(cubic((128, 88), (132, 83), (136, 82), (140, 86), 10)), w)
    # temple arm runs back to the head outline and stops on it (round cap tucked into the line)
    arm = W(LineString([(166, 87), (202, 82)]).intersection(SIL.buffer(-2.5)), w)
    farm = W(LineString([(102, 90), (86, 89)]), w)
    return ["<g>",
            f'<circle cx="{f(lx)}" cy="{f(ly)}" r="{r - 1}" fill="#FFFFFF" fill-opacity="0.3"/>',
            f'<circle cx="{f(rx)}" cy="{f(ry)}" r="{r}" fill="#FFFFFF" fill-opacity="0.3"/>',
            stroke(f"M{f(lx - 7)} {f(ly - 6)} Q{f(lx - 5)} {f(ly - 8.5)} {f(lx - 1.5)} {f(ly - 9)} "
                   f"M{f(rx - 7.5)} {f(ry - 7)} Q{f(rx - 5.5)} {f(ry - 9.5)} {f(rx - 2)} {f(ry - 10)}", 2.4, WHITE),
            stroke(line_d(unary_union([bridge, arm, farm])), 4),
            f'<circle cx="{f(lx)}" cy="{f(ly)}" r="{r - 1}" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
            f'<circle cx="{f(rx)}" cy="{f(ry)}" r="{r}" fill="none" stroke="{LINE}" stroke-width="4.5"/>',
            f'<circle cx="{f(lx)}" cy="{f(ly)}" r="{r - 1}" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
            f'<circle cx="{f(rx)}" cy="{f(ry)}" r="{r}" fill="none" stroke="#C98A4B" stroke-width="1.8"/>',
            "</g>"]


def build_acc():
    items = {
        "headphones": (headphones, "headphones on the round earless head: band over the crown (tuft pokes up behind it), cups where ears would be."),
        "beanie": (beanie, "red knit beanie pulled over the crown, cream pompom."),
        "party_hat": (party_hat, "little blue party hat perched on the crown."),
        "bow": (bow, "pink bow on the crown, right of the tuft."),
        "glasses": (glasses, "round glasses over the eyes on the white face."),
    }
    for name, (fn, note) in items.items():
        write(ACC / f"{name}.svg", fn(None), f"typebud penguin: {note}")
        write(ACC / f"{name}_sleep.svg", fn(sleep_w),
              f"typebud penguin: {note} Sleep: same item run through the head-tuck warp.")


# ---------------------------------------------------------------- held items (hold + sip positions)
def build_hold():
    for item in ("coffee", "boba", "book"):
        src = (SHARED / f"hold_{item}.svg").read_text()
        for name, (x, y, r) in (("hold", HOLD_AT), ("sip", SIP_AT)):
            rr = r + (-14 if item == "book" else 0)
            if item == "book" and name == "sip":
                x, y, rr = 139, 137, -10   # reading: held up at the chest, below the eyes
            out = re.sub(r'<g transform="translate\([^)]*\) rotate\([^)]*\)">',
                         f'<g transform="translate({x} {y}) rotate({rr})">', src, count=1)
            out = out.replace("hug position", f"penguin {name} position")
            (ACC / f"{name}_{item}.svg").write_text(out)


# ---------------------------------------------------------------- overlays
def build_motion():
    # dashes radiating from the flapping flipper tips
    d = ("M40 100 L33 95 M38 114 L30 114 M44 126 L38 131 "
         "M236 102 L241 96 M237 116 L243.5 117 M234 132 L238 138")
    write(ACC / "motion.svg", [stroke(d, 7), stroke(d, 2.6, CREAM)],
          "typebud penguin motion marks: dashes around the flapping flipper tips (excited).")


# ---------------------------------------------------------------- desk props (moved clear of the egg)
DESK_MOVES = {"desk_lamp": (-12, 10), "desk_plant": (6, 22), "desk_mug": (3, 0)}


def build_desk():
    for name, (dx, dy) in DESK_MOVES.items():
        src = (SHARED / f"{name}.svg").read_text()
        start = src.index(">", src.index("<svg")) + 1
        end = src.rindex("</svg>")
        out = (src[:start] + f'\n  <!-- penguin copy: shared prop moved by ({dx} {dy}) so it peeks out beside the tall egg -->'
               + f'\n  <g transform="translate({dx} {dy})">' + src[start:end] + "</g>\n" + src[end:])
        (ACC / f"{name}.svg").write_text(out)


# ---------------------------------------------------------------- icons
def icon_shapes():
    head = ellipse_poly(128, 146, 106, 90, res=64)
    tuft = unary_union([vtube(catmull([(120, 60), (113, 40), (102, 29), (90, 28)], 8), lambda t: 11 - 4.5 * t),
                        vtube(catmull([(136, 60), (142, 40), (153, 31), (165, 32)], 8), lambda t: 11 - 4.5 * t)])
    face = unary_union([Point(92, 140).buffer(44, resolution=32), Point(164, 140).buffer(44, resolution=32),
                        ellipse_poly(128, 176, 74, 50)]).buffer(6).buffer(-6).intersection(head.buffer(-20))
    beak = Polygon(catmull([(104, 166), (128, 154), (152, 166), (140, 184), (128, 190), (116, 184)], 8, closed=True))
    return head, tuft, face, beak


def build_icons():
    head, tuft, face, beak = icon_shapes()
    hd = poly_d(head)
    td = poly_d(tuft)
    sheen = head.buffer(-14).difference(affinity.translate(head.buffer(-14), 12, 14)).intersection(box(0, 0, 128, 130))
    body = [fill(td, MAIN), stroke(td, 14), fill(hd, MAIN), fill(poly_d(sheen.buffer(-1).buffer(1)), SHEEN),
            fill(poly_d(face), LIGHT),
            '<ellipse cx="62" cy="182" rx="17" ry="11" fill="#F4A6A0"/>',
            '<ellipse cx="194" cy="182" rx="17" ry="11" fill="#F4A6A0"/>',
            stroke(hd, 16),
            stroke("M68 146 Q82 150 96 146 M160 146 Q174 150 188 146", 18),
            outlined(poly_d(beak), FEAT, 12)]
    write(OUT / "icon.svg", body, "typebud penguin icon: front face only, outline 16, eyes 18; reads at 16 px.")
    sil = unary_union([head, tuft.buffer(-1)]).buffer(8, join_style="round").union(tuft.buffer(7))
    holes = unary_union([
        # eye slots sized and placed on the 16 px grid (cols 4-5 / 10-11, row 9) so they stay crisp
        LineString([(72, 152), (88, 152)]).buffer(8),
        LineString([(168, 152), (184, 152)]).buffer(8),
        beak.buffer(4.5),
    ])
    write(OUT / "icon_template.svg", [f'<path d="{poly_d(sil.difference(holes))}" fill="#000000" fill-rule="evenodd"/>'],
          "typebud penguin icon template: pure black silhouette, eyes and beak cut out (even-odd).")


# ---------------------------------------------------------------- anchors
def build_anchors():
    rl, rr = REST["L"], REST["R"]
    anchors = {
        "keyboard": {"translate": list(KB_T), "scale": KB_S},
        "overlays": {"music_notes": [0, 0], "zzz": [2, 6]},
        "paws": {"left": [round(rl[0], 1), round(rl[1], 1)], "right": [round(rr[0], 1), round(rr[1], 1)]},
        "head": HEAD,
    }
    lines = ",\n".join(f'  "{k}": {json.dumps(v, separators=(", ", ": "))}' for k, v in anchors.items())
    (OUT / "anchors.json").write_text("{\n" + lines + "\n}\n")


if __name__ == "__main__":
    build_frames()
    build_acc()
    build_hold()
    build_motion()
    build_desk()
    build_icons()
    build_anchors()
    (OUT / "palette.json").write_text(json.dumps(PALETTE, indent=2) + "\n")
    print("penguin: wrote frames, paws, acc/, icons, anchors.json, palette.json")
