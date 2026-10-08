#!/usr/bin/env python3
"""Generate every shiba layer (art/shiba/*.svg, acc/*.svg) from one set of shapes.

usage: python3 art/shiba/_src/gen_shiba.py      (needs: pip install shapely)

Outlines are written as the hand-placed bezier paths below. Patches that must stay inside a shape
(the cream "urajiro" mask, chest patch, shade crescents, the ear tops that head items redraw over
their bands) are computed with shapely and written as dense polygons; they always sit under an
outline, so their edges on the contour never show.
"""
import math
import re
from pathlib import Path

from shapely import affinity
from shapely.geometry import LineString, MultiLineString, MultiPolygon, Point, Polygon
from shapely.ops import unary_union

OUT = Path(__file__).resolve().parent.parent
(OUT / "acc").mkdir(exist_ok=True)

# ---- colors -------------------------------------------------------------------------------------
FM, FS = "#B07A4A", "#8A5A33"          # fur_main / fur_shade        (red-orange coat)
FL, FLS = "#E8C9A0", "#D4AE80"         # fur_light / fur_light_shade (cream urajiro)
FEAT = "#E88F7A"                       # feature                     (tongue)
OL, BLUSH, HATCH, WHITE, CREAM = "#3B2A1E", "#F4A6A0", "#E07F7A", "#FFFFFF", "#FBE3A0"
G_LINE, HP_BAND, HP_CUP, HP_SHADE, HP_GLOW = "#22252C", "#3B414E", "#474D5A", "#2F333D", "#9FE8FF"

SLEEP_T = "translate(-4 12) rotate(-6 152 80)"
RAINBOW = ["#4FC3F7", "#7C6CFF", "#E86BD8", "#FF5C6C", "#FFE45C", "#5EE08A"]


# ---- geometry helpers ---------------------------------------------------------------------------
TOK = re.compile(r"[MLCQZ]|-?\d*\.?\d+")


def parse(d, n=28):
    """Absolute M/L/C/Q/Z path -> list of rings (lists of points)."""
    toks = TOK.findall(d)
    rings, cur, i, cmd, pos = [], [], 0, None, (0, 0)
    num = lambda k: float(toks[k])
    while i < len(toks):
        t = toks[i]
        if t in "MLCQZ":
            cmd = t
            i += 1
            if t == "Z":
                if cur:
                    rings.append(cur)
                cur = []
            continue
        if cmd == "M":
            if cur:
                rings.append(cur)
            pos = (num(i), num(i + 1)); cur = [pos]; i += 2; cmd = "L"
        elif cmd == "L":
            pos = (num(i), num(i + 1)); cur.append(pos); i += 2
        elif cmd == "C":
            p0, p1, p2, p3 = pos, (num(i), num(i + 1)), (num(i + 2), num(i + 3)), (num(i + 4), num(i + 5))
            for k in range(1, n + 1):
                s = k / n; u = 1 - s
                cur.append((u**3 * p0[0] + 3 * u * u * s * p1[0] + 3 * u * s * s * p2[0] + s**3 * p3[0],
                            u**3 * p0[1] + 3 * u * u * s * p1[1] + 3 * u * s * s * p2[1] + s**3 * p3[1]))
            pos = p3; i += 6
        elif cmd == "Q":
            p0, p1, p2 = pos, (num(i), num(i + 1)), (num(i + 2), num(i + 3))
            for k in range(1, n + 1):
                s = k / n; u = 1 - s
                cur.append((u * u * p0[0] + 2 * u * s * p1[0] + s * s * p2[0],
                            u * u * p0[1] + 2 * u * s * p1[1] + s * s * p2[1]))
            pos = p2; i += 4
    if cur:
        rings.append(cur)
    return rings


def poly(d):
    return unary_union([Polygon(r).buffer(0) for r in parse(d) if len(r) > 2])


def ell(cx, cy, rx, ry, rot=0):
    e = affinity.scale(Point(0, 0).buffer(1, 64), rx, ry)
    e = affinity.rotate(e, rot, origin=(0, 0))
    return affinity.translate(e, cx, cy)


