#!/usr/bin/env python3
"""Generate the penguin's SVG layers (art/SPEC.md, art/STYLE.md).

usage: python3 art/penguin/_src/gen_penguin.py   (then scripts/render_art.py penguin)
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent

# ---- colors -------------------------------------------------------------------------------
O = "#3B2A1E"            # outline
BLUSH, HATCH, WHITE, CREAM = "#F4A6A0", "#E07F7A", "#FFFFFF", "#FBE3A0"
# fur placeholders (real colors in palette.json)
RIM = "#B07A4A"          # fur_main       -> light slate sheen on the back feathers
BACK = "#6B4A33"         # fur_dark       -> slate/navy back, head cap, flippers
BACK_SH = "#553A28"      # fur_dark_shade -> shade on the back
BELLY = "#E8C9A0"        # fur_light      -> white belly and face mask
BELLY_SH = "#D4AE80"     # fur_light_shade
BEAK = "#E88F7A"         # feature        -> beak and feet
# gear tokens
G_LINE, HP_BAND, HP_CUP, HP_SH, HP_GLOW = "#22252C", "#3B414E", "#474D5A", "#2F333D", "#9FE8FF"

# ---- geometry -----------------------------------------------------------------------------
HX, HY, RX, RY = 152, 80, 57, 46
SLEEP_T = "translate(-4 12) rotate(-6 152 80)"


def ell(a_deg, rx=RX, ry=RY, cx=HX, cy=HY):
    a = math.radians(a_deg)
    return cx + rx * math.cos(a), cy + ry * math.sin(a)


def f(v):
    return f"{v:.1f}".rstrip("0").rstrip(".")


def P(*pts):
    return " ".join(f"{f(x)} {f(y)}" for x, y in pts)


JA = 26                                   # head/body junction: degrees below the head's equator
JL, JR = ell(180 - JA), ell(JA)

SW = 'stroke-linecap="round" stroke-linejoin="round"'


def svg(body, comment, defs=""):
    d = f"\n  <defs>{defs}\n  </defs>" if defs else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">\n'
            f"  <!-- {comment} -->{d}\n{body}\n</svg>\n")


def write(name, text):
    p = OUT / f"{name}.svg"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


# ---- body (never moves) ---------------------------------------------------------------------
BODY_D = (f"M{P(JL)} C{P((95, 118), (91, 156), (95, 190))} "
          f"C{P((98, 214), (118, 233), (150, 233))} "
          f"C{P((172, 233), (188, 226), (196, 206))} "
          f"C{P((201, 182), (205, 130), JR)} "
          f"C{P((190, 62), (114, 62), JL)} Z")
# right-flank shade: outer edge copies the body's right side
FLANK_SH = (f"M{P((196, 206))} C{P((201, 182), (205, 130), JR)} "
            f"C{P((198, 112), (195, 140), (194, 168))} C{P((192, 190), (189, 204), (184, 214))} Z")
BELLY_D = (f"M{P((120, 112))} C{P((108, 136), (106, 186), (116, 226))} "
           f"L{P((176, 228))} C{P((190, 196), (192, 150), (182, 112))} "
           f"C{P((166, 104), (136, 104), (120, 112))} Z")
BELLY_SH_D = (f"M{P((183, 120))} C{P((190, 150), (189, 196), (178, 226))} "
              f"L{P((168, 226))} C{P((178, 196), (182, 156), (176, 124))} Z")
# soft shade where the face mask meets the chest + under each flipper root
CHEST_SH = f"M{P((126, 130))} C{P((140, 144), (162, 144), (176, 130))} C{P((162, 139), (140, 139), (126, 130))} Z"
FEET = (f'  <ellipse cx="124" cy="228" rx="11" ry="5.5" fill="{BEAK}" stroke="{O}" stroke-width="4.5"/>\n'
        f'  <ellipse cx="187" cy="228" rx="11" ry="5.5" fill="{BEAK}" stroke="{O}" stroke-width="4.5"/>\n'
        f'  <path d="M184 229.5 L183 232.5 M190 229.5 L190.5 232.5" stroke="{O}" stroke-width="2.5" {SW}/>')


def body_layer():
    return "\n".join([
        f'  <path d="{BODY_D}" fill="{BACK}"/>',
        f'  <path d="{FLANK_SH}" fill="{BACK_SH}"/>',
        f'  <path d="{BELLY_D}" fill="{BELLY}"/>',
        f'  <path d="{BELLY_SH_D} {CHEST_SH}" fill="{BELLY_SH}"/>',
        f'  <path d="{BODY_D}" fill="none" stroke="{O}" stroke-width="5" {SW}/>',
        FEET,
    ])


# ---- head (moves as one group in sleep/wake) --------------------------------------------------
MASK_D = (f"M{P((144, 74))} C{P((137, 58), (117, 55), (108, 65))} "
          f"C{P((100, 73), (98, 90), (102, 102))} C{P((106, 114), (114, 122), (124, 130))} "
          f"L{P((174, 130))} C{P((184, 121), (191, 110), (192, 98))} "
          f"C{P((193, 84), (188, 68), (179, 63))} C{P((169, 56), (151, 58), (144, 74))} Z")
a0, a1 = ell(-60), ell(32)
HEAD_SH = (f"M{P(a0)} A{RX} {RY} 0 0 1 {P(a1)} "
           f"C{P((196, 96), (199, 70), (186, 46))} Z")
h0, h1 = ell(200, 47, 37), ell(246, 47, 37)
HILITE = f"M{P(h0)} A47 37 0 0 1 {P(h1)}"
HEAD_LINE = f"M{P(JL)} A{RX} {RY} 0 1 1 {P(JR)}"


def eyes(kind):
    if kind == "content":
        return f'  <path d="M115 84 Q122.5 85.5 130 84 M158 82 Q165.5 83.5 173 82" fill="none" stroke="{O}" stroke-width="4.5" {SW}/>'
    if kind == "happy":
        return f'  <path d="M115 87 Q122 78 129 87 M158 85 Q165 76 172 85" fill="none" stroke="{O}" stroke-width="4.5" {SW}/>'
    if kind == "sleepy":
        return f'  <path d="M115 82 Q122 89 129 82 M158 80 Q165 87 172 80" fill="none" stroke="{O}" stroke-width="4.5" {SW}/>'
    if kind == "open":
        return (f'  <ellipse cx="122" cy="84" rx="3.6" ry="4.6" fill="{O}"/>\n'
                f'  <ellipse cx="165" cy="82" rx="3.6" ry="4.6" fill="{O}"/>\n'
                f'  <path d="M120.8 82.2 h0 M163.8 80.2 h0" stroke="{WHITE}" stroke-width="2.8" stroke-linecap="round"/>')
    if kind == "wake":
        return (f'  <ellipse cx="122" cy="84" rx="3.6" ry="4.6" fill="{O}"/>\n'
                f'  <path d="M120.8 82.2 h0" stroke="{WHITE}" stroke-width="2.8" stroke-linecap="round"/>\n'
                f'  <path d="M158 80 Q165 87 172 80" fill="none" stroke="{O}" stroke-width="4.5" {SW}/>')
    raise ValueError(kind)


def beak(kind):
    if kind == "open":
        return "\n".join([
            f'  <path d="M137.5 96 Q143.5 99 149.5 96 Q148.5 107 143 107.5 Q138 107 137.5 96 Z" fill="{HATCH}" stroke="{O}" stroke-width="3.5" {SW}/>',
            f'  <path d="M135 92 Q143 88.5 151 92 Q148 98.5 143 99.5 Q138 98.5 135 92 Z" fill="{BEAK}" stroke="{O}" stroke-width="3.5" {SW}/>',
        ])
    return f'  <path d="M135.5 92.5 Q143 89 150.5 92.5 Q147.5 101.5 143 102.5 Q138.5 101.5 135.5 92.5 Z" fill="{BEAK}" stroke="{O}" stroke-width="3.5" {SW}/>'


BLUSH_SVG = (f'  <ellipse cx="110" cy="99" rx="8" ry="4.5" fill="{BLUSH}"/>\n'
             f'  <ellipse cx="177" cy="97" rx="8" ry="4.5" fill="{BLUSH}"/>\n'
             f'  <path d="M106 101 L108 97 M109.5 101.5 L111.5 97.5 M113 101 L115 97 '
             f'M173 99 L175 95 M176.5 99.5 L178.5 95.5 M180 99 L182 95" stroke="{HATCH}" stroke-width="1.6" stroke-linecap="round"/>')


def head_layer(eye, mouth="closed"):
    return "\n".join([
        f'  <ellipse cx="{HX}" cy="{HY}" rx="{RX}" ry="{RY}" fill="{BACK}"/>',
        f'  <path d="{HEAD_SH}" fill="{BACK_SH}"/>',
        f'  <path d="{HILITE}" fill="none" stroke="{RIM}" stroke-width="5" stroke-linecap="round"/>',
        f'  <path d="{MASK_D}" fill="{BELLY}"/>',
        f'  <path d="{HEAD_LINE}" fill="none" stroke="{O}" stroke-width="5" {SW}/>',
        f'  <path d="M147 36.5 Q143 29 149 26 M154 36 Q156 30 162 30" fill="none" stroke="{O}" stroke-width="3.5" stroke-linecap="round"/>',
        BLUSH_SVG,
        eyes(eye),
        beak(mouth),
    ])


FRAME_FACES = {
    "idle": ("content", "closed"), "peek": ("open", "closed"),
    "type_left": ("content", "closed"), "type_right": ("content", "closed"), "type_both": ("content", "closed"),
    "excited": ("happy", "open"), "sleep": ("sleepy", "closed"), "wake": ("wake", "closed"),
    "hold": ("content", "closed"), "sip": ("happy", "closed"),
}


def frame(name):
    eye, mouth = FRAME_FACES[name]
    head = head_layer(eye, mouth)
    if name in ("sleep", "wake"):
        head = f'  <g transform="{SLEEP_T}">\n' + head.replace("\n  ", "\n    ").replace("  <", "    <", 1) + "\n  </g>"
    return svg(body_layer() + "\n" + head, f"typebud penguin, {name}: body + head + face (no flippers).")


# ---- flippers -----------------------------------------------------------------------------------
L_ROOT = ((96, 110), (124, 114))      # outer (on the body edge), inner
R_ROOT = ((208, 114), (182, 118))
REST = {"L": (122, 168), "R": (160, 180)}


def flipper_arm(side, p, mode):
    """Open-topped forearm from the shoulder root to the flipper tip at p."""
    px, py = p
    if side == "L":
        (ox, oy), (ix, iy) = L_ROOT
        if mode == "hug":
            outer = f"M{P((ox, oy))} C{P((94, 136), (116, 160), (px - 6, py + 9))}"
            inner = f"M{P((px + 2, py - 9))} C{P((134, 142), (124, 132), (ix, iy))}"
        elif mode == "sip":
            outer = f"M{P((ox, oy))} C{P((96, 128), (110, 140), (px - 4, py + 10))}"
            inner = f"M{P((px + 2, py - 9))} C{P((128, 118), (124, 116), (ix, iy))}"
        else:
            outer = f"M{P((ox, oy))} C{P((ox - 9, oy + 22), (px - 22, py - 12), (px - 12, py + 3))}"
            inner = f"M{P((px + 11, py - 2))} C{P((px + 6, py - 16), (ix + 4, iy + 18), (ix, iy))}"
    else:
        (ox, oy), (ix, iy) = R_ROOT
        if mode == "hug":
            outer = f"M{P((ox, oy))} C{P((210, 136), (204, 152), (px + 6, py + 9))}"
            inner = f"M{P((px - 3, py - 8))} C{P((188, 136), (188, 128), (ix, iy))}"
        elif mode == "sip":
            outer = f"M{P((ox, oy))} C{P((210, 130), (196, 136), (px + 5, py + 9))}"
            inner = f"M{P((px - 2, py - 9))} C{P((178, 114), (182, 114), (ix, iy))}"
        else:
            outer = f"M{P((ox, oy))} C{P((ox + 7, oy + 26), (px + 26, py - 10), (px + 11, py + 5))}"
            inner = f"M{P((px - 12, py - 1))} C{P((px - 8, py - 18), (ix - 4, iy + 18), (ix, iy))}"
    fill = outer + " L" + inner.split("M", 1)[1] + " Z"
    return fill, outer + " " + inner


def tip(p, rx, ry, rot, hl=True):
    cx, cy = p
    tr = f' transform="rotate({f(rot)} {f(cx)} {f(cy)})"' if rot else ""
    out = f'  <ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}"{tr} fill="{BACK}" stroke="{O}" stroke-width="4.5"/>'
    if hl:
        out += (f'\n  <path d="M{f(cx - rx * 0.55)} {f(cy - ry * 0.15)} Q{f(cx - rx * 0.35)} {f(cy - ry * 0.55)} {f(cx + rx * 0.05)} {f(cy - ry * 0.55)}"'
                f'{tr} fill="none" stroke="{RIM}" stroke-width="2.5" stroke-linecap="round"/>')
    return out


def paws(state):
    L, R = REST["L"], REST["R"]
    spec = {}   # side -> (center, rx, ry, rot, mode)
    rest = lambda p: (p, 13, 9.2, 14, "type")
    pressed = lambda p: ((p[0], p[1] + 3), 13.6, 7.8, 14, "type")
    raised = lambda p: ((p[0] + 2, p[1] - 10), 13, 9.2, 0, "type")
    if state in ("idle", "sleep"):
        spec = {"L": rest(L), "R": rest(R)}
    elif state == "type_left":
        spec = {"L": pressed(L), "R": raised(R)}
    elif state == "type_right":
        spec = {"L": raised(L), "R": pressed(R)}
    elif state == "type_both":
        spec = {"L": pressed(L), "R": pressed(R)}
    elif state == "excited":
        spec = {"L": ((L[0] - 1, L[1] - 12), 13, 9, -16, "type"), "R": ((R[0] + 1, R[1] - 12), 13, 9, 30, "type")}
    elif state == "hold":
        spec = {"L": ((148, 152), 11, 9, -20, "hug"), "R": ((182, 146), 10, 9, 20, "hug")}
    elif state == "sip":
        spec = {"L": ((138, 140), 11, 9, -30, "sip"), "R": ((165, 131), 10, 9, 30, "sip")}
    parts = []
    for side in ("L", "R"):
        c, rx, ry, rot, mode = spec[side]
        fill, line = flipper_arm(side, c, mode)
        parts.append(f'  <path d="{fill}" fill="{BACK}"/>')
        parts.append(f'  <path d="{line}" fill="none" stroke="{O}" stroke-width="5" {SW}/>')
        parts.append(tip(c, rx, ry, rot))
    return svg("\n".join(parts), f"typebud penguin, {state} flippers (drawn after the keyboard).")


# ---- headphones -----------------------------------------------------------------------------------
HP_DEFS = """
    <linearGradient id="hp-ring" gradientUnits="userSpaceOnUse" x1="0" y1="70" x2="0" y2="104">
      <stop offset="0" stop-color="#4FC3F7"/>
      <stop offset="0.25" stop-color="#7C6CFF"/>
      <stop offset="0.45" stop-color="#E86BD8"/>
      <stop offset="0.62" stop-color="#FF5C6C"/>
      <stop offset="0.8" stop-color="#FFE45C"/>
      <stop offset="1" stop-color="#5EE08A"/>
    </linearGradient>"""


def headphones_body():
    band = "M92 72 C90 21 212 17 205 68"
    return "\n".join([
        f'    <path d="M99 62 C87 61 82 73 82 83 C82 93 87 103 100 100 C96 93 95 87 95 81 C95 74 96 68 99 62 Z" fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5" stroke-linejoin="round"/>',
        f'    <path d="{band}" fill="none" stroke="{G_LINE}" stroke-width="14" stroke-linecap="round"/>',
        f'    <path d="{band}" fill="none" stroke="{HP_BAND}" stroke-width="6.5" stroke-linecap="round"/>',
        f'    <path d="M106 42 C124 30 150 26 172 30" fill="none" stroke="{HP_CUP}" stroke-width="2.5" stroke-linecap="round"/>',
        f'    <ellipse cx="199" cy="86" rx="11" ry="22" fill="{HP_SH}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'    <ellipse cx="209" cy="87" rx="13" ry="22" fill="{HP_CUP}" stroke="{G_LINE}" stroke-width="4.5"/>',
        f'    <ellipse cx="211" cy="87" rx="6.5" ry="14" fill="{HP_GLOW}" stroke="url(#hp-ring)" stroke-width="3.5"/>',
        f'    <ellipse cx="212" cy="87" rx="3" ry="8.5" fill="{HP_CUP}"/>',
    ])


# ---- other head items (fixed literal colors) ---------------------------------------------------------
def beanie_body():
    knit, knit_sh, cuff = "#E9806E", "#CC6656", "#F2A08F"
    dome = "M98 66 C94 34 132 27 154 28 C186 29 210 42 206 64 Z"
    dome_sh = "M178 30 C198 38 208 50 206 64 L190 62 C192 50 188 40 178 30 Z"
    cuff_d = "M93 61 Q150 44 211 57 Q214 66 212 74 Q150 60 94 78 Q90 70 93 61 Z"
    ribs = " ".join(f"M{x} {f(y0)} L{x - 1} {f(y0 + 12)}" for x, y0 in
                    [(106, 59), (118, 56), (130, 53.5), (142, 52), (154, 51.5), (166, 52), (178, 53.5), (190, 55.5), (201, 58)])
    return "\n".join([
        f'    <path d="{dome}" fill="{knit}"/>',
        f'    <path d="{dome_sh}" fill="{knit_sh}"/>',
        f'    <path d="M120 40 Q122 50 120 58 M140 33 Q142 44 141 54 M162 33 Q164 44 164 53 M182 38 Q184 48 185 56" fill="none" stroke="{knit_sh}" stroke-width="2.5" stroke-linecap="round"/>',
        f'    <path d="{dome}" fill="none" stroke="{O}" stroke-width="5" {SW}/>',
        f'    <path d="{cuff_d}" fill="{cuff}" stroke="{O}" stroke-width="4.5" {SW}/>',
        f'    <path d="{ribs}" stroke="#D98374" stroke-width="2.5" stroke-linecap="round"/>',
        f'    <circle cx="128" cy="35" r="6.5" fill="#FFF8EE" stroke="{O}" stroke-width="3.5"/>',
    ])


def party_hat_body():
    cone, cone_sh, stripe = "#8FD3F4", "#68B6DE", "#F497B4"
    B1, B2, A = (111, 50), (147, 37), (101, 32)     # base ends on the head's upper left, apex leaning left
    lerp = lambda p, q, t: (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)
    bot = (131, 50)                                  # control point: base bulges down (round brim)
    cone_d = f"M{P(B1)} L{P(lerp(B1, A, 0.92))} Q{P(A, lerp(B2, A, 0.92))} L{P(B2)} Q{P(bot, B1)} Z"
    sh = f"M{P(lerp(B2, A, 0.15))} L{P(lerp(B2, A, 0.85))} L{P(lerp(lerp(B1, B2, 0.6), A, 0.82))} L{P(lerp(B1, B2, 0.72))} Z"
    stripes = ""
    for t in (0.22, 0.55):
        p, q = lerp(B1, A, t), lerp(B2, A, t)
        c = lerp(lerp(B1, bot, 1), A, t)
        stripes += f"M{P(p)} Q{P(c, q)} "
    return "\n".join([
        f'    <path d="{cone_d}" fill="{cone}"/>',
        f'    <path d="{sh}" fill="{cone_sh}"/>',
        f'    <path d="{stripes}" fill="none" stroke="{stripe}" stroke-width="6" stroke-linecap="round"/>',
        f'    <path d="{cone_d}" fill="none" stroke="{O}" stroke-width="4.5" {SW}/>',
        f'    <circle cx="{A[0]}" cy="{A[1]}" r="5" fill="{CREAM}" stroke="{O}" stroke-width="3.5"/>',
    ])


def bow_body():
    pink, pink_sh = "#F497B4", "#DE7A9C"
    cx, cy = 180, 42
    left = f"M{cx} {cy} C{cx - 6} {cy - 10} {cx - 20} {cy - 14} {cx - 22} {cy - 6} C{cx - 24} {cy + 2} {cx - 18} {cy + 12} {cx} {cy + 3} Z"
    right = f"M{cx} {cy} C{cx + 6} {cy - 12} {cx + 20} {cy - 14} {cx + 22} {cy - 4} C{cx + 23} {cy + 6} {cx + 14} {cy + 12} {cx} {cy + 3} Z"
    tails = f"M{cx - 3} {cy + 4} L{cx - 10} {cy + 16} L{cx - 3} {cy + 15} Z M{cx + 3} {cy + 4} L{cx + 11} {cy + 15} L{cx + 4} {cy + 16} Z"
    return "\n".join([
        f'    <path d="{tails}" fill="{pink_sh}" stroke="{O}" stroke-width="3.5" {SW}/>',
        f'    <path d="{left}" fill="{pink}" stroke="{O}" stroke-width="4.5" {SW}/>',
        f'    <path d="{right}" fill="{pink}" stroke="{O}" stroke-width="4.5" {SW}/>',
        f'    <path d="M{cx + 6} {cy - 2} C{cx + 12} {cy - 6} {cx + 16} {cy - 4} {cx + 16} {cy + 2} M{cx - 6} {cy - 1} C{cx - 12} {cy - 5} {cx - 16} {cy - 3} {cx - 16} {cy + 2}" fill="none" stroke="{pink_sh}" stroke-width="3" stroke-linecap="round"/>',
        f'    <ellipse cx="{cx}" cy="{cy + 1.5}" rx="5.5" ry="6" fill="{pink_sh}" stroke="{O}" stroke-width="3.5"/>',
    ])


def glasses_body():
    frame_c = "#D9614C"
    rims = ("M109 84 a13 12 0 1 0 26 0 a13 12 0 1 0 -26 0 "
            "M153 82 a13 12 0 1 0 26 0 a13 12 0 1 0 -26 0")
    bridge = "M135 83 Q144 78 153 82"
    arm = "M179 80 L200 76"
    lines = f"{rims} {bridge} {arm}"
    return "\n".join([
        f'    <path d="{rims}" fill="#DFF3FF" fill-opacity="0.35"/>',
        f'    <path d="{lines}" fill="none" stroke="{O}" stroke-width="7" {SW}/>',
        f'    <path d="{lines}" fill="none" stroke="{frame_c}" stroke-width="3" {SW}/>',
        f'    <path d="M113 79 Q115 75 119 74 M157 77 Q159 73 163 72" fill="none" stroke="{WHITE}" stroke-width="2.5" stroke-linecap="round"/>',
    ])


HEAD_ITEMS = {
    "headphones": (headphones_body, HP_DEFS),
    "beanie": (beanie_body, ""),
    "party_hat": (party_hat_body, ""),
    "bow": (bow_body, ""),
    "glasses": (glasses_body, ""),
}


def head_item(name, sleep):
    fn, defs = HEAD_ITEMS[name]
    t = f' transform="{SLEEP_T}"' if sleep else ""
    note = " Sleep: same drawing in the sleep head transform." if sleep else ""
    return svg(f"  <g{t}>\n{fn()}\n  </g>", f"typebud penguin {name}, fitted to the penguin head (center 152,80; rx 57, ry 46).{note}", defs)


# ---- held items: shared drawings, penguin positions ------------------------------------------------
SHARED = OUT.parent / "_shared"
HOLD_T = {"hold_coffee": "translate(164 140) rotate(10)", "hold_boba": "translate(164 140) rotate(10)",
          "hold_book": "translate(164 140) rotate(-8)"}
SIP_T = {"hold_coffee": "translate(148 126) rotate(-20)", "hold_boba": "translate(148 136) rotate(-20)",
         "hold_book": "translate(154 134) rotate(-12)"}


def held(name, t):
    src = (SHARED / f"{name}.svg").read_text()
    start = src.index("<g transform=\"")
    end = src.index("\"", start + 14)
    return src[:start] + f'<g transform="{t}"' + src[end + 1:]


# ---- icons ---------------------------------------------------------------------------------------------
IC = dict(cx=128, cy=134, rx=103, ry=92)
IC_MASK = ("M126 114 C114 86 80 82 62 98 C46 114 42 142 50 166 C60 196 94 211 127 211 "
           "C160 211 196 196 206 166 C214 142 210 112 194 96 C176 80 138 86 126 114 Z")
IC_EYES = ((74, 138, 102, 138), (152, 135, 180, 135))
IC_BEAK = "M106 156 Q127 145 148 156 Q141 180 127 184 Q113 180 106 156 Z"
IC_BEAK_BIG = "M100 154 Q127 139 154 154 Q145 188 127 191 Q109 188 100 154 Z"   # beak + its outline, for the template


def icon():
    cx, cy, rx, ry = IC["cx"], IC["cy"], IC["rx"], IC["ry"]
    s0, s1 = ell(-58, rx, ry, cx, cy), ell(40, rx, ry, cx, cy)
    h0, h1 = ell(198, rx - 18, ry - 18, cx, cy), ell(240, rx - 18, ry - 18, cx, cy)
    eyes = " ".join(f"M{x0} {y0} Q{(x0 + x1) / 2:g} {y0 + 4} {x1} {y1}" for x0, y0, x1, y1 in IC_EYES)
    body = "\n".join([
        f'  <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{BACK}"/>',
        f'  <path d="M{P(s0)} A{rx} {ry} 0 0 1 {P(s1)} C{P((222, 150), (222, 96), (196, 60))} Z" fill="{BACK_SH}"/>',
        f'  <path d="M{P(h0)} A{rx - 18} {ry - 18} 0 0 1 {P(h1)}" fill="none" stroke="{RIM}" stroke-width="12" stroke-linecap="round"/>',
        f'  <path d="{IC_MASK}" fill="{BELLY}"/>',
        f'  <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="none" stroke="{O}" stroke-width="16"/>',
        f'  <ellipse cx="62" cy="166" rx="16" ry="10" fill="{BLUSH}"/>',
        f'  <ellipse cx="193" cy="162" rx="16" ry="10" fill="{BLUSH}"/>',
        f'  <path d="{eyes}" fill="none" stroke="{O}" stroke-width="18" {SW}/>',
        f'  <path d="{IC_BEAK}" fill="{BEAK}" stroke="{O}" stroke-width="12" {SW}/>',
    ])
    return svg(body, "typebud penguin icon: face only (slate cap, heart face mask, beak), reads at 16 px.")


def capsule(x0, y0, x1, y1, r):
    """Closed path for a thick line from (x0,y0) to (x1,y1) with round ends (radius r)."""
    a = math.atan2(y1 - y0, x1 - x0)
    nx, ny = -math.sin(a) * r, math.cos(a) * r
    return (f"M{f(x0 + nx)} {f(y0 + ny)} L{f(x1 + nx)} {f(y1 + ny)} A{f(r)} {f(r)} 0 0 0 {f(x1 - nx)} {f(y1 - ny)} "
            f"L{f(x0 - nx)} {f(y0 - ny)} A{f(r)} {f(r)} 0 0 0 {f(x0 + nx)} {f(y0 + ny)} Z")


def icon_template():
    cx, cy = IC["cx"], IC["cy"]
    rx, ry = IC["rx"] + 8, IC["ry"] + 8
    outer = f"M{cx - rx} {cy} A{rx} {ry} 0 1 0 {cx + rx} {cy} A{rx} {ry} 0 1 0 {cx - rx} {cy} Z"
    eyes = " ".join(capsule(x0, y0 + 1, x1, y1 + 1, 9) for x0, y0, x1, y1 in IC_EYES)
    # even-odd: head (solid) > face mask (hole) > eyes + beak (solid again)
    d = f"{outer} {IC_MASK} {eyes} {IC_BEAK_BIG}"
    return svg(f'  <path d="{d}" fill="#000000" fill-rule="evenodd"/>',
               "typebud penguin tray template: black head, face mask cut out, eyes and beak solid inside it.")


# ---- main ----------------------------------------------------------------------------------------------
def main():
    for name in FRAME_FACES:
        write(name, frame(name))
    for st in ("idle", "type_left", "type_right", "type_both", "excited", "sleep", "hold", "sip"):
        write(f"{st}_paws", paws(st))
    for item in HEAD_ITEMS:
        write(f"acc/{item}", head_item(item, False))
        write(f"acc/{item}_sleep", head_item(item, True))
    for item in HOLD_T:
        write(f"acc/{item}", held(item, HOLD_T[item]))
        write(f"acc/{item}_sip", held(item, SIP_T[item]))
    write("icon", icon())
    write("icon_template", icon_template())


if __name__ == "__main__":
    main()
