#!/usr/bin/env python3
"""Render an animal's SVG frames to PNG previews and a contact sheet, one row per theme.

usage: scripts/render_art.py <animal> [<animal> ...]
Needs: pip install cairosvg pillow
"""
import io
import json
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent / "art"
FRAMES = ["idle", "blink", "type_left", "type_right", "type_both", "excited", "sleep", "wake", "icon", "icon_template"]
TOKENS = {
    "fur_main": "#B07A4A", "fur_shade": "#8A5A33", "fur_light": "#E8C9A0", "outline": "#3B2A1E",
    "blush": "#F2A7A0", "keyboard": "#2E3440", "keycap": "#D8DEE9", "accent": "#FFD166",
}
BACKDROPS = {"dark": (30, 30, 36), "bright": (245, 245, 240), "pink": (255, 228, 236)}
SIZE = 256


def themed(svg: str, palette: dict, theme: str) -> str:
    for token, placeholder in TOKENS.items():
        color = palette.get(theme, {}).get(token)
        if color:
            svg = svg.replace(placeholder, color).replace(placeholder.lower(), color)
    return svg


def render(animal: str) -> None:
    folder = ROOT / animal
    palette = json.loads((folder / "palette.json").read_text()) if (folder / "palette.json").exists() else {}
    out = folder / "preview"
    out.mkdir(exist_ok=True)
    sheet = Image.new("RGB", (SIZE * len(FRAMES), SIZE * len(BACKDROPS) + 20), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    for col, frame in enumerate(FRAMES):
        draw.text((col * SIZE + 6, SIZE * len(BACKDROPS) + 4), frame, fill=(0, 0, 0))
        path = folder / f"{frame}.svg"
        if not path.exists():
            print(f"missing {path}")
            continue
        src = path.read_text()
        for row, (theme, bg) in enumerate(BACKDROPS.items()):
            png = cairosvg.svg2png(bytestring=themed(src, palette, theme).encode(), output_width=SIZE, output_height=SIZE)
            img = Image.open(io.BytesIO(png)).convert("RGBA")
            if row == 0:
                img.save(out / f"{frame}.png")
            tile = Image.new("RGBA", (SIZE, SIZE), bg + (255,))
            tile.alpha_composite(img)
            sheet.paste(tile.convert("RGB"), (col * SIZE, row * SIZE))
        # 16px legibility check for the tray icon
        if frame.startswith("icon"):
            small = cairosvg.svg2png(bytestring=src.encode(), output_width=16, output_height=16)
            Image.open(io.BytesIO(small)).resize((128, 128), Image.NEAREST).save(out / f"{frame}_16x.png")
    sheet.save(out / "sheet.png")
    print(f"wrote {out / 'sheet.png'}")


if __name__ == "__main__":
    for name in sys.argv[1:] or [p.name for p in ROOT.iterdir() if p.is_dir()]:
        render(name)
