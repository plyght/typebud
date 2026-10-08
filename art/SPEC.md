# typebud character art spec

Every animal is a folder `art/<animal>/` of standalone SVG layers that the app stacks on one
256×256 canvas, swaps between, and lightly transforms (bob, squash). The **technical contract**
(canvas, layer names, frame list, draw order, colour tokens) is shared so animals, accessories and
themes mix freely. The **anatomy is not**: each animal's designer owns its silhouette, proportions,
posture and where its head and paws sit, and describes them in `anchors.json`. How lines, eyes and
shading are drawn is in [STYLE.md](STYLE.md); shared gear lives in [`_shared/`](_shared/).

The scene is the same for every animal: the animal sits (or stands) behind a compact keyboard and
taps it while you type. Beyond that, draw the animal the way that animal should look: a tall egg
penguin, a long low capybara, an upright shiba. Don't squeeze it into another animal's shape.

## Canvas and rendering

- `viewBox="0 0 256 256"`, no `width`/`height` attributes, transparent background.
- The pet is freely resizable, from about **96 px to 512 px** tall on screen (×2 on HiDPI). Art must
  read at 96 px and must not look sparse or blocky at 512 px. Line weights in STYLE.md are chosen
  for that range. Keycap legends, blush hatching and toe lines may vanish below ~160 px; nothing
  else may.
