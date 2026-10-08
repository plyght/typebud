# typebud character art spec

Every animal is a folder `art/<animal>/` of standalone SVG layers that the app stacks on one
256×256 canvas, swaps between, and lightly transforms (bob, squash, paw offsets). Every animal uses
the same canvas geometry, layer names and draw order, so animals, accessories and themes can be
mixed freely. How things are drawn (line weights, eyes, shading) is in [STYLE.md](STYLE.md); shared
layers live in [`_shared/`](_shared/).

The pose is the same for every animal: a chubby bean-shaped animal in 3/4 view facing slightly to
the viewer's left, sitting behind a compact 60% keyboard. The keyboard is in front of the body, and
the forearms come over its back edge so the paws rest on the back rows of keys.

## Canvas and rendering

- `viewBox="0 0 256 256"`, no `width`/`height` attributes, transparent background.
- The pet is freely resizable, from about **96 px to 512 px** tall on screen (×2 on HiDPI). Art must
  read at 96 px and must not look sparse or blocky at 512 px. Line weights in STYLE.md are chosen
  for that range. Keycap legends, blush hatching and toe lines may vanish below ~160 px; nothing
  else may.
- Everything stays inside the safe box x ∈ [16, 240], y ∈ [24, 240], **strokes included**.
- Allowed: `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `g`, `defs`,
  `linearGradient`, `radialGradient`, `transform` attributes, `fill-opacity` (sparingly).
  Not allowed: filters, masks, clip paths, `<use>`, `<text>`, `<style>`/CSS, `<image>`, external
  references (the app renders through lunasvg). `stroke-dasharray` only in reference files.
- Strokes use `stroke-linejoin="round"` and `stroke-linecap="round"`.
- Keep each SVG under ~150 elements. Many shapes of the same style can share one `<path>` with
  several subpaths (the keyboard draws all 61 keycaps in two paths).
- Gradient ids must be unique per file and prefixed with the file's purpose (`kb-underglow`,
  `hp-ring`) because the app may inline several layers.

## Canvas geometry (shared by every animal)

All numbers are viewBox units. `art/_shared/reference_pose.svg` + `reference_pose_paws.svg` show
them as a placeholder animal with magenta guides; line your animal up with it.

### Desk and keyboard (fixed: everyone uses `_shared/keyboard.svg`)

| Thing | Value |
|---|---|
| Desk line (lowest point of the keyboard) | y = 236 |
| Keyboard case top face, corners | front-left (30,188), front-right (170,224), back-right (220,182), back-left (80,146) |
| Case thickness (front + right faces drop straight down) | 12 → bottom corners (30,200), (170,236), (220,194) |
| Board tilt | front edge rises 14.4° to the left; depth axis points up-right |
| Back edge line | y = 146 + 0.257·(x − 80) (e.g. y = 164 at x = 150) |
| Key grid → canvas | K(s, t) = (37.4, 185.9) + s·(8.84, 2.27) + t·(8.74, −7.34); s = key units from the left (0…15), t = rows from the front (0…5) |
| Rows (front → back) | space row, Shift row, Caps row, Tab row, number row |
| Rainbow underglow | band in the lower half of the front and right faces, fixed gradient |

`scripts/gen_keyboard.py` generates the keyboard from these numbers.

### Animal

| Thing | Value |
|---|---|
| Head center H | (152, 80), may move ±4 in x and y |
| Head radius | rx 54–62, ry 44–52 (head shape, cheeks included). Ears/tufts may rise to y = 24. |
| Face center | x = H.x − 8 (3/4 view facing left). Eye line ≈ H.y + 3; eyes ≈ x 122 and x 165 (40–46 apart, the right one ~2 higher) |
| Blush centers | ≈ (110, 99) and (177, 97) |
| Mouth | ≈ (144, 100) |
| Body | bean, widest x 98–212; its top hides under the head (~y 110); bottom runs behind the keyboard to y ≥ 200 |
| Shoulders (forearms start here) | L (122, 136), R (182, 144) |
| Shade side | right flank and under the head/forearms (light from the upper left) |

"L" and "R" always mean the viewer's left and right.

### Paws (in `<frame>_paws.svg`, drawn after the keyboard)

Each paws layer contains both forearms and both paws. Forearms run from the shoulder over the
keyboard's back edge; the paws sit on the back rows (row 3–4, around the F and J keys).

| State | L paw center | R paw center | Notes |
|---|---|---|---|
| rest (`idle`, `peek`, `sleep`, `wake`) | (122, 168) | (160, 180) | paw ellipse rx 12–14, ry 8.5–10, rotated 14° with the board |
| pressed | rest + (0, 3) | rest + (0, 3) | squash: ry × 0.85, a tiny bit wider |
| raised | rest + (2, −10) | rest + (2, −10) | rotate ~0°, forearm still crosses the back edge |
| `type_left` | pressed | raised | |
| `type_right` | raised | pressed | |
| `type_both` | pressed | pressed | |
| `excited` | rest + (0, −12) | rest + (0, −12) | `_shared/motion.svg` is added on top |
| hug (`hold`) | (148, 152) | (182, 146) | paws wrap the lower front of the held item (`reference_hold_paws.svg`) |
| `sip` | ≈ (136, 128) | ≈ (170, 122) | follow the raised item; adjust to your item position |

With the keyboard turned off, the same paws read as resting on the desk; draw nothing extra.

### Held items (`acc/hold_<item>.svg`)

Held items are hugged with **both** paws in front of the chest, never carried in one paw. Each
shared item is drawn around (0,0) inside one `<g transform="translate(…) rotate(…)">`, so moving it
means editing only that transform.

| Frame | Item anchor | Tilt |
|---|---|---|
| `hold` | translate(164, 140) | coffee/boba 10°, book −8° |
| `sip` | ≈ translate(146, 114) | ≈ −25° (rim/straw touching the mouth); fine-tune per animal |

The item must stay entirely above the keyboard's back edge (bottom ≤ y 164 at x 164). It may overlap
the chin and lower cheek, like holding a cup up close.

### Sleep / wake head

The head (and everything on it) moves by (−4, +12) and rotates −6° about H, i.e.
`transform="translate(-4 12) rotate(-6 152 80)"` → sleeping head center ≈ (148, 92). The body does
not move. `acc/<item>_sleep.svg` use exactly the same transform, so a head item and its sleep variant
are the same drawing in a different group transform.

### Headphones convention

Shared base: `_shared/headphones.svg` (fitted to H = (152,80), rx 58, ry 48). Each animal copies it
to `acc/headphones.svg` and refits it to its own head:

- Near cup (screen right) covers the ear on the head's right edge: outer cap center
  ≈ (H.x + rx, H.y + 7), cap rx 13, ry 22; a cushion ellipse 10 units to its left; rainbow ring on
  the cap face (fixed gradient) with `hp_glow` inside.
- Far cup (screen left) shows only as a crescent outside the head outline, from H.y − 17 to H.y + 21.
- Band: centerline 10–14 units above the skull top, drawn as an outlined stroke (14 wide
  `gear_line` under 6.5 wide `hp_band`), ending in the tops of the two cups. For animals with ears on
  top (cat, shiba), the band sits between/behind the ears: draw the ears in the frame and leave a
  gap in the band where an ear would be in front of it, or route the band behind the ears.

### Decor zones (shared layers; keep animal art out of these where possible)

| Layer | Zone |
|---|---|
| `desk_lamp` | left, x 22–92, y 58–166 (base on the desk behind the keyboard's left end) |
| `desk_plant` | right, x 201–239, y 108–183 |
| `desk_mug` | front right on the desk, x 199–238, y 180–236 |
| `sparkles` | (26, 218), (233, 97), (72, 32) |
| `music_notes` | top right, x 205–240, y 24–70 |
| `zzz` | top left, x 34–90, y 24–70 (in front of the sleeping face) |
| `motion` | short dashes around the two paw rest points |

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
6. `acc/hold_<item>.svg`: only with `hold`/`sip` (`hold_coffee`, `hold_boba`, `hold_book`).
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
