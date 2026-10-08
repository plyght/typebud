#!/usr/bin/env python3
"""Generate every capybara layer (art/capybara/*.svg, acc/*.svg) from one set of shapes.

usage: python3 art/capybara/_src/gen.py && python3 scripts/render_art.py capybara

All paths use absolute M/L/C/Q/Z commands only, so `xf()` can move/scale them for the icon.
Colors: fur tokens are the placeholder hexes from art/_shared/themes.json (real colors in palette.json).
"""
import math
import re
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent
ACC = OUT / "acc"

# ---- colors ---------------------------------------------------------------------------------
LINE = "#3B2A1E"
MAIN, SHADE = "#B07A4A", "#8A5A33"          # fur_main, fur_shade
LIGHT, LIGHT_SH = "#E8C9A0", "#D4AE80"      # fur_light, fur_light_shade
DARK, DARK_SH = "#6B4A33", "#553A28"        # fur_dark, fur_dark_shade
FEATURE = "#E88F7A"
BLUSH, HATCH, WHITE, CREAM = "#F4A6A0", "#E07F7A", "#FFFFFF", "#FBE3A0"
SLEEP_T = "translate(-4 12) rotate(-6 152 80)"

NUM = re.compile(r"-?\d+(?:\.\d+)?")


def f(v):
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def xf(d, s=1.0, ox=0.0, oy=0.0, cx=0.0, cy=0.0):
    """Scale an absolute-only path about (cx, cy) by s, then move by (ox, oy)."""
    vals = [float(v) for v in NUM.findall(d)]
    it = iter(range(len(vals)))
    out, idx = [], 0

    def repl(m):
        nonlocal idx
        v = float(m.group(0))
        if idx % 2 == 0:
            r = (v - cx) * s + cx + ox
        else:
            r = (v - cy) * s + cy + oy
        idx += 1
        return f(r)
    return NUM.sub(repl, d)


def svg(body, comment):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">\n'
            f"  <!-- typebud capybara: {comment} -->\n{body}</svg>\n")


def P(d, fill="none", stroke=None, w=None, extra=""):
    s = f'  <path d="{d}" fill="{fill}"'
    if stroke:
        s += f' stroke="{stroke}" stroke-width="{f(w)}" stroke-linecap="round" stroke-linejoin="round"'
    return s + extra + "/>\n"


def E(cx, cy, rx, ry, fill="none", stroke=None, w=None, rot=None):
    s = f'  <ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"'
    if rot:
        s += f' transform="rotate({f(rot)} {f(cx)} {f(cy)})"'
    s += f' fill="{fill}"'
    if stroke:
        s += f' stroke="{stroke}" stroke-width="{f(w)}"'
    return s + "/>\n"


def G(inner, t=None):
    if not t:
        return inner
    return f'  <g transform="{t}">\n' + inner.replace("\n  <", "\n    <").replace("  <", "    <", 1) + "  </g>\n"


# ---- geometry (viewBox units, SPEC "Animal") -------------------------------------------------
# Head: a soft loaf, flatter on top than a circle, with full jowls. Center ~(152,82), x 95..210, y 39..127.
HEAD = ("M96 80 C95 54 108 40 138 39 L168 39 C196 39 209 53 209 79 L209.5 96 "
        "C210 118 194 128 162 128 L142 128 C112 128 96 118 96 98 Z")
# shade on the right side of the head (outline covers the outer edge)
HEAD_SH = ("M192 44 C206 52 212 66 212 80 L212 98 C212 118 196 130 166 130 L158 130 "
           "C186 124 200 112 200 96 L200 80 C200 64 198 52 192 44 Z")
# Ears: tiny rounded nubs high on the head; far (L) ear smaller, near (R) ear a bit bigger.
EAR_L = (109, 46, 8.5, 7.5, -30)
EAR_R = (193, 45, 9.5, 8.5, 28)
EAR_L_IN = (107.5, 44, 4.2, 3.4, -30)
EAR_R_IN = (194, 43, 4.8, 3.8, 28)
# Cowlick: a single swoopy tuft on the crown, leaning right.
TUFT = "M140 41 C138 32 144 26 152 27 C148 30 148 34 152 37 C154 31 160 29 165 31 C160 34 158 38 158 41 Z"
TUFT_LN = "M140 41 C138 32 144 26 152 27 C148 30 148 34 152 37 C154 31 160 29 165 31 C160 34 158 38 158 41"
# Muzzle: big blunt loaf of dark fur, wider than tall, sitting low on the face (3/4: a bit left).
MUZZLE = "M119 105 C119 93 127 89 144 89 C161 89 169 93 169 105 C169 117 160 123 144 123 C128 123 119 117 119 105 Z"
MUZZLE_SH = "M162 92 C167 95 170 100 169 106 C168 117 159 123 147 123 L144 123 C156 119 163 112 164 104 C164 99 164 95 162 92 Z"
NOSTRILS = "M133.5 99 Q135.5 96.5 138.5 97.5 M150.5 97.5 Q153.5 96.5 155.5 99"
WHISKER_DOTS = []