- Everything stays inside the safe box x ∈ [8, 248], y ∈ [8, 248], **strokes included**.
- Allowed: `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `g`, `defs`,
  `linearGradient`, `radialGradient`, `transform` attributes, `fill-opacity` (sparingly).
  Not allowed: filters, masks, clip paths, `<use>`, `<text>`, `<style>`/CSS, `<image>`, external
  references (the app renders through lunasvg). `stroke-dasharray` only in reference files.
- Strokes use `stroke-linejoin="round"` and `stroke-linecap="round"`.
- Keep each SVG under ~150 elements. Many shapes of the same style can share one `<path>` with
  several subpaths (the keyboard draws all 61 keycaps in two paths).
- Gradient ids must be unique per file and prefixed with the file's purpose (`kb-underglow`,
  `hp-ring`) because the app may inline several layers.

## Geometry: what's shared, what's yours

### Shared defaults (`_shared/`)

`_shared/keyboard.svg` is drawn at a default placement (desk line y = 236; case top corners
front-left (30,188), front-right (170,224), back-right (220,182), back-left (80,146); back edge
y = 146 + 0.257·(x − 80); key grid K(s,t) = (37.4,185.9) + s·(8.84,2.27) + t·(8.74,−7.34)).
`scripts/gen_keyboard.py` generates it. `_shared/reference_pose*.svg` is one example of an animal
fitted to that default. It is **only an example**; don't copy its bean shape.

The shared head items (`headphones`), held items, desk props and overlays are drawn for that
example. Every animal ships its own fitted copies in `acc/`.

### Yours (`anchors.json`)

Each animal has `art/<animal>/anchors.json`. The app and `scripts/render_art.py` read it, so the
art can sit anywhere in the canvas:

```json
{
  "keyboard": { "translate": [0, 0], "scale": 1.0 },
  "overlays": {
    "music_notes": [0, 0],
    "zzz": [0, 0],
    "motion": [0, 0]
  },
  "paws": { "left": [122, 168], "right": [160, 180] },
  "head": { "cx": 152, "cy": 80, "rx": 58, "ry": 48 }
}
```

| Field | Meaning |
|---|---|
| `keyboard` | Transform applied to the shared keyboard (and the desk props) for this animal: `translate(x y) scale(s)` about the keyboard's front-left bottom corner (30,200). Use it to make the board smaller/larger or move it so your animal's paws land naturally. Optional; default identity. |
| `overlays.*` | Offset of each shared overlay from its default position (`music_notes` top right, `zzz` top left, `motion` around the default paws). Optional. You may instead ship your own `acc/music_notes.svg` etc. |
| `paws.left/right` | Rest points of your paws on the keys (the app uses them for small key-press effects). Required. |
| `head` | Ellipse of your head (the app uses it for future effects and the settings preview crop). Required. |

Everything else is free: head size and position, body shape, how far the animal leans over the
keyboard, how the paws reach the keys, where held items sit, how the head moves when asleep. Rules
that still apply:

- Everything stays inside the safe box (below) with strokes included, at the keyboard transform
  you chose.
- Layers line up between frames: the body doesn't jump from frame to frame unless the motion is
  intentional (sleep slump, excited bounce).
- The paws/flippers in `<frame>_paws.svg` are drawn **over** the keyboard, so they must visibly
  sit on (or hover just above) keys. With the keyboard turned off they must still read as resting
  on the desk.
- Held items are hugged in front of the chest (`hold`) and raised to the mouth (`sip`), never in
  front of the keyboard's keys.
- Head items: ship fitted `acc/<item>.svg` + `acc/<item>_sleep.svg` for every head item, following
  your own head in both poses.
- Prefer keeping the right side clear of the plant/mug props and the top corners clear for the
  overlays, but if your animal's silhouette needs the space, move the props via your own
  `acc/desk_*.svg` copies rather than cramping the animal.

## Frames (final list; file names are fixed)

| File | Purpose |
|---|---|
| `idle.svg` | Resting at the keyboard. Eyes closed in the content "— —" look (the default face). |
| `peek.svg` | `idle` with small open eyes; shown for ~0.5 s every 4–8 s. (Replaces the old `blink`: the resting face already has closed eyes.) |
| `type_left.svg` | L paw pressed, R paw raised. |
| `type_right.svg` | R paw pressed, L paw raised. |
| `type_both.svg` | Both paws pressed (fast typing / space bar). |
| `excited.svg` | Burst of fast typing: happy "^ ^" eyes, open smile; both paws raised; motion marks overlay. |
| `sleep.svg` | After ~60 s idle: head lowered (sleep transform), droopy closed eyes; z's overlay. |
| `wake.svg` | Transition out of sleep: head still lowered, one eye open, one closed. |
| `hold.svg` | Idle while hugging the held item; content eyes. |
| `sip.svg` | Sipping/reading the held item; blissful closed eyes, mouth at the item. |
| `icon.svg` | Face only, for the tray/menu bar and app icon; must read at 16×16. |
| `icon_template.svg` | Pure black (`#000000`) silhouette of `icon.svg` with features cut out (even-odd holes). |

Every frame except the icons has a `<frame>_paws.svg` partner (forearms + paws). `peek` and `wake`
may omit theirs; the app then uses `idle_paws` and `sleep_paws`.

Body and head are identical between frames (except `sleep`/`wake`, which use the sleep transform for
the head); only eyes, mouth, and paws change. Frames contain no keyboard, gear, props or overlays.

## Draw order (back to front)

1. `acc/sparkles.svg`: optional decor.
2. `acc/desk_lamp.svg`, `acc/desk_plant.svg`, `acc/desk_mug.svg`: desk props behind the animal. The
   mug is where the held drink rests while typing.
3. `<frame>.svg`: body, head, ears, tail, face. No forearms, no paws.
4. `acc/<head item>.svg` (or `acc/<head item>_sleep.svg` in `sleep`/`wake`): `headphones`, `beanie`,
   `party_hat`, `bow`, `glasses`.
5. `acc/keyboard.svg`.
6. `acc/hold_<item>.svg`: only with `hold`/`sip` (`hold_coffee`, `hold_boba`, `hold_book`). The `sip` frame uses `acc/sip_<item>.svg` (`sip_coffee`, `sip_boba`, `sip_book`: the item raised to the mouth) when the animal provides one, else `hold_<item>`.
7. `<frame>_paws.svg`: forearms and paws, over the keyboard's back edge and around the held item.
8. Overlays: `acc/music_notes.svg` (headphones on and a typing frame), `acc/motion.svg` (`excited`),
   `acc/zzz.svg` (`sleep`).