def f(v):
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def geom_d(g, tol=0.12):
    """Polygon / MultiPolygon -> path data (holes included, for even-odd or nonzero fills)."""
    if g.is_empty:
        return ""
    g = g.simplify(tol)
    polys = g.geoms if isinstance(g, MultiPolygon) else [g] if isinstance(g, Polygon) else \
        [p for p in getattr(g, "geoms", []) if isinstance(p, Polygon)]
    out = []
    for p in polys:
        if p.area < 0.8:
            continue
        for ring in [p.exterior] + list(p.interiors):
            c = list(ring.coords)[:-1]
            out.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in c) + "Z")
    return "".join(out)


def lines_d(g, tol=0.1):
    if g.is_empty:
        return ""
    g = g.simplify(tol)
    ls = g.geoms if isinstance(g, MultiLineString) else [g] if isinstance(g, LineString) else \
        [x for x in getattr(g, "geoms", []) if isinstance(x, LineString)]
    out = []
    for l in ls:
        if l.length < 0.5:
            continue
        out.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in l.coords))
    return "".join(out)


def crescent(g, dx, dy):
    """Shade crescent: the part of g not covered by g shifted toward the light."""
    return g.difference(affinity.translate(g, dx, dy))


def P(d, fill="none", stroke=None, w=None, extra=""):
    s = f'<path d="{d}" fill="{fill}"'
    if stroke:
        s += f' stroke="{stroke}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"'
    return s + extra + "/>"


def E(cx, cy, rx, ry, fill, stroke=None, w=None, rot=0):
    s = f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"'
    if rot:
        s += f' transform="rotate({f(rot)} {f(cx)} {f(cy)})"'
    s += f' fill="{fill}"'
    if stroke:
        s += f' stroke="{stroke}" stroke-width="{w}"'
    return s + "/>"


def svg(name, body, comment):
    text = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">\n'
            f"  <!-- typebud shiba: {comment} Generated by art/shiba/_src/gen_shiba.py. -->\n"
            + "\n".join("  " + b for b in body if b) + "\n</svg>\n")
    (OUT / name).write_text(text)
    n = len(re.findall(r"<(path|ellipse|circle|rect|line|polygon|polyline|stop|g)\b", text))
    if n > 150:
        print(f"WARNING {name}: {n} elements")


# ---- the shiba ----------------------------------------------------------------------------------
HEAD_D = ("M152 37 C186 37 210 55 212 81 C214 104 199 122 173 127 C160 129.5 146 130 134 128.5 "
          "C116 126 104 119 99 110 Q92 108 90 102 Q94 101 96 98 C94 92 93.5 86 94.5 80 "
          "C97 55 119 37 152 37 Z")
ICON_HEAD_D = ("M152 37 C186 37 210 55 212 81 C214 104 199 122 173 127 C160 129.5 146 130 134 128.5 "
               "C114 126 98 116 95.5 100 C94 92 93.5 86 94.5 80 C97 55 119 37 152 37 Z")
EAR_L_D = "M101 66 C99 50 101 38 106 30.5 Q108.5 27.5 112 29.5 C123 35 133 43 140 52 Z"
EAR_R_D = "M166 46 C175 39 186 33 197 29 Q201 28 202 31.5 C206 42 208 55 205 68 Z"
EAR_L_IN = "M108 58 C107 49 108 42 111 37 C119 41 126 46 131 52 Z"
EAR_R_IN = "M176 46 C183 41 189 38 195 36 C198 44 199 52 198 60 Z"
MASK_D = ("M86 74 C96 82 106 94 120 95 C131 96 136 90 142 90 C149 90 152 96 162 95 "
          "C174 94 184 87 194 86 C203 85 210 90 216 95 L216 140 L86 140 Z")
BODY_D = "M110 110 C93 134 90 176 100 203 L208 207 C218 180 221 138 198 108 Z"
CHEST_D = "M142 112 C136 136 130 170 134 206 L167 206 C171 176 172 140 168 112 Z"
TAIL_D = ("M112 146 C102 152 84 150 77 138 C70 126 76 110 90 106 C96 104 101 104 105 106 "
          "Q103 101 107 98 Q109 103 112 106 C118 112 118 124 112 130 Z")
