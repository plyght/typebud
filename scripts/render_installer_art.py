#!/usr/bin/env python3
"""Render the installer artwork from typebud's layered SVG art (bright theme).

usage: scripts/render_installer_art.py [--out-preview DIR]

Writes (committed; re-run after changing art/ or this script):
  packaging/windows/wizard-large-<pct>.bmp   Inno Setup WizardImageFile (welcome/finish pages)
  packaging/windows/wizard-small-<pct>.bmp   Inno Setup WizardSmallImageFile (inner-page header)
  packaging/macos/dmg-background.png         DMG window background, 660x400 pt
  packaging/macos/dmg-background@2x.png      the same at 1320x800 px

Sizes follow the Inno Setup 6 docs for 100/125/150/175/200/225/250 % DPI.
Needs: pip install cairosvg pillow freetype-py
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_art as ra  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
FONT = REPO / "assets/fonts/Nunito-ExtraBold.ttf"
WIN = REPO / "packaging/windows"
MAC = REPO / "packaging/macos"

# The app icon's own gradient (packaging/icons): cream -> blush.
CREAM = (255, 244, 228)
BLUSH = (255, 225, 234)
LILAC = (238, 230, 255)
INK = (92, 62, 48)          # warm brown, matches the art's outlines
INK_SOFT = (150, 118, 104)
ACCENT = (242, 143, 152)    # cat "feature" pink

LARGE = {100: (164, 314), 125: (192, 386), 150: (246, 459), 175: (273, 556),
         200: (328, 628), 225: (355, 697), 250: (410, 797)}
SMALL = {100: (55, 55), 125: (64, 68), 150: (83, 80), 175: (92, 97),
         200: (110, 106), 225: (119, 123), 250: (138, 140)}


def sprite(animal: str, frame: str, size: int, theme: str = "bright", **kw) -> Image.Image:
    """One animal frame (with keyboard etc.) on a transparent background."""
    a = ra.Animal(animal)
    cmap = ra.color_map(theme, a.fur)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for n in a.layers(frame, **kw):
        p = a.find(n)
        if not p:
            continue
        out.alpha_composite(ra.raster(p, cmap, size, a.transform_for(n, p)))
        if n == "acc/keyboard" and p.parent == ra.SHARED:
            kb = a.anchors.get("keyboard", {})
            out.alpha_composite(ra.legends(size, theme, (*kb.get("translate", [0, 0]), kb.get("scale", 1.0))))
    return out


def icon(size: int) -> Image.Image:
    a = ra.Animal("cat")
    return ra.raster(ra.ROOT / "cat/icon.svg", ra.color_map("bright", a.fur), size)


def gradient(w: int, h: int, stops, vertical=True) -> Image.Image:
    """Multi-stop linear gradient; stops = [(pos 0..1, rgb), ...]."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    n = h if vertical else w
    line = []
    for i in range(n):
        t = i / max(1, n - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                u = (t - p0) / max(1e-6, p1 - p0)
                u = u * u * (3 - 2 * u)
                line.append(tuple(round(c0[k] + (c1[k] - c0[k]) * u) for k in range(3)))
                break
    for i, c in enumerate(line):
        if vertical:
            for x in range(w):
                px[x, i] = c
        else:
            for y in range(h):
                px[i, y] = c
    return img.convert("RGBA")


def soft_ellipse(base: Image.Image, box, color, alpha, blur):
    """A blurred ellipse of one solid color (blur the mask only, so edges never darken)."""
    mask = Image.new("L", base.size, 0)
    ImageDraw.Draw(mask).ellipse(box, fill=alpha)
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", base.size, color + (0,))
    layer.putalpha(mask)
    base.alpha_composite(layer)


def glow(base: Image.Image, cx, cy, r, color, alpha):
    soft_ellipse(base, (cx - r, cy - r, cx + r, cy + r), color, alpha, r * 0.45)


def shadow_under(base: Image.Image, cx, cy, rx, ry, alpha=60):
    soft_ellipse(base, (cx - rx, cy - ry, cx + rx, cy + ry), (196, 120, 140), alpha, max(1, ry * 0.6))


def sparkle(d: ImageDraw.ImageDraw, cx, cy, r, color):
    """Four-point twinkle."""
    pts = []
    import math
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    d.polygon(pts, fill=color)


def text_center(d, cx, y, s, font, fill):
    w = d.textlength(s, font=font)
    d.text((cx - w / 2, y), s, font=font, fill=fill)


def to_bmp(img: Image.Image, path: Path):
    img.convert("RGB").save(path, format="BMP")


# ---------------------------------------------------------------- Windows wizard

def wizard_large(w: int, h: int) -> Image.Image:
    k = w / 164
    img = gradient(w, h, [(0, CREAM), (0.55, BLUSH), (1, LILAC)])
    glow(img, w * 0.5, h * 0.62, 90 * k, (255, 255, 255), 150)
    glow(img, w * 0.15, h * 0.1, 50 * k, (255, 255, 255), 120)
    d = ImageDraw.Draw(img)
    for (fx, fy, fr, col) in [(0.16, 0.35, 5, ACCENT), (0.84, 0.30, 6, (255, 196, 120)),
                               (0.80, 0.45, 3.5, (180, 160, 240)), (0.22, 0.52, 3, (255, 196, 120)),
                               (0.88, 0.08, 3, ACCENT)]:
        sparkle(d, w * fx, h * fy, fr * k, col + (255,))
    # wordmark
    f = ImageFont.truetype(str(FONT), round(30 * k))
    text_center(d, w / 2, 26 * k, "typebud", f, INK)
    f2 = ImageFont.truetype(str(FONT), round(10.5 * k))
    text_center(d, w / 2, 62 * k, "a cozy pet that types", f2, INK_SOFT)
    text_center(d, w / 2, 76 * k, "along with you", f2, INK_SOFT)
    # the cat, waving hello at its keyboard
    s = round(168 * k)
    cat = sprite("cat", "excited", s, head="headphones", sparkles=False)
    cx, top = w / 2 - 4 * k, h - s - 14 * k
    shadow_under(img, cx, top + s * 0.86, s * 0.36, s * 0.05, 70)
    img.alpha_composite(cat, (round(cx - s / 2), round(top)))
    return img


def wizard_small(w: int, h: int) -> Image.Image:
    img = Image.new("RGBA", (w, h), (255, 255, 255, 255))
    s = min(w, h)
    pad = round(s * 0.04)
    tile = gradient(s - 2 * pad, s - 2 * pad, [(0, CREAM), (1, BLUSH)])
    mask = Image.new("L", tile.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, tile.width - 1, tile.height - 1), radius=round(tile.width * 0.24), fill=255)
    x0, y0 = (w - tile.width) // 2, (h - tile.height) // 2
    img.paste(tile, (x0, y0), mask)
    ic = icon(round(tile.width * 0.92))
    img.alpha_composite(ic, (x0 + (tile.width - ic.width) // 2, y0 + (tile.height - ic.height) // 2 + round(s * 0.02)))
    return img


# ---------------------------------------------------------------- macOS DMG

# Finder coordinates (points) shared with scripts/make-dmg.sh.
DMG_W, DMG_H = 660, 400
APP_X, APPS_X, ICON_Y = 180, 480, 190


def arrow(img: Image.Image, k: float):
    """A dotted arc from the app slot to Applications, ending in a rounded arrowhead."""
    import math
    ss = 4  # supersample for smooth dots
    layer = Image.new("RGBA", (img.width * ss, img.height * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    K = k * ss
    p0 = ((APP_X + 84) * K, (ICON_Y + 2) * K)
    p2 = ((APPS_X - 92) * K, (ICON_Y + 2) * K)
    p1 = ((p0[0] + p2[0]) / 2, (ICON_Y - 52) * K)
    col = (236, 140, 156, 235)

    def q(t):
        u = 1 - t
        return (u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1])

    n = 9
    for i in range(n):
        t = i / n * 0.97
        x, y = q(t)
        r = (2.4 + 1.6 * i / n) * K
        d.ellipse((x - r, y - r, x + r, y + r), fill=col)
    # head: tangent at t=1
    ex, ey = p2
    tx, ty = 2 * (p2[0] - p1[0]), 2 * (p2[1] - p1[1])
    ang = math.atan2(ty, tx)
    L, W = 15 * K, 9 * K
    c, s_ = math.cos(ang), math.sin(ang)
    tip = (ex + c * L * 0.55, ey + s_ * L * 0.55)
    base = (ex - c * L * 0.45, ey - s_ * L * 0.45)
    left = (base[0] - s_ * W, base[1] + c * W)
    right = (base[0] + s_ * W, base[1] - c * W)
    d.polygon([tip, left, right], fill=col)
    d.line([left, tip, right], fill=col, width=round(4 * K), joint="curve")
    for pt in (tip, left, right):
        r = 2 * K
        d.ellipse((pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r), fill=col)
    img.alpha_composite(layer.resize(img.size, Image.LANCZOS))


def dmg_background(scale: int) -> Image.Image:
    k = scale
    w, h = DMG_W * k, DMG_H * k
    img = gradient(w, h, [(0, CREAM), (0.5, (255, 235, 236)), (1, LILAC)], vertical=False)
    # gentle vertical wash so the bottom feels grounded
    wash = gradient(w, h, [(0, (255, 255, 255)), (1, (250, 226, 236))])
    wash.putalpha(90)
    img.alpha_composite(wash)
    glow(img, APP_X * k, ICON_Y * k, 95 * k, (255, 255, 255), 170)
    glow(img, APPS_X * k, ICON_Y * k, 95 * k, (255, 255, 255), 170)
    d = ImageDraw.Draw(img)
    # caption
    f = ImageFont.truetype(str(FONT), 27 * k)
    text_center(d, w / 2, 34 * k, "Drag typebud to Applications", f, INK)
    f3 = ImageFont.truetype(str(FONT), round(12 * k))
    text_center(d, w / 2, 74 * k, "First launch: right-click Typebud and choose Open", f3, INK_SOFT)
    for (fx, fy, fr, col) in [(0.085, 0.13, 7, ACCENT), (0.92, 0.12, 6, (255, 190, 110)),
                               (0.955, 0.24, 3.5, (175, 155, 240)), (0.05, 0.27, 3.5, (255, 190, 110)),
                               (0.5, 0.31, 4, (175, 155, 240))]:
        sparkle(d, w * fx, h * fy, fr * k, col + (255,))
    arrow(img, k)
    # the gang along the bottom edge: everyone at their keyboard, cat front and centre
    gang = [("penguin", "type_left", 92, 0.075), ("shiba", "type_right", 104, 0.20),
            ("cat", "excited", 136, 0.5), ("capybara", "type_both", 104, 0.80), ("penguin", "sleep", 0, 0)]
    gang = [g for g in gang if g[2]]
    for animal, frame, size, fx in sorted(gang, key=lambda g: g[2]):
        s = size * k
        spr = sprite(animal, frame, s, head="headphones" if animal == "cat" else None)
        cx = w * fx
        bottom = h + 6 * k
        shadow_under(img, cx, bottom - s * 0.2, s * 0.34, s * 0.045, 55)
        img.alpha_composite(spr, (round(cx - s / 2), round(bottom - s)))
    return img


def dmg(scale: int) -> Image.Image:
    return dmg_background(scale)


def main():
    WIN.mkdir(parents=True, exist_ok=True)
    MAC.mkdir(parents=True, exist_ok=True)
    preview = None
    if "--out-preview" in sys.argv:
        preview = Path(sys.argv[sys.argv.index("--out-preview") + 1])
        preview.mkdir(parents=True, exist_ok=True)
    for pct, (w, h) in LARGE.items():
        im = wizard_large(w, h)
        to_bmp(im, WIN / f"wizard-large-{pct}.bmp")
        if preview:
            im.save(preview / f"wizard-large-{pct}.png")
    for pct, (w, h) in SMALL.items():
        im = wizard_small(w, h)
        to_bmp(im, WIN / f"wizard-small-{pct}.bmp")
        if preview:
            im.save(preview / f"wizard-small-{pct}.png")
    one, two = dmg(1), dmg(2)
    one.convert("RGB").save(MAC / "dmg-background.png", dpi=(72, 72))
    two.convert("RGB").save(MAC / "dmg-background@2x.png", dpi=(144, 144))
    if preview:
        two.save(preview / "dmg-background@2x.png")
    print("wrote", WIN / "wizard-*.bmp", MAC / "dmg-background{,@2x}.png")


if __name__ == "__main__":
    main()
