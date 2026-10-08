#!/usr/bin/env python3
"""Render typebud's layered SVG art to PNG previews, stacked the way the app stacks it (art/SPEC.md).

usage: scripts/render_art.py [<animal> ...]   every folder in art/ except _shared when none given
       scripts/render_art.py --shared         the shared layers + reference pose, all three themes

Colors: gear tokens (keyboard, headphones, cup sleeve) come from art/_shared/themes.json per theme;
fur tokens come from art/<animal>/palette.json and are the same in every theme.
Layers: an animal's acc/<name>.svg wins; otherwise art/_shared/<name>.svg is used.

Writes art/<animal>/preview/:
  sheet.png        every frame with keyboard + paws, one row per theme (+ idle at 96/512 px)
  accessories.png  frames with each accessory turned on, bright theme
  icon*_16x.png    the tray icons at 16 px, upscaled for inspection
and for --shared, art/_shared/preview/sheet.png.
Needs: pip install cairosvg pillow
"""
import io
import json
import re
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent / "art"
SHARED = ROOT / "_shared"
THEME_FILE = json.loads((SHARED / "themes.json").read_text())
PLACEHOLDERS = {k: v.upper() for k, v in THEME_FILE["placeholders"].items()}
THEMES = list(THEME_FILE["themes"])                      # dark, bright, pink

FRAMES = ["idle", "peek", "type_left", "type_right", "type_both", "excited", "sleep", "wake", "hold", "sip"]
PAWS_FALLBACK = {"peek": "idle", "wake": "sleep"}         # these frames may reuse another frame's paws
TYPING = {"type_left", "type_right", "type_both", "excited"}
SLEEPY = {"sleep", "wake"}
ICONS = ["icon", "icon_template"]
HEAD = ["headphones", "beanie", "party_hat", "bow", "glasses"]
HOLD = ["hold_coffee", "hold_boba", "hold_book"]
DESK = ["desk_lamp", "desk_plant", "desk_mug"]
BACKDROPS = {"dark": (30, 30, 36), "bright": (245, 245, 240), "pink": (255, 228, 236)}
SIZE = 256
HEX = re.compile(r"#[0-9A-Fa-f]{6}\b")


def color_map(theme: str, fur: dict) -> dict:
    """placeholder hex -> real hex for one theme: gear from themes.json, fur from the animal palette."""
    real = dict(THEME_FILE["themes"][theme])
    real.update({k: v for k, v in fur.items() if k in THEME_FILE["fur_tokens"]})
    return {PLACEHOLDERS[t]: c for t, c in real.items() if t in PLACEHOLDERS}


def recolor(svg: str, cmap: dict) -> str:
    # one pass, so a replacement can never be re-replaced by a later token
    return HEX.sub(lambda m: cmap.get(m.group(0).upper(), m.group(0)), svg)


def wrap(svg: str, transform: str) -> str:
    """Apply a group transform to a whole SVG layer."""
    start = svg.index(">", svg.index("<svg")) + 1
    end = svg.rindex("</svg>")
    return f'{svg[:start]}<g transform="{transform}">{svg[start:end]}</g>{svg[end:]}'


def raster(path: Path, cmap: dict, size: int, transform: str | None = None) -> Image.Image:
    svg = recolor(path.read_text(), cmap)
    if transform:
        svg = wrap(svg, transform)
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def compose(paths, theme: str, fur: dict, size: int = SIZE) -> Image.Image:
    cmap = color_map(theme, fur)
    out = Image.new("RGBA", (size, size), BACKDROPS[theme] + (255,))
    for p in paths:
        if isinstance(p, tuple) and p[0] == "LEGENDS":
            out.alpha_composite(legends(size, theme, p[1]))
            continue
        p, t = p if isinstance(p, tuple) else (p, None)
        out.alpha_composite(raster(p, cmap, size, t))
    return out.convert("RGB")


KEYS = json.loads((SHARED / "keyboard_keys.json").read_text())
FONT_PATH = ROOT.parent / KEYS["font"]