TAIL_IN_D = "M60 132 C70 146 92 152 112 146 L112 160 L60 160 Z"
TAIL_CURL = "M97 125 C101 127 105 123 103 119 C101 114 93 114 90 120 C87 127 92 135 102 135"

HEAD, EAR_L, EAR_R = poly(HEAD_D), poly(EAR_L_D), poly(EAR_R_D)
EARS = unary_union([EAR_L, EAR_R])
EAR_IN = unary_union([poly(EAR_L_IN), poly(EAR_R_IN)])
MASK = poly(MASK_D).intersection(HEAD)
BODY, CHEST = poly(BODY_D), poly(CHEST_D).intersection(poly(BODY_D))
TAIL, TAIL_IN = poly(TAIL_D), poly(TAIL_D).intersection(poly(TAIL_IN_D))

# eyes / mouths (STYLE "Faces"); eye centers (122,84) and (165,82)
EYES = {
    "content": P("M115 84 Q122.5 85.5 130 84 M158 82 Q165.5 83.5 173 82", stroke=OL, w=4.5),
    "happy": P("M115 87 Q122 78 129 87 M158 85 Q165 76 172 85", stroke=OL, w=4.5),
    "sleepy": P("M115 81 Q122 88 129 81 M158 79 Q165 86 172 79", stroke=OL, w=4.5),
}


def open_eye(cx, cy):
    return [E(cx, cy, 4.3, 5.4, OL), f'<circle cx="{f(cx - 1.4)}" cy="{f(cy - 2.1)}" r="1.7" fill="{WHITE}"/>']


EYES["open"] = open_eye(122, 84) + open_eye(165, 82)
EYES["wake"] = open_eye(122, 84) + [P("M158 79 Q165 86 172 79", stroke=OL, w=4.5)]

NOSE = P("M137 89.5 Q142 87.8 147 89.5 Q146.3 94.5 142 95.2 Q137.7 94.5 137 89.5 Z", OL, OL, 2.5)
MOUTHS = {
    "smug": P("M142 95.5 L142 98.5 M135.5 97.5 Q138.8 102 142 98.5 Q146 102.5 150.5 96.5", stroke=OL, w=3.5),
    "open": [P("M134.5 97.5 Q142 100.5 151 96.5 Q150.5 108.5 142.5 109 Q135.5 108.5 134.5 97.5 Z", OL, OL, 3.5),
             P("M137.5 105 Q138.5 101.5 142.5 101.8 Q146.5 101.5 147.8 104.5 Q147 108 142.5 108 Q138.5 108 137.5 105 Z", FEAT),
             P("M142.5 102.5 L142.5 105.5", stroke="#C96D5C", w=1.8)],
    "calm": P("M142 95.5 L142 98 M137 97.8 Q139.5 100.5 142 98 Q144.5 100.5 147 97.8", stroke=OL, w=3.5),
    "sip": P("M142 95.5 L142 98 M137.5 98.5 Q142 100.5 146.5 98.5", stroke=OL, w=3.5),
}
BLUSH_EL = [E(110, 100, 8, 4.5, BLUSH), E(178, 97, 8, 4.5, BLUSH),
            P("M106 102 L108 98 M109.5 102.5 L111.5 98.5 M113 102 L115 98 "
              "M174 99 L176 95 M177.5 99.5 L179.5 95.5 M181 99 L183 95", stroke=HATCH, w=1.6)]
BROWS = [E(119, 70.5, 5.2, 3.3, FL, rot=-12), E(162.5, 68.5, 5.2, 3.3, FL, rot=10)]


def ear_parts():
    """Ears (behind the head): fill, shade, inner cream, outline."""
    shade = EAR_R.difference(affinity.translate(EAR_R, -6, 3)).union(crescent(EAR_L, -4, 2))
    return [P(EAR_L_D + EAR_R_D, FM), P(geom_d(shade.intersection(EARS)), FS),
            P(geom_d(EAR_IN), FL),
            P(EAR_L_D + EAR_R_D, stroke=OL, w=5)]


