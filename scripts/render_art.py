#!/usr/bin/env python3
"""Render an animal's layered SVG art to PNG previews, the way the app stacks it (art/SPEC.md).

usage: scripts/render_art.py [<animal> ...]     (default: every folder in art/)
Writes art/<animal>/preview/:
  sheet.png        every frame composited with keyboard + paws, one row per theme
  accessories.png  idle (or hold/sip) with each accessory turned on, bright theme
  icon*_16x.png    the tray icons at 16 px, upscaled for inspection
Needs: pip install cairosvg pillow
"""
import io
import json
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent / "art"
FRAMES = ["idle", "blink", "type_left", "type_right", "type_both", "excited", "sleep", "wake", "hold", "sip"]
ICONS = ["icon", "icon_template"]
HEAD = ["headphones", "beanie", "party_hat", "bow", "glasses"]
HOLD = ["hold_coffee", "hold_boba", "hold_book"]
DESK = ["desk_plant", "desk_lamp", "desk_mug"]
TOKENS = {
    "fur_main": "#B07A4A", "fur_shade": "#8A5A33", "fur_light": "#E8C9A0", "outline": "#3B2A1E",
    "blush": "#F2A7A0", "keyboard": "#2E3440", "keycap": "#D8DEE9", "accent": "#FFD166",
    "item_a": "#C0392B", "item_b": "#27AE60", "item_c": "#F5F5F5",
}
BACKDROPS = {"dark": (30, 30, 36), "bright": (245, 245, 240), "pink": (255, 228, 236)}
SIZE = 256


class Animal:
    def __init__(self, name: str):
        self.dir = ROOT / name
        pal = self.dir / "palette.json"
        self.palette = json.loads(pal.read_text()) if pal.exists() else {}

    def layer(self, rel: str, theme: str):
        path = self.dir / f"{rel}.svg"
        if not path.exists():
            return None
        svg = path.read_text()
        for token, placeholder in TOKENS.items():
            color = self.palette.get(theme, {}).get(token)
            if color:
                svg = svg.replace(placeholder, color).replace(placeholder.lower(), color)
        png = cairosvg.svg2png(bytestring=svg.encode(), output_width=SIZE, output_height=SIZE)
        return Image.open(io.BytesIO(png)).convert("RGBA")

    def stack(self, frame: str, theme: str, desk=(), head=None, hold=None, keyboard=True):
        sleeping = frame in ("sleep", "wake")
        names = [f"acc/{d}" for d in desk] + [frame]
        if head:
            names.append(f"acc/{head}_sleep" if sleeping else f"acc/{head}")
        if keyboard:
            names.append("acc/keyboard")
        names.append(f"{frame}_paws")
        if hold and frame in ("hold", "sip"):
            names.append(f"acc/{hold}")
        out = Image.new("RGBA", (SIZE, SIZE), BACKDROPS[theme] + (255,))
        missing = []
        for n in names:
            img = self.layer(n, theme)
            if img is None:
                missing.append(n)
            else:
                out.alpha_composite(img)
        return out.convert("RGB"), missing


def label(draw, x, y, text):
    draw.text((x + 6, y + 4), text, fill=(0, 0, 0))


def render(name: str) -> None:
    a = Animal(name)
    out = a.dir / "preview"
    out.mkdir(exist_ok=True)
    missing = set()

    sheet = Image.new("RGB", (SIZE * len(FRAMES), SIZE * len(BACKDROPS) + 20), (255, 255, 255))
    for col, frame in enumerate(FRAMES):
        for row, theme in enumerate(BACKDROPS):
            hold = "hold_coffee" if frame in ("hold", "sip") else None
            img, miss = a.stack(frame, theme, hold=hold)
            missing.update(miss)
            sheet.paste(img, (col * SIZE, row * SIZE))
            if row == 0:
                img.save(out / f"{frame}.png")
        label(ImageDraw.Draw(sheet), col * SIZE, SIZE * len(BACKDROPS), frame)
    sheet.save(out / "sheet.png")

    combos = [("no keyboard", dict(frame="idle", keyboard=False))]
    combos += [(h, dict(frame="type_left", head=h)) for h in HEAD]
    combos += [(h + " (sleep)", dict(frame="sleep", head=h)) for h in ("headphones", "beanie")]
    combos += [(h, dict(frame="hold", hold=h)) for h in HOLD]
    combos += [("sip", dict(frame="sip", hold="hold_coffee"))]
    combos += [("desk", dict(frame="type_both", desk=DESK))]
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
        small = cairosvg.svg2png(bytestring=path.read_bytes(), output_width=16, output_height=16)
        Image.open(io.BytesIO(small)).resize((128, 128), Image.NEAREST).save(out / f"{icon}_16x.png")

    print(f"{name}: wrote {out}/sheet.png, accessories.png")
    for m in sorted(missing):
        print(f"  missing {m}.svg")


if __name__ == "__main__":
    for n in sys.argv[1:] or sorted(p.name for p in ROOT.iterdir() if p.is_dir()):
        render(n)