# Body: chunky barrel, leaning a touch right; bottom hidden by the keyboard.
BODY = "M114 110 C98 128 92 166 98 202 L200 196 C206 168 207 132 192 108 Z"
BODY_SH = "M190 116 C202 136 206 166 201 198 L186 198 C192 172 192 146 182 126 Z"
CHIN_SH = "M114 120 C132 134 172 136 194 120 L196 130 C174 144 132 144 112 130 Z"
BELLY = "M128 146 C128 132 140 128 152 128 C166 128 178 134 178 150 C178 170 168 190 152 190 C136 190 128 170 128 146 Z"
BELLY_SH = "M170 134 C176 140 178 146 178 152 C178 170 168 190 152 190 L150 190 C162 182 170 166 170 150 C170 144 170 138 170 134 Z"

EYE_L, EYE_R = (122.5, 84), (165.5, 82)


# ---- faces ----------------------------------------------------------------------------------
def eye(kind, cx, cy):
    if kind == "content":
        return P(f"M{f(cx-7.5)} {f(cy)} Q{f(cx)} {f(cy+1.5)} {f(cx+7.5)} {f(cy)}", stroke=LINE, w=4.5)
    if kind == "open":
        return E(cx, cy, 4.8, 5.8, fill=LINE) + f'  <circle cx="{f(cx-1.5)}" cy="{f(cy-2.2)}" r="1.8" fill="{WHITE}"/>\n'
    if kind == "happy":
        return P(f"M{f(cx-7)} {f(cy+3)} Q{f(cx)} {f(cy-6)} {f(cx+7)} {f(cy+3)}", stroke=LINE, w=4.5)
    if kind == "sleepy":
        return P(f"M{f(cx-7)} {f(cy-2)} Q{f(cx)} {f(cy+5)} {f(cx+7)} {f(cy-2)}", stroke=LINE, w=4.5)
    raise ValueError(kind)


def blush():
    s = E(110, 100, 8, 4.5, fill=BLUSH) + E(177, 98, 8, 4.5, fill=BLUSH)
    s += P("M106 102 L108 98 M109.5 102.5 L111.5 98.5 M113 102 L115 98 "
           "M173 100 L175 96 M176.5 100.5 L178.5 96.5 M180 100 L182 96", stroke=HATCH, w=1.6)
    return s


def mouth(kind):
    if kind == "w":        # tiny calm "w" under the nostrils
        return P("M144 103 L144 106.5 M138.5 107 Q141.3 110.5 144 106.5 Q146.7 110.5 149.5 107", stroke=LINE, w=3.5)
    if kind == "sip":      # little pursed "o" pushed toward the cup
        return P("M144 103 L143 105.5", stroke=LINE, w=3.5) + E(141, 109, 3.4, 3, fill=LINE)
    if kind == "open":
        return (P("M137 106 Q144 105 151 106 Q151 116 144 116 Q137 116 137 106 Z", fill=FEATURE, stroke=LINE, w=3.5)
                + P("M140.5 113 Q144 111 147.5 113", stroke="#C9675A", w=2))
    if kind == "sleep":    # relaxed, slightly slack "w"
        return P("M144 103 L144 106.5 M139.5 108 Q141.8 110 144 107 Q146.2 110 148.5 108", stroke=LINE, w=3.5)
    raise ValueError(kind)


def ears():
    s = ""
    for (cx, cy, rx, ry, r), (ix, iy, irx, iry, ir) in ((EAR_L, EAR_L_IN), (EAR_R, EAR_R_IN)):
        s += E(cx, cy, rx, ry, fill=MAIN, stroke=LINE, w=5, rot=r)
        s += E(ix, iy, irx, iry, fill=DARK, rot=ir)
    return s


def head(eyes=("content", "content"), mouth_kind="w"):
    s = ears()
    s += P(HEAD, fill=MAIN) + P(HEAD_SH, fill=SHADE) + P(HEAD, stroke=LINE, w=5)
    s += P(TUFT, fill=MAIN) + P(TUFT_LN, stroke=LINE, w=4)
    s += blush()
    s += P(MUZZLE, fill=DARK) + P(MUZZLE_SH, fill=DARK_SH)
    s += P(NOSTRILS, stroke=LINE, w=3.5)
    s += "".join(f'  <circle cx="{f(x)}" cy="{f(y)}" r="1.5" fill="{DARK_SH}"/>\n' for x, y in WHISKER_DOTS)
    s += eye(eyes[0], *EYE_L) + eye(eyes[1], *EYE_R)
    s += mouth(mouth_kind)
    return s