def head_parts(eyes, mouth):
    shade = crescent(HEAD, -9, -7)
    out = ear_parts()
    out += [P(HEAD_D, FM), P(geom_d(MASK), FL),
            P(geom_d(shade.difference(MASK)), FS), P(geom_d(shade.intersection(MASK)), FLS)]
    out += BROWS
    out += [P(HEAD_D, stroke=OL, w=5)]
    out += BLUSH_EL
    out += EYES[eyes] if isinstance(EYES[eyes], list) else [EYES[eyes]]
    m = MOUTHS[mouth]
    out += m if isinstance(m, list) else [m]
    out += [NOSE]
    return out


def body_parts():
    flank = crescent(BODY, -14, 0)
    chin = affinity.translate(HEAD, 3, 7).difference(HEAD).intersection(BODY)
    shade = flank.union(chin).intersection(BODY)
    tail_shade = TAIL.difference(affinity.translate(TAIL, -3, -6))
    return [
        # curled tail over the back, peeking out on the left
        P(TAIL_D, FM), P(geom_d(TAIL_IN), FL), P(geom_d(tail_shade.difference(TAIL_IN)), FS),
        P(TAIL_D, stroke=OL, w=5), P(TAIL_CURL, stroke=OL, w=3.5),
        # body bean with cream chest
        P(BODY_D, FM), P(geom_d(CHEST), FL),
        P(geom_d(shade.difference(CHEST)), FS), P(geom_d(shade.intersection(CHEST)), FLS),
        P(BODY_D, stroke=OL, w=5),
    ]


def frame(name, eyes, mouth, sleep=False, comment=""):
    head = head_parts(eyes, mouth)
    body = body_parts()
    if sleep:
        head = [f'<g transform="{SLEEP_T}">'] + ["  " + h for h in head] + ["</g>"]
    svg(f"{name}.svg", body + head, comment)


# ---- forearms + paws ----------------------------------------------------------------------------
def arm(S, C, Pt, w0=28, w1=22, bulge=4.5):
    """Chubby curled forearm: a tube along the quadratic centerline S -> C -> Pt that swells in the
    middle. S sits up under the head; paws_layer trims it to the chin."""
    n = 40
    a, b = [], []
    for k in range(n + 1):
        t = k / n; u = 1 - t
        x = u * u * S[0] + 2 * u * t * C[0] + t * t * Pt[0]
        y = u * u * S[1] + 2 * u * t * C[1] + t * t * Pt[1]
        dx = 2 * u * (C[0] - S[0]) + 2 * t * (Pt[0] - C[0])
        dy = 2 * u * (C[1] - S[1]) + 2 * t * (Pt[1] - C[1])
        L = math.hypot(dx, dy)
        w = (w0 + (w1 - w0) * t) / 2 + bulge * math.sin(math.pi * t) ** 1.5
        a.append((x - dy / L * w, y + dx / L * w)); b.append((x + dy / L * w, y - dx / L * w))
    return Polygon(a + b[::-1]).buffer(0)


def paw(cx, cy, rx, ry, rot):
    sh = ell(cx, cy, rx, ry, rot)
    shade = crescent(sh, -4, -4).intersection(sh)
    r = math.radians(rot)
    toes = []
    for ox in (-4.5, 3.5):
        x0 = cx + ox * math.cos(r) - (ry - 3.5) * math.sin(r)
        y0 = cy + ox * math.sin(r) + (ry - 3.5) * math.cos(r)
        toes.append(f"M{f(x0)} {f(y0)} L{f(x0 + 0.8)} {f(y0 + 3.4)}")
    return [E(cx, cy, rx, ry, FL, rot=rot), P(geom_d(shade), FLS),
            E(cx, cy, rx, ry, "none", OL, 4.5, rot=rot), P("".join(toes), stroke=OL, w=2.5)]