def legends(size: int, theme: str, kb=(0.0, 0.0, 1.0), os_name: str = "default") -> Image.Image:
    """Keycap legends, rasterized by FreeType with the keyboard's affine transform applied to the glyph
    outlines (FT_Set_Transform), the same way the app's text system does it: no bitmap stretching."""
    import freetype

    tx, ty, sc = kb
    color = THEME_FILE["themes"][theme]["keycap_legend"]
    rgb = tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))
    k = size / 256
    (ux, uy), (vx, vy) = KEYS["u"], KEYS["v"]
    overrides = KEYS["os_overrides"].get(os_name, {})
    face = freetype.Face(str(FONT_PATH))
    nominal = 64
    face.set_char_size(nominal * 64)
    flags = freetype.FT_LOAD_RENDER | freetype.FT_LOAD_NO_HINTING
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    solid = Image.new("RGBA", (size, size), rgb + (255,))
    for key in KEYS["keys"]:
        text = key["label"]
        row_over = overrides.get(str(key["row"]))
        if row_over:
            text = row_over[key["index"]]
        if not text:
            continue
        # glyph x -> u, glyph up -> v; FreeType device space is y-up, so negate the y components
        f = key["em"] * sc * k * 1.35 / nominal
        m = freetype.Matrix(int(f * ux * 65536), int(f * vx * 65536), int(-f * uy * 65536), int(-f * vy * 65536))
        face.set_transform(m, freetype.Vector(0, 0))
        pen_x = pen_y = 0.0   # device pixels, y down
        pieces = []
        for ch in text:
            face.load_char(ch, flags)
            g = face.glyph
            bm = g.bitmap
            if bm.width and bm.rows:
                img = Image.frombytes("L", (bm.width, bm.rows), bytes(bm.buffer))
                pieces.append((img, pen_x + g.bitmap_left, pen_y - g.bitmap_top))
            pen_x += g.advance.x / 64
            pen_y -= g.advance.y / 64
        if not pieces:
            continue
        x0 = min(px for _, px, _ in pieces); y0 = min(py for _, _, py in pieces)
        x1 = max(px + im.width for im, px, _ in pieces); y1 = max(py + im.height for im, _, py in pieces)
        cx, cy = key["center"]
        cx, cy = (30 + (cx - 30) * sc + tx) * k, (200 + (cy - 200) * sc + ty) * k
        mask = Image.new("L", (size, size), 0)
        for im, px, py in pieces:
            mask.paste(im, (round(cx - (x0 + x1) / 2 + px), round(cy - (y0 + y1) / 2 + py)), im)
        out.paste(solid, (0, 0), mask)
    return out


def label(draw, x, y, text):
    draw.text((x + 6, y + 4), text, fill=(0, 0, 0))


class Animal:
    def __init__(self, name: str):
        self.name = name
        self.dir = ROOT / name
        pal = self.dir / "palette.json"
        data = json.loads(pal.read_text()) if pal.exists() else {}
        if any(t in data for t in THEMES):
            print(f"  {name}: palette.json is per-theme (old format); fur is no longer themed, using 'bright'")
            data = data.get("bright", {})
        self.fur = data
        anc = self.dir / "anchors.json"
        self.anchors = json.loads(anc.read_text()) if anc.exists() else {}
        if not self.anchors and name != "_shared":
            print(f"  {name}: no anchors.json (see SPEC 'Yours')")

    def find(self, rel: str):
        """Path for a layer: the animal's own file, else (for acc/ layers) the shared one."""
        own = self.dir / f"{rel}.svg"
        if own.exists():
            return own
        if rel.startswith("acc/"):
            shared = SHARED / f"{rel[4:]}.svg"
            if shared.exists():
                return shared
        if rel.endswith("_paws"):
            base = rel[: -len("_paws")]
            if base in PAWS_FALLBACK:
                return self.find(PAWS_FALLBACK[base] + "_paws")
        return None

    def layers(self, frame, desk=(), head=None, hold=None, keyboard=True, sparkles=False):
        """Layer names in draw order (SPEC "Draw order")."""
        names = []
        if sparkles:
            names.append("acc/sparkles")
        names += [f"acc/{d}" for d in DESK if d in desk]
        names.append(frame)
        if head:
            names.append(f"acc/{head}_sleep" if frame in SLEEPY else f"acc/{head}")
        if keyboard:
            names.append("acc/keyboard")
        if hold and frame in ("hold", "sip"):
            # sip uses the item raised to the mouth (acc/sip_<item>) when the animal has one
            sip = "acc/sip_" + hold.removeprefix("hold_")
            names.append(sip if frame == "sip" and self.find(sip) else f"acc/{hold}")
        names.append(f"{frame}_paws")
        if head == "headphones" and frame in TYPING:
            names.append("acc/music_notes")
        if frame == "excited":
            names.append("acc/motion")
        if frame == "sleep":
            names.append("acc/zzz")
        return names

    def transform_for(self, name: str, path: Path):
        """anchors.json placement for shared layers (the animal's own copies are drawn in place)."""
        if path.parent != SHARED:
            return None
        base = name.removeprefix("acc/")
        if base == "keyboard" or base in DESK:
            kb = self.anchors.get("keyboard", {})
            (tx, ty), sc = kb.get("translate", [0, 0]), kb.get("scale", 1.0)
            if (tx, ty, sc) == (0, 0, 1.0):
                return None
            # scale about the keyboard's front-left bottom corner, then move
            return f"translate({tx} {ty}) translate(30 200) scale({sc}) translate(-30 -200)"
        off = self.anchors.get("overlays", {}).get(base)
        return f"translate({off[0]} {off[1]})" if off else None

    def stack(self, frame, theme, size=SIZE, **kw):
        paths, missing = [], []
        for n in self.layers(frame, **kw):
            p = self.find(n)
            if p:
                t = self.transform_for(n, p)
                paths.append((p, t) if t else p)
                if n == "acc/keyboard" and p.parent == SHARED:
                    kb = self.anchors.get("keyboard", {})
                    paths.append(("LEGENDS", (*kb.get("translate", [0, 0]), kb.get("scale", 1.0))))
            else:
                missing.append(n)
        return compose(paths, theme, self.fur, size), missing