def body():
    s = P(BODY, fill=MAIN) + P(CHIN_SH, fill=SHADE) + P(BODY_SH, fill=SHADE)
    s += P(BODY, stroke=LINE, w=5)
    return s


def frame(name, eyes, mouth_kind, sleepy=False, note=""):
    h = head(eyes, mouth_kind)
    if sleepy:
        h = G(h, SLEEP_T)
    return svg(body() + h, f"{name}. {note}")


# ---- forearms + paws --------------------------------------------------------------------------
SH_L, SH_R = (119, 145), (178, 151)


def tube(S, Pp, ws, wp, bulge_side, bulge=1.35):
    """Chubby sausage from shoulder S to paw P. Returns (fill path, outline subpaths)."""
    dx, dy = Pp[0] - S[0], Pp[1] - S[1]
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    nx, ny = -uy, ux                       # left normal
    pts = {}
    for sgn in (1, -1):
        k = bulge if sgn == bulge_side else 1.05
        a = (S[0] + nx * ws * sgn, S[1] + ny * ws * sgn)
        b = (Pp[0] + nx * wp * sgn, Pp[1] + ny * wp * sgn)
        c1 = (S[0] + nx * ws * sgn * k + ux * L * 0.35, S[1] + ny * ws * sgn * k + uy * L * 0.35)
        c2 = (Pp[0] + nx * wp * sgn * k - ux * L * 0.35, Pp[1] + ny * wp * sgn * k - uy * L * 0.35)
        pts[sgn] = (a, c1, c2, b)
    A, B = pts[1], pts[-1]
    q = lambda p: f"{f(p[0])} {f(p[1])}"
    fill = (f"M{q(A[0])} C{q(A[1])} {q(A[2])} {q(A[3])} L{q(B[3])} "
            f"C{q(B[2])} {q(B[1])} {q(B[0])} Z")
    line = (f"M{q(A[0])} C{q(A[1])} {q(A[2])} {q(A[3])} "
            f"M{q(B[0])} C{q(B[1])} {q(B[2])} {q(B[3])}")
    return fill, line


def tube_side(S, Pp, ws, wp):
    """Shade strip along the screen-right contour of a tube (light from the upper left)."""
    dx, dy = Pp[0] - S[0], Pp[1] - S[1]
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    nx, ny = -uy, ux
    sgn = 1 if nx > 0 else -1        # the side whose normal points right
    def side(w, k):
        return (S[0] + nx * w * sgn * k, S[1] + ny * w * sgn * k), (Pp[0] + nx * wp / ws * w * sgn * k, Pp[1] + ny * wp / ws * w * sgn * k)
    (a0, b0), (a1, b1) = side(ws, 1.25), side(ws, 0.45)
    q = lambda p: f"{f(p[0])} {f(p[1])}"
    c = lambda a, b: (f"{q((a[0] + ux * L * .35, a[1] + uy * L * .35))} {q((b[0] - ux * L * .35, b[1] - uy * L * .35))}")
    return (f"M{q(a0)} C{c(a0, b0)} {q(b0)} L{q(b1)} C{q((b1[0] - ux * L * .35, b1[1] - uy * L * .35))} "
            f"{q((a1[0] + ux * L * .35, a1[1] + uy * L * .35))} {q(a1)} Z"), None


def paw(cx, cy, rot, state, toes_dir=1):
    rx, ry = 14, 10
    if state == "pressed":
        rx, ry = 14.8, 10 * 0.85
    if state == "hug":
        rx, ry = 11.5, 9.5
    inner = E(cx, cy, rx, ry, fill=MAIN, stroke=LINE, w=4.5)
    if state == "hug":
        tx = cx + 4 * toes_dir
        inner += P(f"M{f(tx)} {f(cy-4)} L{f(tx+3*toes_dir)} {f(cy-4.6)} M{f(tx+0.6*toes_dir)} {f(cy+2)} L{f(tx+3.6*toes_dir)} {f(cy+1.6)}",
                   stroke=LINE, w=2.5)
    else:
        b = cy + ry - 2.5
        inner += P(f"M{f(cx-5)} {f(b-1.5)} L{f(cx-4.4)} {f(b+1.5)} M{f(cx+3)} {f(b-1)} L{f(cx+3.6)} {f(b+2)}",
                   stroke=LINE, w=2.5)
    return G(inner, f"rotate({f(rot)} {f(cx)} {f(cy)})" if rot else None)


