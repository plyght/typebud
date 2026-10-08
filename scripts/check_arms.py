#!/usr/bin/env python3
"""Find arm/keyboard layering mistakes in an animal's art.

usage: scripts/check_arms.py <animal> [--out DIR] [--size N]

Two kinds of mistakes show up where arms meet the keyboard:

* THROUGH: paw/forearm pixels (the `<frame>_paws` layer, drawn over the keyboard) that land on the
  keyboard's FRONT or RIGHT side faces. Paws sit on the key surface; anything that spills onto the
  side faces reads as the arm going through the board. Measured automatically.
* UNDER: an arm drawn in the body layer (`<frame>.svg`, drawn behind the keyboard) where the
  keyboard then covers it, so the board cuts across the arm. Flagged when body-layer OUTLINE pixels hidden
  by the keyboard touch paw-layer pixels (the arm continues under the board right next to a paw).

For every frame it writes a debug crop of the keyboard area to --out (default
art/<animal>/preview/arms/): the normal render, plus an overlay where THROUGH pixels are red,
UNDER pixels are blue, the keyboard top face is outlined green and the side faces yellow.
Exit status is 1 if any frame has more than the tolerated number of THROUGH or UNDER pixels.
"""
import argparse
import io
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_art as ra  # noqa: E402

# Keyboard case geometry at the default placement (scripts/gen_keyboard.py).
FL, FR, BL = (30.0, 188.0), (170.0, 224.0), (80.0, 146.0)
BR = (FR[0] + BL[0] - FL[0], FR[1] + BL[1] - FL[1])
DEPTH = 12.0
UNDER_TOLERANCE = 12        # outline px (at 256 px canvas scale) of arm hidden under the board next to a paw
THROUGH_TOLERANCE = 0.002   # fraction of the paws layer allowed on the side faces (antialiasing)


def kb_xform(anchors):
    kb = anchors.get("keyboard", {})
    (tx, ty), sc = kb.get("translate", [0, 0]), kb.get("scale", 1.0)
    return lambda p: (30 + (p[0] - 30) * sc + tx, 200 + (p[1] - 200) * sc + ty)


def polys(anchors):
    t = kb_xform(anchors)
    down = lambda p: (p[0], p[1] + DEPTH)
    top = [t(FL), t(FR), t(BR), t(BL)]
    front = [t(FL), t(FR), t(down(FR)), t(down(FL))]
    right = [t(FR), t(BR), t(down(BR)), t(down(FR))]
    return top, front, right


def mask_of(paths_with_t, size, cmap):
    """Alpha mask of the given layers composited together."""
    out = Image.new("L", (size, size), 0)
    for p, tr in paths_with_t:
        img = ra.raster(p, cmap, size, tr)
        out = ImageChops.lighter(out, img.getchannel("A"))
    return out.point(lambda v: 255 if v > 96 else 0)


def poly_mask(poly, size, k):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon([(x * k, y * k) for x, y in poly], fill=255)
    return m


def check(name, out_dir, size):
    a = ra.Animal(name)
    cmap = ra.color_map("bright", a.fur)
    k = size / 256
    top, front, right = polys(a.anchors)
    sides = ImageChops.lighter(poly_mask(front, size, k), poly_mask(right, size, k))
    kb_path = a.find("acc/keyboard")
    kb_t = a.transform_for("acc/keyboard", kb_path) if kb_path else None
    kb_mask = mask_of([(kb_path, kb_t)], size, cmap) if kb_path else Image.new("L", (size, size), 0)
    out_dir.mkdir(parents=True, exist_ok=True)

    failures = 0
    print(f"{name}: THROUGH = paws on keyboard side faces, UNDER = arm hidden under the board next to a paw")
    for frame in ra.FRAMES:
        paws = a.find(f"{frame}_paws")
        body = a.find(frame)
        if not paws or not body:
            continue
        hold = None
        if frame in ("hold", "sip"):
            hold = a.find("acc/sip_coffee" if frame == "sip" else "acc/hold_coffee") or a.find("acc/hold_coffee")
        paws_m = mask_of([(paws, None)], size, cmap)
        body_m = mask_of([(body, None)], size, cmap)
        # outline-coloured body pixels only: an arm OUTLINE continuing under the board is the bug;
        # plain body fill behind the keyboard is normal
        body_rgba = ra.raster(body, cmap, size)
        r, g, b, al = body_rgba.split()
        dark = Image.merge("RGB", (r, g, b)).convert("L").point(lambda v: 255 if v < 80 else 0)
        body_m = ImageChops.multiply(ImageChops.multiply(body_m, dark), al.point(lambda v: 255 if v > 96 else 0))

        through = ImageChops.multiply(paws_m, sides)
        n_paws = max(1, sum(1 for v in paws_m.get_flattened_data() if v))
        n_through = sum(1 for v in through.get_flattened_data() if v)

        # body pixels covered by the keyboard that touch a paw (dilate paws a few px)
        near_paws = paws_m.filter(ImageFilter.MaxFilter(int(6 * k) | 1))
        hidden_body = ImageChops.multiply(ImageChops.multiply(body_m, kb_mask), near_paws)
        hidden_body = ImageChops.subtract(hidden_body, paws_m)
        n_under = sum(1 for v in hidden_body.get_flattened_data() if v)

        bad = n_through / n_paws > THROUGH_TOLERANCE or n_under > UNDER_TOLERANCE * k * k
        failures += bad
        flag = "  <-- FIX" if bad else ""
        print(f"  {frame:11s} through={n_through:6d} px ({100 * n_through / n_paws:5.2f}% of paws)  under={n_under:6d} px{flag}")

        render, _ = a.stack(frame, "bright", size=size, head=None,
                            hold="hold_coffee" if frame in ("hold", "sip") else None)
        overlay = render.convert("RGBA")
        red = Image.new("RGBA", (size, size), (255, 0, 0, 230))
        blue = Image.new("RGBA", (size, size), (0, 90, 255, 200))
        overlay.paste(blue, (0, 0), hidden_body)
        overlay.paste(red, (0, 0), through)
        d = ImageDraw.Draw(overlay)
        d.polygon([(x * k, y * k) for x, y in top], outline=(0, 200, 0, 255), width=max(1, size // 512))
        for poly in (front, right):
            d.polygon([(x * k, y * k) for x, y in poly], outline=(230, 200, 0, 255), width=max(1, size // 512))
        xs = [p[0] for p in top + front + right]
        ys = [p[1] for p in top + front + right]
        box = (int((min(xs) - 24) * k), int((min(ys) - 60) * k), int((max(xs) + 24) * k), int((max(ys) + 8) * k))
        box = (max(0, box[0]), max(0, box[1]), min(size, box[2]), min(size, box[3]))
        pair = Image.new("RGB", ((box[2] - box[0]) * 2 + 8, box[3] - box[1]), (255, 255, 255))
        pair.paste(render.crop(box), (0, 0))
        pair.paste(overlay.convert("RGB").crop(box), (box[2] - box[0] + 8, 0))
        pair.save(out_dir / f"{frame}.png")
    print(f"  debug crops: {out_dir}")
    return failures


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("animal")
    ap.add_argument("--out")
    ap.add_argument("--size", type=int, default=1024)
    args = ap.parse_args()
    out = Path(args.out) if args.out else ra.ROOT / args.animal / "preview" / "arms"
    sys.exit(1 if check(args.animal, out, args.size) else 0)
