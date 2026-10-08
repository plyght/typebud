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
| `hold.svg` | Idle while holding an item in the left paw. |
| `sip.svg` | Sipping or using the held item. |
| `icon.svg` | The face only, for tray/menu bar and app icon; must read at 16×16. |
| `icon_template.svg` | Single-color black silhouette of `icon.svg` (macOS template image). |

Body and head stay pixel-identical between frames (except `sleep`/`wake`, where the head lowers);
only paws, eyes, mouth and accents change. Frames contain **no keyboard and no accessories**: those
are separate, toggleable layers (below).

## Layers and accessories

Every accessory is configurable in the app, so the art is split into layers that the app stacks on
the same 256×256 canvas. Draw order, back to front:

1. `acc/desk_<item>.svg`: desk props behind the animal (`desk_plant`, `desk_lamp`, `desk_mug`; the
   mug is where the held drink rests while typing).
2. `<frame>.svg`: body, head and face, without paws.
3. `acc/<head item>.svg`: head accessories. Each one also has a `_sleep` variant that follows the
   lowered head (`headphones` + `headphones_sleep`, `beanie`, `party_hat`, `bow`, `glasses`).
   When headphones are on, the app also floats `acc/music_notes.svg` above them while typing.
4. `acc/keyboard.svg`: the keyboard. With the keyboard turned off, the paws rest on the desk line.
5. `<frame>_paws.svg`: paws. They sit on the keycaps' top surface (y≈200) so they also look right
   with no keyboard.
6. `acc/hold_<item>.svg`: an item held in the left paw, shown only with `hold.svg`/`hold_paws.svg`
   and `sip.svg`/`sip_paws.svg` (`hold_coffee`, `hold_boba`, `hold_book`). With a held item, the
   animal holds it when idle and sets it on the desk (`desk_mug`) while typing.

Every frame therefore has a `<frame>_paws.svg` partner. Add the extra frames `hold`, `sip` (for the
idle loop with a held item) and their `_paws`. Accessories use the same token colors plus three extra
tokens: `item_a` `#C0392B`, `item_b` `#27AE60`, `item_c` `#F5F5F5`.

## Themes

The app has three themes (plus `light`/`dark` *window* chrome that follows the OS): **dark**, **bright**, and **pink**. Use only these placeholder colors in
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
| item_a / item_b / item_c | `#C0392B` / `#27AE60` / `#F5F5F5` | Accessory colors (cup, plant, pages). |

Each animal writes `art/<animal>/palette.json` mapping these token names to its real colors for
each of the three themes (`dark`, `bright`, `pink`).

## Performance

The app rasterizes each layer once per (size, theme, display scale) and only re-blits, so keep each SVG
under ~150 elements and avoid hairline details below 1.5 px at the 128 px (Small) size.

## Deliverables per animal

`art/<animal>/` containing every frame + `_paws` partner, the `acc/` layers, `palette.json`, and `NOTES.md` (one paragraph on the
character's personality and one line per frame). Also run `scripts/render_art.py <animal>`, which
renders PNG previews and a contact sheet into `art/<animal>/preview/` so the art can be reviewed.