REST_L, REST_R = (122, 168), (160, 180)


def paw_state(rest, state):
    x, y = rest
    if state == "pressed":
        return (x, y + 3), 14
    if state == "raised":
        return (x + 2, y - 10), 0
    if state == "excited":
        return (x, y - 12), 6
    return (x, y), 14


def capsule(E_, Pp, re, rp, bow=0.0, inset=0.0):
    """Closed chubby forearm from elbow E_ (radius re) to paw end Pp (radius rp); `bow` bends the
    centerline sideways (positive = toward the left normal). Absolute cubic path."""
    dx, dy = Pp[0] - E_[0], Pp[1] - E_[1]
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    nx, ny = -uy, ux
    k = 0.5523
    re, rp = re - inset, rp - inset
    q = lambda x, y: f"{f(x)} {f(y)}"
    a = (E_[0] + nx * re, E_[1] + ny * re)
    b = (Pp[0] + nx * rp, Pp[1] + ny * rp)
    c = (Pp[0] - nx * rp, Pp[1] - ny * rp)
    d = (E_[0] - nx * re, E_[1] - ny * re)
    bx, by = nx * bow, ny * bow
    path = f"M{q(*a)} C{q(a[0] + ux * L * .33 + bx, a[1] + uy * L * .33 + by)} {q(b[0] - ux * L * .33 + bx, b[1] - uy * L * .33 + by)} {q(*b)}"
    # round paw end
    path += f" C{q(b[0] + ux * rp * k, b[1] + uy * rp * k)} {q(Pp[0] + ux * rp + nx * rp * k, Pp[1] + uy * rp + ny * rp * k)} {q(Pp[0] + ux * rp, Pp[1] + uy * rp)}"
    path += f" C{q(Pp[0] + ux * rp - nx * rp * k, Pp[1] + uy * rp - ny * rp * k)} {q(c[0] + ux * rp * k, c[1] + uy * rp * k)} {q(*c)}"
    path += f" C{q(c[0] - ux * L * .33 + bx, c[1] - uy * L * .33 + by)} {q(d[0] + ux * L * .33 + bx, d[1] + uy * L * .33 + by)} {q(*d)}"
    # round elbow end
    path += f" C{q(d[0] - ux * re * k, d[1] - uy * re * k)} {q(E_[0] - ux * re - nx * re * k, E_[1] - uy * re - ny * re * k)} {q(E_[0] - ux * re, E_[1] - uy * re)}"
    path += f" C{q(E_[0] - ux * re + nx * re * k, E_[1] - uy * re + ny * re * k)} {q(a[0] - ux * re * k, a[1] - uy * re * k)} {q(*a)} Z"
    return path


def arm(E_, Pp, re, rp, bow):
    """Fill, the one shade tone on the screen-right side, then the full outline."""
    body_ = capsule(E_, Pp, re, rp, bow)
    dx, dy = Pp[0] - E_[0], Pp[1] - E_[1]
    L = math.hypot(dx, dy)
    nx, ny = -dy / L, dx / L
    if nx > 0:      # make (nx, ny) point screen-left so the shade goes right
        nx, ny = -nx, -ny
    sh_off = 0.62
    shade = capsule((E_[0] - nx * re * sh_off, E_[1] - ny * re * sh_off), (Pp[0] - nx * rp * sh_off, Pp[1] - ny * rp * sh_off),
                    re * 0.5, rp * 0.5, bow)
    return P(body_, fill=MAIN) + P(shade, fill=SHADE) + P(body_, stroke=LINE, w=5)


ELBOW_L, ELBOW_R = (114, 142), (186, 150)


def arms(lp, lrot, lstate, rp, rrot, rstate, el=ELBOW_L, er=ELBOW_R, r=(13.5, 11.5), bows=(3, -3), toes=(1, -1)):
    s = arm(el, lp, r[0], r[1], bows[0]) + arm(er, rp, r[0], r[1], bows[1])
    s += paw(*lp, lrot, lstate, toes[0]) + paw(*rp, rrot, rstate, toes[1])
    return s


def typing_paws(lstate, rstate, name):
    lp, lr = paw_state(REST_L, lstate)
    rp, rr = paw_state(REST_R, rstate)
    return svg(arms(lp, lr, lstate, rp, rr, rstate), f"{name} forearms + paws (drawn after the keyboard).")


# held-item placements
HOLD_T = {"hold_coffee": "translate(164 140) rotate(10)", "hold_boba": "translate(164 140) rotate(10)",
          "hold_book": "translate(164 140) rotate(-8)"}