REST = {"L": (122, 168), "R": (160, 180)}
SHOULDER = {"L": (124, 112), "R": (182, 112)}
HEAD_SLEEP = affinity.translate(affinity.rotate(HEAD, -6, origin=(152, 80)), -4, 12)


def paw_pose(side, state):
    rx, ry, rot = 13.5, 9.5, 14
    x, y = REST[side]
    if state == "pressed":
        y += 3; ry *= 0.85; rx += 0.8
    elif state == "raised":
        x += 2; y -= 10; rot = 0
    elif state == "excited":
        y -= 12; rot = 4
    return x, y, rx, ry, rot


def arm_for(side, x, y):
    S = SHOULDER[side]
    mx, my = (S[0] + x) / 2, (S[1] + y) / 2
    L = math.hypot(x - S[0], y - S[1])
    nx, ny = (y - S[1]) / L, -(x - S[0]) / L        # perpendicular, pointing to the viewer's right
    k = -0.26 * L if side == "L" else 0.12 * L      # elbow bulges outward: left arm left, right arm right
    return arm(S, (mx + nx * k, my + ny * k), (x, y))


def paws_layer(name, specs, comment, head=HEAD):
    """specs: list of (arm polygon, shoulder point, paw (x, y, rx, ry, rot)). The arm is cut off at the chin so the
    head outline stays on top; its outline is the remaining contour (round caps tuck into the chin
    line, the wrist end hides under the paw)."""
    out = []
    for shape, S, pw in specs:
        cut = head.buffer(2.5).intersection(Point(S).buffer(34))
        shape = shape.difference(cut)
        sh = crescent(shape, -7, -2).intersection(shape)
        edge = shape.exterior.difference(cut.buffer(0.4)).difference(ell(*pw).buffer(-2.5))
        out += [P(geom_d(shape), FM), P(geom_d(sh), FS), P(lines_d(edge), stroke=OL, w=5)]
    for _, _, pw in specs:
        out += paw(*pw)
    svg(name, out, comment)


def typing_paws(name, ls, rs, comment, head=HEAD):
    specs = []
    for side, st in (("L", ls), ("R", rs)):
        x, y, rx, ry, rot = paw_pose(side, st)
        specs.append((arm_for(side, x, y), SHOULDER[side], (x, y, rx, ry, rot)))
    paws_layer(name, specs, comment, head)


# ---- held items ---------------------------------------------------------------------------------
# The shared hold_* drawings fit as they are: hug at translate(164 140), sip at translate(146 114)
# rotate(-25) (rim/straw on the mouth at ~(144,100)). The sip copies (acc/sip_<item>.svg) are the
# shared drawings with only their group transform changed.
SHARED = OUT.parent / "_shared"
SIP_T = {"coffee": "translate(146 114) rotate(-25)", "boba": "translate(147 116) rotate(-22)",
         "book": "translate(153 127) rotate(-8)"}


def sip_items():
    for item, t in SIP_T.items():
        src = (SHARED / f"hold_{item}.svg").read_text()
        src = re.sub(r'<g transform="[^"]*">', f'<g transform="{t}">', src, count=1)
        src = re.sub(r"<!--.*?-->", f"<!-- typebud shiba: shared {item} raised to the mouth for sip; only the "
                     f"group transform differs from _shared/hold_{item}.svg. Generated by art/shiba/_src/gen_shiba.py. -->",
                     src, count=1, flags=re.S)
        (OUT / "acc" / f"sip_{item}.svg").write_text(src)


# ---- head items ---------------------------------------------------------------------------------
def ear_overlay():
    """Redraw the visible ear tops (above the head) so a band/hat behind them is hidden."""
    vis = EARS.difference(HEAD)
    shade = EAR_R.difference(affinity.translate(EAR_R, -6, 3)).union(crescent(EAR_L, -4, 2))
    edge = LineString(list(EAR_L.exterior.coords)).difference(HEAD).union(
        LineString(list(EAR_R.exterior.coords)).difference(HEAD))
    seam = LineString(list(HEAD.exterior.coords)).intersection(EARS.buffer(3))
    return [P(geom_d(vis), FM), P(geom_d(shade.intersection(vis)), FS),
            P(geom_d(EAR_IN.difference(HEAD)), FL),
            P(lines_d(edge), stroke=OL, w=5), P(lines_d(seam), stroke=OL, w=5)]