def render(name: str) -> None:
    a = Animal(name)
    out = a.dir / "preview"
    out.mkdir(exist_ok=True)
    missing = set()

    sheet = Image.new("RGB", (SIZE * len(FRAMES), SIZE * len(THEMES) + 20), (255, 255, 255))
    for col, frame in enumerate(FRAMES):
        for row, theme in enumerate(THEMES):
            hold = "hold_coffee" if frame in ("hold", "sip") else None
            img, miss = a.stack(frame, theme, hold=hold, head="headphones")
            missing.update(miss)
            sheet.paste(img, (col * SIZE, row * SIZE))
            if theme == "bright":
                img.save(out / f"{frame}.png")
        label(ImageDraw.Draw(sheet), col * SIZE, SIZE * len(THEMES), frame)
    sheet.save(out / "sheet.png")
    for px in (96, 512):
        img, _ = a.stack("idle", "bright", size=px, head="headphones", sparkles=True)
        img.save(out / f"idle_{px}.png")

    combos = [("no keyboard", dict(frame="idle", keyboard=False)), ("bare", dict(frame="type_left"))]
    combos += [(h, dict(frame="type_left", head=h)) for h in HEAD]
    combos += [(h + " (sleep)", dict(frame="sleep", head=h)) for h in ("headphones", "beanie")]
    combos += [(h, dict(frame="hold", hold=h)) for h in HOLD]
    combos += [("sip", dict(frame="sip", hold="hold_coffee"))]
    combos += [("desk+sparkles", dict(frame="type_both", desk=DESK, sparkles=True))]
    acc = Image.new("RGB", (SIZE * len(combos), SIZE + 20), (255, 255, 255))
    for col, (title, kw) in enumerate(combos):
        img, miss = a.stack(theme="bright", **kw)
        missing.update(miss)
        acc.paste(img, (col * SIZE, 0))
        label(ImageDraw.Draw(acc), col * SIZE, SIZE, title)
    acc.save(out / "accessories.png")

    for icon in ICONS:
        path = a.dir / f"{icon}.svg"
        if not path.exists():
            missing.add(icon)
            continue
        small = raster(path, color_map("bright", a.fur), 16)
        small.resize((128, 128), Image.NEAREST).save(out / f"{icon}_16x.png")

    print(f"{name}: wrote {out}/sheet.png, accessories.png, idle_96.png, idle_512.png")
    for m in sorted(missing):
        print(f"  missing {m}.svg")


def render_shared() -> None:
    """Shared layers on the reference placeholder animal, in all three themes."""
    s = lambda n: SHARED / f"{n}.svg"
    ref, ref_paws, hug = s("reference_pose"), s("reference_pose_paws"), s("reference_hold_paws")
    kb = s("keyboard")
    scene = [s("sparkles")] + [s(d) for d in DESK] + [ref, s("headphones"), kb, ref_paws, s("music_notes")]
    cols = [
        ("scene", scene),
        ("keyboard", [kb]),
        ("reference pose", [ref, kb, ref_paws]),
        ("hold_coffee", [ref, s("headphones"), kb, s("hold_coffee"), hug]),
        ("hold_boba", [ref, kb, s("hold_boba"), hug]),
        ("hold_book", [ref, kb, s("hold_book"), hug]),
        ("excited marks", [ref, kb, ref_paws, s("motion")]),
        ("sleep gear + zzz", [s("headphones_sleep"), kb, s("zzz")]),
        ("desk props", [s(d) for d in DESK] + [s("sparkles")]),
    ]
    fur = {}
    out = SHARED / "preview"
    out.mkdir(exist_ok=True)
    small = 96
    h = SIZE * len(THEMES) + small + 20
    sheet = Image.new("RGB", (SIZE * len(cols), h), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    for col, (title, paths) in enumerate(cols):
        for row, theme in enumerate(THEMES):
            sheet.paste(compose(paths, theme, fur), (col * SIZE, row * SIZE))
        label(draw, col * SIZE, SIZE * len(THEMES) + small, title)
    # bottom strip: the scene and the keyboard at the smallest on-screen size, every theme
    x = 0
    for paths in (scene, [ref, s("headphones"), kb, ref_paws]):
        for theme in THEMES:
            sheet.paste(compose(paths, theme, fur, small), (x, SIZE * len(THEMES)))
            x += small + 8
    label(draw, x, SIZE * len(THEMES) + 30, "<- 96 px: scene x3 themes, typing pose x3 themes")
    sheet.save(out / "sheet.png")
    for px in (96, 512):
        compose(scene, "dark", fur, px).save(out / f"scene_dark_{px}.png")
    print(f"_shared: wrote {out}/sheet.png, scene_dark_96.png, scene_dark_512.png")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--shared"]:
        render_shared()
    else:
        for n in args or sorted(p.name for p in ROOT.iterdir() if p.is_dir() and not p.name.startswith("_")):
            render(n)