SIP_T = {"hold_coffee": "translate(151 128) rotate(-30)", "hold_boba": "translate(148 137) rotate(-24)",
         "hold_book": "translate(154 134) rotate(-4)"}
HUG_L, HUG_R = (148, 152), (182, 146)
SIP_L, SIP_R = (137, 136), (171, 128)


def hold_paws():
    return svg(arms(HUG_L, -20, "hug", HUG_R, 20, "hug", el=(118, 136), er=(193, 134), r=(13, 11), bows=(-4, 4)),
               "hold forearms + paws: hugging the held item's lower front (drawn after the item).")


def sip_paws():
    return svg(arms(SIP_L, -30, "hug", SIP_R, 10, "hug", el=(116, 150), er=(192, 146), r=(13, 11), bows=(-4, 4)),
               "sip forearms + paws: lifting the item to the mouth (drawn after acc/hold_*_sip).")


# ---- accessories --------------------------------------------------------------------------------
def ears_on_top():
    """Ears redrawn above a head item so the item sits between/behind them."""
    return ears()


HP_DEFS = """  <defs>
    <linearGradient id="hp-ring" gradientUnits="userSpaceOnUse" x1="0" y1="72" x2="0" y2="106">
      <stop offset="0" stop-color="#4FC3F7"/>
      <stop offset="0.25" stop-color="#7C6CFF"/>
      <stop offset="0.45" stop-color="#E86BD8"/>
      <stop offset="0.62" stop-color="#FF5C6C"/>
      <stop offset="0.8" stop-color="#FFE45C"/>
      <stop offset="1" stop-color="#5EE08A"/>
    </linearGradient>
  </defs>
"""


def headphones():
    s = ""
    # far cup crescent outside the head's left edge, H.y-17 .. H.y+21
    s += P("M97 66 C85 65 80 76 80 86 C80 96 85 104 97 103 C93 96 92 90 92 85 C92 78 93 72 97 66 Z",
           fill="#2F333D", stroke="#22252C", w=4.5)
    band = "M88 76 C86 26 214 22 207 72"
    s += P(band, stroke="#22252C", w=14) + P(band, stroke="#3B414E", w=6.5)
    s += P("M100 50 C116 36 146 31 170 34", stroke="#474D5A", w=2.5)
    s += ears_on_top()
    s += P(TUFT, fill=MAIN) + P(TUFT_LN, stroke=LINE, w=4)
    s += E(200, 89, 10.5, 21.5, fill="#2F333D", stroke="#22252C", w=4.5)
    s += E(210, 89, 13, 22, fill="#474D5A", stroke="#22252C", w=4.5)
    s += E(212, 89, 6.5, 14, fill="#9FE8FF", stroke="url(#hp-ring)", w=3.5)
    s += E(213, 89, 3, 8.5, fill="#474D5A")
    return s


BEANIE_C, BEANIE_SH, BEANIE_RIB = "#E9785E", "#CC5F48", "#F4A08A"


def beanie():
    dome = "M104 60 C104 38 126 30 152 30 C178 30 200 38 200 58 Z"
    s = P(dome, fill=BEANIE_C) + P("M184 34 C196 40 200 48 200 58 L188 58 C190 50 188 42 184 34 Z", fill=BEANIE_SH)
    s += P(dome, stroke=LINE, w=4.5)
    s += P("M126 36 L124 52 M152 32 L152 50 M176 36 L178 52", stroke=BEANIE_SH, w=2.5)
    cuff = "M100 58 C130 50 172 49 204 56 C206 61 205 66 203 69 C172 62 132 63 101 71 C98 67 98 62 100 58 Z"
    s += P(cuff, fill=BEANIE_RIB) + P("M186 54 C196 55 202 56 204 56 C206 61 205 66 203 69 C198 68 192 66 186 66 Z", fill=BEANIE_C)
    s += P(cuff, stroke=LINE, w=4.5)
    s += P("M112 59 L113 66 M124 57 L125 64 M136 55.5 L136.5 62.5 M148 55 L148 62 M160 55 L160 62 "
           "M172 55.5 L171.5 62.5 M184 56.5 L183.5 63.5 M195 58 L194.5 65", stroke=BEANIE_SH, w=2.2)
    # pom-pom, sitting on the right shoulder of the dome (keeps it inside the safe box)
    s += f'  <circle cx="176" cy="34" r="7.5" fill="{CREAM}" stroke="{LINE}" stroke-width="4"/>\n'
    s += P("M172.5 32 Q174 30 176.5 30.5", stroke=WHITE, w=2)
    # the little ears poke through knitted holes
    s += E(113, 47, 9.5, 8.5, fill=MAIN, stroke=LINE, w=4.5, rot=-25) + E(111.5, 45, 4.4, 3.6, fill=DARK, rot=-25)
    s += E(190, 44, 10.5, 9.5, fill=MAIN, stroke=LINE, w=4.5, rot=20) + E(190.5, 42, 5, 4, fill=DARK, rot=20)
    return s