def head_item(name, parts, comment):
    svg(f"acc/{name}.svg", ["<g>"] + ["  " + p for p in parts] + ["</g>"], comment)
    svg(f"acc/{name}_sleep.svg", [f'<g transform="{SLEEP_T}">'] + ["  " + p for p in parts] + ["</g>"],
        comment + " Sleep: same drawing in the sleep head transform.")


def headphones():
    grad = ('<defs><linearGradient id="hp-ring" gradientUnits="userSpaceOnUse" x1="0" y1="72" x2="0" y2="106">'
            + "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in
                      zip(["0", "0.25", "0.45", "0.62", "0.8", "1"], RAINBOW)) + "</linearGradient></defs>")
    band = "M91 72 C86 21 214 17 210 68"
    parts = [
        P("M97 62 C85 61 80 73 80 84 C80 94 85 104 98 101 C94 94 93 88 93 82 C93 75 94 69 97 62 Z",
          HP_SHADE, G_LINE, 4.5),
        P(band, stroke=G_LINE, w=14), P(band, stroke=HP_BAND, w=6.5),
        P("M140 28.5 C152 27 164 27 172 28", stroke=HP_CUP, w=2.5),
    ] + ear_overlay() + [
        E(202, 88, 11, 22, HP_SHADE, G_LINE, 4.5),
        E(212, 89, 13, 22, HP_CUP, G_LINE, 4.5),
        E(214, 89, 6.5, 14, HP_GLOW) [:-2] + ' stroke="url(#hp-ring)" stroke-width="3.5"/>',
        E(215, 89, 3, 8.5, HP_CUP),
    ]
    body = ["<g>"] + ["  " + p for p in parts] + ["</g>"]
    svg("acc/headphones.svg", [grad] + body, "headphones refitted to the shiba head; band runs behind the upright ears (ear tops redrawn over it).")
    svg("acc/headphones_sleep.svg", [grad, f'<g transform="{SLEEP_T}">'] + ["  " + p for p in parts] + ["</g>"],
        "headphones, sleep head transform.")


def beanie():
    # knit beanie sitting on the skull between the ears; ears poke out in front of it
    dome = "M116 58 C114 38 134 27.5 153 28 C172 28.5 190 38 188 56 Z"
    cuff = "M112 52 Q152 42 192 50 Q195 57 192 64 Q152 55 112 66 Q109 59 112 52 Z"
    k, c = "#E58A8A", "#C96F70"   # berry knit, shade
    dome_g = poly(dome)
    parts = [P(dome, k), P(geom_d(crescent(dome_g, -8, 4).intersection(dome_g)), c),
             P("M136 30 Q134 42 136 54 M152 30 L152 52 M168 30 Q170 42 168 52", stroke=c, w=2.5),
             P(dome, stroke=OL, w=4.5),
             P(cuff, "#F2B0A6", OL, 4.5),
             P("M124 55 L124 62 M136 52.5 L136 59.5 M148 51 L148 58 M160 51 L160 57.5 M172 51.5 L172 58 M184 53 L184 59.5",
               stroke="#D98F86", w=2.2)]
    parts += ear_overlay()
    head_item("beanie", parts, "berry knit beanie between the ears (ear tops redrawn in front).")


def party_hat():
    cone = "M134 58 L151 33 Q153 30 155 33 L172 54 Q153 62 134 58 Z"
    g = poly(cone)
    parts = [P(cone, "#7FC8E8"), P(geom_d(crescent(g, -6, 1).intersection(g)), "#5FAED0"),
             P("M141 47 Q148 50 162 44 M146 38 Q152 40 158 36", stroke=CREAM, w=4),
             P(cone, stroke=OL, w=4.5),
             P("M132 58 Q153 65 174 53", stroke=OL, w=7), P("M132 58 Q153 65 174 53", stroke="#F497B4", w=3),
             f'<circle cx="153" cy="31" r="4.5" fill="{CREAM}" stroke="{OL}" stroke-width="3"/>']
    head_item("party_hat", parts, "little party cone between the ears.")


