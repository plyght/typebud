# typebud character art spec

Every animal is a folder `art/<animal>/` of standalone SVG frames that the app swaps between and
lightly transforms (bob, squash, paw offsets). The same rules apply to every animal so they're
interchangeable in the app.

## Canvas

- `viewBox="0 0 256 256"`, no `width`/`height` attributes, transparent background.
- The character sits on an implicit desk line at y = 224 and is centered horizontally. Its bounding
  box stays inside x ∈ [16, 240], y ∈ [24, 240] so S/M/L scaling never clips.
- Only flat fills, strokes, and linear/radial gradients: no filters, masks, `<text>`, external
  references, CSS `<style>` blocks, or embedded images (zpui renders through lunasvg).
- Stroke outlines use `stroke-linejoin="round"` and `stroke-linecap="round"`.

## Frames (file names are fixed)

| File | Purpose |
|---|---|
| `idle.svg` | Resting at the keyboard, eyes open, paws on the keys. |
| `blink.svg` | `idle` with eyes closed (used for a few frames every ~4 s). |
| `type_left.svg` | Left paw pressed down, right paw raised. |
| `type_right.svg` | Right paw pressed down, left paw raised. |
| `type_both.svg` | Both paws down (fast typing / space bar). |
| `excited.svg` | Burst of fast typing: happy eyes, little motion marks. |
| `sleep.svg` | After ~60 s of no typing: eyes closed, head lowered, a "z" shape drawn as a path. |
| `wake.svg` | Transition from sleep: one eye open, startled. |
| `icon.svg` | The face only, for tray/menu bar and app icon; must read at 16×16. |
| `icon_template.svg` | Single-color black silhouette of `icon.svg` (macOS template image). |

Every frame includes the same small keyboard (or desk prop) at the bottom so swaps don't jump.
Body, head and keyboard stay pixel-identical between frames; only paws, eyes, mouth and accents
change.

## Themes

The app has three themes: **dark**, **bright**, and **pink**. Use only these placeholder colors in
the SVGs. The app substitutes them per theme, so every color in your art must be one of these
exact hex values:

| Token | Placeholder | Meaning |
|---|---|---|
| fur main | `#B07A4A` | Main body color (each animal picks its own and records it in `palette.json`). |
| fur shade | `#8A5A33` | Shadow side. |
| fur light | `#E8C9A0` | Belly/muzzle. |
| outline | `#3B2A1E` | Line work. |
| blush | `#F2A7A0` | Cheeks. |
| keyboard | `#2E3440` | Keyboard body. |
| keycap | `#D8DEE9` | Keycaps. |
| accent | `#FFD166` | Sparkles, z's, motion marks. |

Each animal writes `art/<animal>/palette.json` mapping these token names to its real colors for
each of the three themes (`dark`, `bright`, `pink`).

## Deliverables per animal

`art/<animal>/` containing the 10 SVGs, `palette.json`, and `NOTES.md` (one paragraph on the
character's personality and one line per frame). Also run `scripts/render_art.py <animal>`, which
renders PNG previews and a contact sheet into `art/<animal>/preview/` so the art can be reviewed.