def party_hat():
    # squat cone tipped toward the near ear; stripes + pom-pom
    t = "translate(168 52) rotate(26)"
    cone = "M-18 2 Q-10 -11 -2.5 -20 Q0 -23 2.5 -20 Q10 -11 18 2 Q0 8 -18 2 Z"
    inner = P(cone, fill="#8EC5F0")
    inner += P("M-12 -6 Q0 -2 12 -6 L15 -1 Q0 4 -15 -1 Z M-6 -14 Q0 -11.5 6 -14 L8.5 -10 Q0 -7.5 -8.5 -10 Z", fill="#FFE07A")
    inner += P("M6 -14 L18 2 Q14 4 10 4.5 L3 -17 Z", fill="#6FA9D8")
    inner += P(cone, stroke=LINE, w=4.5)
    inner += f'  <circle cx="0" cy="-21.5" r="4.6" fill="{BLUSH}" stroke="{LINE}" stroke-width="3.5"/>\n'
    inner += P("M-10 -5 L-7.5 -10", stroke=WHITE, w=2.2)
    return G(inner, t)


def bow():
    t = "translate(178 44) rotate(14)"
    inner = P("M-2 0 C-8 -10 -20 -12 -19 -1 C-18 9 -8 8 -2 0 Z", fill="#F497B4", stroke=LINE, w=4)
    inner += P("M2 0 C8 -10 20 -12 19 -1 C18 9 8 8 2 0 Z", fill="#F497B4", stroke=LINE, w=4)
    inner += P("M9 -6 C14 -7 16 -4 16 0 C14 3 11 4 8 3 Z", fill="#E07A9C")
    inner += P("M-12 -4 Q-9 -1 -6 -1 M12 -4 Q9 -1 6 -1", stroke="#E07A9C", w=2)
    inner += P("M-3 5 L-8 13 M3 5 L8 13", stroke=LINE, w=7.5) + P("M-3 5 L-8 13 M3 5 L8 13", stroke="#F497B4", w=3)
    inner += E(0, 0, 5, 5.5, fill="#F7B3C8", stroke=LINE, w=4)
    return G(inner, t)


def glasses():
    s = ""
    # far temple arm is hidden; near arm runs back to the near ear over the cheek
    s += P("M176 80 C186 76 196 74 207 74", stroke=LINE, w=4)
    for cx, cy in ((122.5, 84.5), (165.5, 82.5)):
        s += f'  <circle cx="{f(cx)}" cy="{f(cy)}" r="12" fill="{WHITE}" fill-opacity="0.28" stroke="{LINE}" stroke-width="4.5"/>\n'
    s += P("M134.5 83 Q144 78.5 153.5 81.5", stroke=LINE, w=4)
    s += P("M115 79 Q117.5 75.5 121 75 M158 77 Q160.5 73.5 164 73", stroke=WHITE, w=2.2)
    return s


YUZU, YUZU_SH, LEAF = "#FFCC4D", "#F0A93A", "#86C27A"


def yuzu():
    cx, cy, r = 148, 41, 12.5
    s = f'  <circle cx="{cx}" cy="{cy}" r="{r}" fill="{YUZU}"/>\n'
    s += P("M155 32 C161 36 163 44 158 50 C154 54 147 54 142 52 C150 50 157 44 155 32 Z", fill=YUZU_SH)
    s += f'  <circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{LINE}" stroke-width="4.5"/>\n'
    s += "".join(f'  <circle cx="{x}" cy="{y}" r="1.1" fill="{YUZU_SH}"/>\n' for x, y in ((142, 40), (146, 46), (152, 43), (147, 36)))
    s += P("M150 30 Q151 27.5 153 27 M153 29.5 Q160 25.5 166 30 Q159 35 153 29.5 Z", fill=LEAF, stroke=LINE, w=3)
    s += P("M140.5 36.5 Q142 33.5 145 33", stroke=WHITE, w=2.2)
    return s


def item(name, t, shared_dir):
    src = (shared_dir / f"{name}.svg").read_text()
    out = re.sub(r'<g transform="[^"]*">', f'<g transform="{t}">', src, count=1)
    return out.replace("typebud shared", "typebud capybara (fitted from the shared item)", 1)