def bow():
    c, s = "#F48FA8", "#D96C8A"
    parts = [P("M128 47 C120 36 106 38 107 47 C108 56 120 58 128 50 Z", c, OL, 4),
             P("M131 47 C138 35 152 36 151 45 C150 54 139 57 131 50 Z", c, OL, 4),
             P("M110 46 C112 50 118 51 122 49 M146 44 C145 49 140 51 136 50", stroke=s, w=2.5),
             E(129.5, 48.5, 4.6, 5, s, OL, 3.5)]
    head_item("bow", parts, "pink bow at the base of the left ear.")


def glasses():
    lens = "#FFFFFF"
    parts = [P("M177 81 C188 79 198 76 207 75", stroke=OL, w=4),
             f'<ellipse cx="122" cy="85" rx="12" ry="11" fill="{lens}" fill-opacity="0.35" stroke="{OL}" stroke-width="4"/>',
             f'<ellipse cx="165" cy="83" rx="12.5" ry="11.5" fill="{lens}" fill-opacity="0.35" stroke="{OL}" stroke-width="4"/>',
             P("M134 84 Q143 79 152.5 83", stroke=OL, w=4),
             P("M115 80 Q118 77 121 77 M158 78 Q161 75 164 75", stroke=WHITE, w=2)]
    head_item("glasses", parts, "round specs over the eyes.")


# ---- icons --------------------------------------------------------------------------------------
IC_S, IC_O = 1.74, (154, 77)          # scale about the head, then place at (128, 132)


def icon_xy(x, y):
    return (129.5 + (x - IC_O[0]) * IC_S, 134 + (y - IC_O[1]) * IC_S)


def icon_d(d):
    """Map every coordinate pair of an absolute path into icon space (no scale() on strokes)."""
    toks = TOK.findall(d)
    vals = [float(t) for t in toks if t not in "MLCQZ"]
    flat = iter([c for k in range(0, len(vals), 2) for c in icon_xy(vals[k], vals[k + 1])])
    return " ".join(t if t in "MLCQZ" else f(next(flat)) for t in toks)


def scale_d(d, cx, cy, k):
    toks = TOK.findall(d)
    vals = [float(t) for t in toks if t not in "MLCQZ"]
    flat = iter([c for i in range(0, len(vals), 2)
                 for c in (cx + (vals[i] - cx) * k, cy + (vals[i + 1] - cy) * k)])
    return " ".join(t if t in "MLCQZ" else f(next(flat)) for t in toks)


# icon ears are 25% bigger (about their bases) so they survive 16 px
ICON_EARS_D = scale_d(EAR_L_D, 120, 58, 1.25) + scale_d(EAR_R_D, 186, 58, 1.25)
ICON_EARS_IN_D = scale_d(EAR_L_IN, 120, 58, 1.25) + scale_d(EAR_R_IN, 186, 58, 1.25)


def icon_geom(g):
    return affinity.translate(affinity.scale(g, IC_S, IC_S, origin=IC_O), 129.5 - IC_O[0], 134 - IC_O[1])


