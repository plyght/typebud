# typebud style guide

Cozy, hand-drawn sticker style: chubby bean animals with thick round dark-brown outlines, flat soft
fills with exactly one shade tone, closed content eyes, tiny mouth, pink blush, and cream
4-point sparkles. Everything is drawn on the shared 256×256 canvas in [SPEC.md](SPEC.md). Follow
these rules literally; when in doubt, look at the files in `_shared/` and their preview in
`_shared/preview/sheet.png`.

The pet is shown anywhere from **96 px to 512 px** tall (×2 on HiDPI). At 96 px, 1 viewBox unit ≈
0.375 px; at 512 px, 1 unit = 2 px. The weights below are chosen so outlines still read at 96 px
(5 units ≈ 1.9 px) and look like confident marker lines at 512 px (10 px) without looking blocky.

## Line work

| Weight (viewBox units) | Use |
|---|---|
| **5** | Animal silhouette: head, body, ears, tail, forearm contours. |
| **4.5** | Eyes, paws, gear and prop silhouettes (keyboard case, headphones, cups, pot, lamp). |
| **3.5** | Mouth, nose, inner ear lines, arm/belly creases, sparkles, small parts on items. |
| **3** | Smallest line that must still read at 96 px (tiny sparkles, z's, whiskers). |
| 2–2.5 | Toe lines, blush hatching, keycap outlines, page lines. Allowed to vanish below ~160 px. |
| 1.6 | Keycap legends only. |

- Outline color for animals, items, props, sparkles and overlays: **`#3B2A1E`** (warm dark brown),
  never black. Gear (keyboard, keycaps, headphones) uses the theme token `gear_line` instead, so the
  white and pink vibes get soft grey/pink lines like the inspiration.
- Always `stroke-linecap="round"` and `stroke-linejoin="round"`. No sharp corners anywhere: round
  polygon corners (quadratic corner curves, 2–4 units) or use curves.
- Strokes are centered on the path, so half the width sits outside the shape. Keep the outer edge
  inside the safe box (x 16–240, y 24–240).
- A line that ends inside a fill (a forearm melting into the body, a chin crease) is an **open
  path** drawn after the fill; don't close it across the joint.
- Never scale a group that contains strokes (`scale()` would change the line weight). Move and
  rotate only.

## Color and shading

- Flat fills only. Each colored area gets **one** shade tone (`fur_shade`, `fur_light_shade`, …),
  no gradients on the animal. Gradients are reserved for the fixed rainbow (keyboard underglow,
  headphone ring).
- **Light comes from the upper left.** Shade goes on the right flank, under the head (chin shadow
  on the chest), under the forearms, and on the right side of items/props.
- Shade is a separate flat shape with **no stroke**, drawn between the fill and the outline:
  1. the shape's fill (no stroke),
  2. the shade shape, which may run past the edge (the outline covers it),
  3. the same shape again as `fill="none"` with the outline stroke.

  Alternatively keep the shade shape strictly inside the fill and stroke the fill in step 1.
- Fur colors are fixed per animal (`palette.json`); they never change with the theme.

Fixed colors (write them literally; same in every animal and theme):

| Color | Hex |
|---|---|
| outline | `#3B2A1E` |
| blush | `#F4A6A0` |
| blush hatch | `#E07F7A` |
| eye shine / highlights | `#FFFFFF` |
| cream (sparkles, notes, z's, motion core) | `#FBE3A0` |
| rainbow stops | `#4FC3F7 #7C6CFF #E86BD8 #FF5C6C #FFA24C #FFE45C #5EE08A` |
| cup / pages | `#FFF8EE`, shade `#EADCC8`, lid `#F1E4D2` |

## Proportions and pose

- Chibi: the head is big (≈ 1.0–1.15× the body's width) and slightly wider than tall; the body is a
  soft bean that leans a touch to the right behind the keyboard.
- 3/4 view facing the viewer's left: the face sits 8 units left of the head center, the left eye
  is a little lower and the right eye a little higher (2 units), and the right side of the head
  (with the near ear / headphone cup) shows more.
- Forearms are short and chubby (18–24 wide), come from the shoulders, cross the keyboard's back
  edge and end in small oval paws on the back rows. No fingers; two short toe lines per paw.

## Faces

All eye lines are 4.5 wide. Eye centers ≈ (122, 84) and (165, 82) (SPEC "Animal").

| State | Eyes |
|---|---|
| default (`idle`, `type_*`, `hold`) | **content** "— —": short lines, 14–16 long, with a very slight downward sag (control point 1.5 lower). |
| `peek` | **open**: solid outline-colored ovals rx 3.6, ry 4.6, with a white shine dot r 1.4 up-left. |
| `excited`, `sip` | **happy** "^ ^": arcs bulging upward, 14 wide, 8 tall. |
| `sleep` | **sleepy**: arcs bulging downward ("u"), 14 wide, 6 deep. |
| `wake` | left eye open (peek oval), right eye sleepy arc. |

Mouths are tiny (8–16 wide, 3.5 lines): a small smile arc by default, a "w" for cats/capybara-ish
muzzles if the species reads better that way, a small open "D" filled with `feature` for excited.

```svg
<!-- content eye -->
<path d="M115 84 Q122.5 85.5 130 84" fill="none" stroke="#3B2A1E" stroke-width="4.5" stroke-linecap="round"/>
<!-- open eye (peek) -->
<ellipse cx="122" cy="84" rx="3.6" ry="4.6" fill="#3B2A1E"/>
<circle cx="120.8" cy="82.2" r="1.4" fill="#FFFFFF"/>
<!-- happy eye -->
<path d="M115 87 Q122 78 129 87" fill="none" stroke="#3B2A1E" stroke-width="4.5" stroke-linecap="round"/>
<!-- sleepy eye -->
<path d="M115 82 Q122 89 129 82" fill="none" stroke="#3B2A1E" stroke-width="4.5" stroke-linecap="round"/>
<!-- small smile / open excited mouth -->
<path d="M140 99 Q144 103 148 99" fill="none" stroke="#3B2A1E" stroke-width="3.5" stroke-linecap="round"/>
<path d="M138 98 L150 98 Q150 108 144 108 Q138 108 138 98 Z" fill="#E88F7A" stroke="#3B2A1E" stroke-width="3.5" stroke-linejoin="round"/>
```

### Blush

Soft pink oval under each eye, rx 8, ry 4.5, no outline, plus three tiny slanted hatch strokes
(they vanish at small sizes, which is fine):

```svg
<ellipse cx="110" cy="99" rx="8" ry="4.5" fill="#F4A6A0"/>
<path d="M106 101 L108 97 M109.5 101.5 L111.5 97.5 M113 101 L115 97" stroke="#E07F7A" stroke-width="1.6" stroke-linecap="round"/>
```

## Paws and forearms

Fill first, then an open outline (so the shoulder end melts into the body), then the paw on top.

```svg
<!-- forearm (L) -->
<path d="M110 134 C104 148 105 162 110 172 L134 170 C132 160 133 148 138 138 Z" fill="#B07A4A"/>
<path d="M110 134 C104 148 105 162 110 172 M134 170 C132 160 133 148 138 138" fill="none" stroke="#3B2A1E" stroke-width="5" stroke-linecap="round"/>
<!-- paw at the L rest point, tilted 14deg with the keyboard, two toe lines -->
<ellipse cx="122" cy="168" rx="13" ry="9" transform="rotate(14 122 168)" fill="#B07A4A" stroke="#3B2A1E" stroke-width="4.5"/>
<path d="M116 173 L117 176.5 M124 174.5 L125 178" stroke="#3B2A1E" stroke-width="2.5" stroke-linecap="round"/>
```

Pressed paws squash (ry × 0.85) and drop 3 units; raised paws lift 10 units and lose the tilt.
`_shared/reference_pose_paws.svg` and `reference_hold_paws.svg` are working examples.

## Sparkles and overlays

4-point stars made of four quadratic curves, cream fill, outline 3–3.5 (2.8 for the tiny one):

```svg
<path d="M26 206 Q27.5 216.5 36 218 Q27.5 219.5 26 230 Q24.5 219.5 16 218 Q24.5 216.5 26 206 Z" fill="#FBE3A0" stroke="#3B2A1E" stroke-width="3.5" stroke-linejoin="round"/>
```

- Sizes: big 20–24 across, medium 12–16, tiny 8–10. Never more than three in a layer.
- **Motion marks** (`_shared/motion.svg`): short straight dashes (6–8 long) radiating from the paws,
  drawn as an "outlined stroke" (7-wide outline under a 2.6-wide cream core) so they read on fur,
  desk and every keyboard theme. Never speed lines across the body.
- **Z's** and **music notes**: cream fill with outline, like sparkles; note stems are outlined
  strokes.
- Overlays are shared; animals don't redraw them.

## Gear and items

- Gear (keyboard, headphones, coffee sleeve) uses theme tokens only (SPEC "Gear tokens"). Never
  put a fur token or a literal color on gear, except the fixed rainbow.
- Outlined strokes for bands and arms: a wide `gear_line`/outline stroke under a narrower colored
  stroke on the same path (headphone band 14/6.5, lamp arm 10/4).
- Held items are hugged with both paws in front of the chest (SPEC "Held items"); keep the shared
  item drawings and only change their group `transform`.

## Do / don't

Do:
- Keep every shape soft and rounded; chubby and cozy beats anatomically right.
- Keep the same outline weight on every animal so they look like one sticker set.
- Check `idle_96.png` (does the face still read?) and `idle_512.png` (do lines look confident,
  not blocky?) after every change.
- Reuse coordinates from `_shared/reference_pose*.svg` before inventing new ones.

Don't:
- No black (`#000000`) lines (except `icon_template.svg`), no pure-white fills on fur.
- No gradients, opacity, or soft shadows on the animal; no drop shadows anywhere.
- No hairlines (< 2 units) except keycap legends; no detail that only works at 512 px.
- No open-mouth smiles or open eyes in the default face; the resting face is calm and content.
- No text glyphs: legends, logos and z's are drawn shapes.
- Don't redraw the keyboard, desk props or overlays per animal; use `_shared/`.
- Don't let paws, ears or held items poke outside the safe box.

## Icons

`icon.svg` is the face only: head, ears and features scaled up so the head fills x 16–240. Line
weight scales up too: outline ≥ 16 units and eyes ≥ 18 units (≈ 1 px at 16×16); drop blush hatching,
toe lines and any detail under 16 units. `icon_template.svg` is the same silhouette in `#000000`
with eyes/mouth cut out as even-odd holes (`fill-rule="evenodd"`), no strokes.