# ---- icon ------------------------------------------------------------------------------------
# Drawn separately (not a scaled frame head) so every feature is >= 1 px at 16x16:
# loaf head, two ear nubs, content eyes, big dark muzzle with two nostrils, blush.
IC_HEAD = ("M26 136 C24 86 54 66 102 66 L154 66 C202 66 232 86 230 136 L230 160 "
           "C230 206 200 226 152 226 L104 226 C56 226 26 206 26 160 Z")
IC_HEAD_SH = ("M196 74 C222 86 236 106 236 136 L236 162 C236 208 206 232 156 232 L150 232 "
              "C192 222 214 202 214 162 L214 136 C214 108 208 88 196 74 Z")
IC_EARS = [(62, 66, 23, 21, -20), (194, 66, 23, 21, 20)]
IC_EARS_IN = [(58, 60, 11, 9, -20), (198, 60, 11, 9, 20)]
IC_MUZZLE = "M70 168 C70 146 92 138 128 138 C164 138 186 146 186 168 C186 198 170 214 128 214 C86 214 70 198 70 168 Z"
IC_NOSTRILS = [((98, 162), (112, 155)), ((144, 155), (158, 162))]
IC_MOUTH = [((128, 176), (128, 186)), ((128, 186), (114, 194)), ((128, 186), (142, 194))]
IC_EYES = [((58, 124), (100, 124)), ((156, 124), (198, 124))]


def icon():
    s = ""
    for (cx, cy, rx, ry, r), (ix, iy, irx, iry, ir) in zip(IC_EARS, IC_EARS_IN):
        s += E(cx, cy, rx, ry, fill=MAIN, stroke=LINE, w=16, rot=r)
        s += E(ix, iy, irx, iry, fill=DARK, rot=ir)
    s += P(IC_HEAD, fill=MAIN) + P(IC_HEAD_SH, fill=SHADE) + P(IC_HEAD, stroke=LINE, w=16)
    s += E(52, 168, 17, 11, fill=BLUSH) + E(204, 168, 17, 11, fill=BLUSH)
    s += P(IC_MUZZLE, fill=DARK)
    s += P(" ".join(f"M{a[0]} {a[1]} L{b[0]} {b[1]}" for a, b in IC_NOSTRILS), stroke=LINE, w=13)
    s += P(" ".join(f"M{a[0]} {a[1]} L{b[0]} {b[1]}" for a, b in IC_MOUTH), stroke=LINE, w=10)
    for (ax, ay), (bx, by) in IC_EYES:
        s += P(f"M{f(ax)} {f(ay)} Q{f((ax+bx)/2)} {f(ay+4)} {f(bx)} {f(by)}", stroke=LINE, w=18)
    return svg(s, "icon: face only for the tray/app icon (outline 16, eyes 18); reads at 16x16.")


def ell_path(cx, cy, rx, ry, rot=0.0, n=4):
    """Ellipse as 4 cubic segments (absolute), optionally rotated (degrees)."""
    k = 0.5523
    pts = [(rx, 0), (rx, ry * k), (rx * k, ry), (0, ry), (-rx * k, ry), (-rx, ry * k), (-rx, 0),
           (-rx, -ry * k), (-rx * k, -ry), (0, -ry), (rx * k, -ry), (rx, -ry * k), (rx, 0)]
    c, s_ = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    R = [(cx + x * c - y * s_, cy + x * s_ + y * c) for x, y in pts]
    q = lambda p: f"{f(p[0])} {f(p[1])}"
    d = f"M{q(R[0])}"
    for i in range(1, 13, 3):
        d += f" C{q(R[i])} {q(R[i+1])} {q(R[i+2])}"
    return d + " Z"


def stroke_slot(a, b, w):
    """Closed capsule path around segment a-b with half-width w/2 (for template holes)."""
    (ax, ay), (bx, by) = a, b
    L = math.hypot(bx - ax, by - ay)
    ux, uy = (bx - ax) / L, (by - ay) / L
    nx, ny = -uy * w / 2, ux * w / 2
    r = w / 2
    q = lambda x, y: f"{f(x)} {f(y)}"
    k = 0.5523
    d = f"M{q(ax+nx, ay+ny)} L{q(bx+nx, by+ny)}"
    d += f" C{q(bx+nx+ux*r*k, by+ny+uy*r*k)} {q(bx+ux*r+nx*k, by+uy*r+ny*k)} {q(bx+ux*r, by+uy*r)}"
    d += f" C{q(bx+ux*r-nx*k, by+uy*r-ny*k)} {q(bx-nx+ux*r*k, by-ny+uy*r*k)} {q(bx-nx, by-ny)}"
    d += f" L{q(ax-nx, ay-ny)}"
    d += f" C{q(ax-nx-ux*r*k, ay-ny-uy*r*k)} {q(ax-ux*r-nx*k, ay-uy*r-ny*k)} {q(ax-ux*r, ay-uy*r)}"
    d += f" C{q(ax-ux*r+nx*k, ay-uy*r+ny*k)} {q(ax+nx-ux*r*k, ay+ny-uy*r*k)} {q(ax+nx, ay+ny)} Z"
    return d