def icons():
    ihead = poly(ICON_HEAD_D)
    head, ears, mask = icon_geom(ihead), icon_geom(poly(ICON_EARS_D)), icon_geom(poly(MASK_D).intersection(ihead))
    ear_in = icon_geom(poly(ICON_EARS_IN_D))
    eyes = "M115 84 Q122.5 85.5 130 84 M158 82 Q165.5 83.5 173 82"
    shade = crescent(head, -12, -10)
    body = [P(icon_d(ICON_EARS_D), FM), P(geom_d(ear_in), FL), P(icon_d(ICON_EARS_D), stroke=OL, w=16),
            P(icon_d(ICON_HEAD_D), FM), P(geom_d(mask), FL),
            P(geom_d(shade.difference(mask)), FS), P(geom_d(shade.intersection(mask)), FLS),
            P(icon_d(ICON_HEAD_D), stroke=OL, w=16),
            E(*icon_xy(110, 101), 13, 7.5, BLUSH), E(*icon_xy(178, 98), 13, 7.5, BLUSH),
            P(icon_d(eyes), stroke=OL, w=18),
            P(icon_d("M137 89.5 Q142 87.8 147 89.5 Q146.3 94.5 142 95.2 Q137.7 94.5 137 89.5 Z"), OL, OL, 7)]
    svg("icon.svg", body, "tray / app icon, face only.")
    # template: silhouette (fill + half the outline) with features cut out (even-odd)
    sil = unary_union([head, ears]).buffer(8, join_style="round")
    holes = unary_union([LineString(r).buffer(9, cap_style="round") for r in parse(icon_d(eyes))]
                        + [Polygon(parse(icon_d("M137 89.5 Q142 87.8 147 89.5 Q146.3 94.5 142 95.2 Q137.7 94.5 137 89.5 Z"))[0]).buffer(3.5)])
    holes = holes.intersection(sil.buffer(-4))
    d = geom_d(sil, 0.2) + geom_d(holes, 0.2)
    svg("icon_template.svg", [f'<path d="{d}" fill="#000000" fill-rule="evenodd"/>'],
        "tray template icon: black silhouette, features cut out.")


# ---- write everything ---------------------------------------------------------------------------
def main():
    frame("idle", "content", "smug", comment="idle: content closed eyes, smug little smile.")
    frame("peek", "open", "smug", comment="peek: same as idle with open eyes.")
    for n in ("type_left", "type_right", "type_both"):
        frame(n, "content", "smug", comment=f"{n}: content face.")
    frame("excited", "happy", "open", comment="excited: happy eyes, open smile with a tiny tongue.")
    frame("sleep", "sleepy", "calm", sleep=True, comment="sleep: lowered head, sleepy eyes.")
    frame("wake", "wake", "calm", sleep=True, comment="wake: lowered head, one eye open.")
    frame("hold", "content", "smug", comment="hold: content face while hugging the item.")
    frame("sip", "happy", "sip", comment="sip: blissful eyes, mouth at the item.")

    typing_paws("idle_paws.svg", "rest", "rest", "idle forearms + paws at rest.")
    typing_paws("type_left_paws.svg", "pressed", "raised", "type_left: L pressed, R raised.")
    typing_paws("type_right_paws.svg", "raised", "pressed", "type_right: R pressed, L raised.")
    typing_paws("type_both_paws.svg", "pressed", "pressed", "type_both: both pressed.")
    typing_paws("excited_paws.svg", "excited", "excited", "excited: both paws up.")
    typing_paws("sleep_paws.svg", "rest", "rest", "sleep forearms + paws at rest.", HEAD_SLEEP)

    # hug: paws wrap the lower front of the item
    # hug: forearms curl in from the shoulders, paws wrap the lower front of the item
    hl, hr = (122, 112), (190, 110)
    paws_layer("hold_paws.svg", [(arm(hl, (104, 152), (147, 153), 30, 22, 3), hl, (148, 152, 11.5, 9.5, -20)),
                                 (arm(hr, (199, 150), (183, 148), 26, 21, 2.5), hr, (182, 146, 10.5, 9.5, 20))],
               "hold: paws hug the held item.")
    # sip: same hug raised to the mouth (item at translate(146 114) rotate(-25))
    paws_layer("sip_paws.svg", [(arm(hl, (104, 146), (137, 131), 30, 22, 3), hl, (138, 130, 11, 9.5, -30)),
                                (arm(hr, (199, 138), (173, 125), 26, 21, 2.5), hr, (172, 124, 10.5, 9.5, 25))],
               "sip: paws raise the item to the mouth.")

    headphones(); beanie(); party_hat(); bow(); glasses(); sip_items()
    icons()


if __name__ == "__main__":
    main()