**Shared fallback:** for any `acc/<name>` an animal doesn't provide, the app and the preview script
use `art/_shared/<name>.svg`. Animals normally provide only their head items (headphones and
friends, fitted to their head) and their own `hold_*`/`sip` item positions if they differ; the
keyboard, desk props and overlays come from `_shared/`.

## Colors

All colors live in two places, and the app substitutes them by exact hex match in one pass:

- **Gear tokens** change with the vibe (theme): `art/_shared/themes.json` lists each token's
  placeholder hex and its value in `dark`, `bright` and `pink`. Placeholder = the dark value, so raw
  SVGs preview in the dark vibe.
- **Fur tokens** belong to the animal and never change with the theme: `art/<animal>/palette.json`
  maps each fur token to the animal's real color. SVGs use the placeholder hex from `themes.json`.
- **Fixed colors** (outline, blush, sparkle cream, item and prop colors, rainbow) are written
  literally and are the same everywhere; see STYLE.md.

### Gear tokens (themes.json)

| Token | Placeholder | Used for |
|---|---|---|
| `gear_line` | `#22252C` | outline of all gear (keyboard, keycaps, headphones). Fur keeps the brown outline. |
| `kb_case` | `#3A3F4B` | keyboard case top face |
| `kb_case_hi` | `#4A505E` | highlight rim on the case top |
| `kb_side` | `#262A33` | case front face |
| `kb_side_dark` | `#1E2129` | case right face |
| `keycap` | `#454B59` | keycap tops |
| `keycap_side` | `#2C313B` | keycap skirts |
| `keycap_legend` | `#B8C0CC` | legend strokes |
| `hp_band` | `#3B414E` | headphone band |
| `hp_cup` | `#474D5A` | headphone outer caps, band highlight |
| `hp_cup_shade` | `#2F333D` | cushions, far cup |
| `hp_glow` | `#9FE8FF` | light inside the cup's rainbow ring |
| `cup_sleeve` | `#565E70` | coffee cup sleeve |

### Fur tokens (palette.json, per animal)

| Token | Placeholder | Typical use |
|---|---|---|
| `fur_main` | `#B07A4A` | main body/head |
| `fur_shade` | `#8A5A33` | the single shade tone of `fur_main` |
| `fur_light` | `#E8C9A0` | belly, muzzle, chest patch, paw pads area |
| `fur_light_shade` | `#D4AE80` | shade on `fur_light` areas |
| `fur_dark` | `#6B4A33` | markings: capybara snout, penguin back, cat stripes, shiba back |
| `fur_dark_shade` | `#553A28` | shade on `fur_dark` areas |
| `feature` | `#E88F7A` | nose, beak, feet, inner ears, tongue |

`palette.json` is a flat object, e.g. `{"fur_main": "#C08A5B", "fur_shade": "#9C6B42", ...}`. Unused
tokens may be omitted. Never use a placeholder hex for anything other than its token.

## Performance

The app rasterizes each layer once per (size, theme, display scale) and only re-blits, so keep each
SVG under ~150 elements.

## Deliverables per animal

`art/<animal>/` with every frame + `_paws` partner, `icon.svg`, `icon_template.svg`, `acc/` (at least
the five head items and their `_sleep` variants; `hold_*` only if the shared positions don't fit),
`palette.json`, and `NOTES.md` (one paragraph on the character's personality and one line per
frame). Run `scripts/render_art.py <animal>` and review `art/<animal>/preview/` (sheet,
accessories, `idle_96.png`, `idle_512.png`, 16 px icons). `scripts/render_art.py --shared` renders
the shared layers to `art/_shared/preview/sheet.png`.