def icon_template():
    # silhouette = head + ears grown by half the icon outline (8); holes = eye slits and the muzzle,
    # with the two nostrils left solid inside the muzzle hole (even-odd).
    sil = xf(IC_HEAD, 1.0)
    grow = lambda d: xf(d, 1.0 + 16 / 206, 0, 0, 128, 146)
    ears_d = " ".join(ell_path(cx, cy, rx + 8, ry + 8, r) for cx, cy, rx, ry, r in IC_EARS)
    holes = " ".join(stroke_slot((ax, ay + 1), (bx, by + 1), 18) for (ax, ay), (bx, by) in IC_EYES)
    nost = " ".join(stroke_slot(a, b, 15) for a, b in IC_NOSTRILS)
    s = P(ears_d, fill="#000000")
    s += P(f"{grow(IC_HEAD)} {holes} {IC_MUZZLE} {nost}", fill="#000000", extra=' fill-rule="evenodd"')
    return svg(s, "icon_template: pure black silhouette of icon.svg, features cut out (even-odd).")


# ---- write ------------------------------------------------------------------------------------
def main():
    ACC.mkdir(parents=True, exist_ok=True)
    shared = OUT.parent / "_shared"
    files = {
        "idle": frame("idle", ("content", "content"), "w", note="content closed eyes, calm little 'w'."),
        "peek": frame("peek", ("open", "open"), "w", note="idle with small open eyes."),
        "type_left": frame("type_left", ("content", "content"), "w", note="body/head identical to idle."),
        "type_right": frame("type_right", ("content", "content"), "w", note="body/head identical to idle."),
        "type_both": frame("type_both", ("content", "content"), "w", note="body/head identical to idle."),
        "excited": frame("excited", ("happy", "happy"), "open", note="happy ^ ^ eyes, open smile."),
        "sleep": frame("sleep", ("sleepy", "sleepy"), "sleep", sleepy=True, note="head lowered (sleep transform)."),
        "wake": frame("wake", ("open", "sleepy"), "w", sleepy=True, note="head still lowered, one eye open."),
        "hold": frame("hold", ("content", "content"), "w", note="content face while hugging the item."),
        "sip": frame("sip", ("happy", "happy"), "sip", note="blissful eyes, mouth at the item."),
        "idle_paws": typing_paws("rest", "rest", "idle"),
        "type_left_paws": typing_paws("pressed", "raised", "type_left"),
        "type_right_paws": typing_paws("raised", "pressed", "type_right"),
        "type_both_paws": typing_paws("pressed", "pressed", "type_both"),
        "excited_paws": typing_paws("excited", "excited", "excited"),
        "sleep_paws": typing_paws("rest", "rest", "sleep"),
        "hold_paws": hold_paws(),
        "sip_paws": sip_paws(),
        "icon": icon(),
        "icon_template": icon_template(),
    }
    head_items = {
        "headphones": (HP_DEFS, headphones(), "headphones refit to the loaf head; ears drawn over the band"),
        "beanie": ("", beanie(), "knit beanie; the tiny ears poke through"),
        "party_hat": ("", party_hat(), "party hat tipped toward the near ear"),
        "bow": ("", bow(), "ribbon bow beside the near ear"),
        "glasses": ("", glasses(), "round glasses over the eyes"),
        "yuzu": ("", yuzu(), "OPTIONAL personality item: a yuzu balanced on the crown"),
    }
    for name, (defs, body_, note) in head_items.items():
        files[f"acc/{name}"] = svg(defs + body_, note + ".")
        files[f"acc/{name}_sleep"] = svg(defs + G(body_, SLEEP_T), note + " (sleep: follows the lowered head).")
    for it in ("hold_coffee", "hold_boba", "hold_book"):
        files[f"acc/{it}"] = item(it, HOLD_T[it], shared)
        files[f"acc/{it}_sip"] = item(it, SIP_T[it], shared).replace("hug position", "SIP position", 1)
    for rel, text in files.items():
        p = OUT / f"{rel}.svg"
        p.write_text(text)
    print(f"wrote {len(files)} files")


if __name__ == "__main__":
    main()
