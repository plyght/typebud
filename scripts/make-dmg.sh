#!/bin/bash
# Build the typebud macOS disk image with built-in tools only (hdiutil, Finder via osascript,
# tiffutil, ditto).
#
#   scripts/make-dmg.sh <path/to/Typebud.app> <version> [<out dir>]
#     -> <out dir, default dist>/Typebud-<version>.dmg
#
# The window: packaging/macos/dmg-background{,@2x}.png (rendered by
# scripts/render_installer_art.py) as a HiDPI TIFF, 128 pt icons, Typebud.app on the left and
# an /Applications link on the right at the slots the background is drawn around, no
# toolbar/sidebar/status bar, the app icon as the volume icon, volume name "typebud".
#
# Env: DMG_FORMAT (default ULFO; UDZO for older macOS), DMG_KEEP_RW=1 keeps the writable image.
# Needs a logged-in GUI session (Finder lays out the window); GitHub's macOS runners have one.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <path/to/Typebud.app> <version> [<out dir>]" >&2
  exit 2
fi
app=$1
version=${2#v}
root=$(cd "$(dirname "$0")/.." && pwd)
out_dir=${3:-$root/dist}
format=${DMG_FORMAT:-ULFO}
volname=typebud
app_name=Typebud.app

# Finder coordinates (points); must match scripts/render_installer_art.py.
win_w=660 win_h=400
app_x=180 apps_x=480 icon_y=190
icon_size=128

[ -d "$app/Contents/MacOS" ] || { echo "error: $app is not an app bundle" >&2; exit 1; }
case $version in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "error: version '$version' is not semver" >&2; exit 1 ;;
esac
bg1=$root/packaging/macos/dmg-background.png
bg2=$root/packaging/macos/dmg-background@2x.png
[ -f "$bg1" ] && [ -f "$bg2" ] || { echo "error: missing $bg1 / $bg2 (run scripts/render_installer_art.py)" >&2; exit 1; }

mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
dmg=$out_dir/Typebud-$version.dmg
work=$(mktemp -d "${TMPDIR:-/tmp}/typebud-dmg.XXXXXX")
mnt=""
dev=""
cleanup() {
  if [ -n "$dev" ]; then hdiutil detach "$dev" -force -quiet 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

# 1. Staging folder.
stage=$work/stage
mkdir -p "$stage/.background"
ditto "$app" "$stage/$app_name"
ln -s /Applications "$stage/Applications"
tiffutil -cathidpicheck "$bg1" "$bg2" -out "$stage/.background/background.tiff" >/dev/null
cp "$app/Contents/Resources/typebud.icns" "$stage/.VolumeIcon.icns"

# 2. Writable image, sized to the content plus headroom.
size_mb=$(( $(du -sm "$stage" | cut -f1) + 32 ))
rw=$work/rw.dmg
hdiutil create -quiet -srcfolder "$stage" -volname "$volname" -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
  -format UDRW -size "${size_mb}m" "$rw"

# Finder addresses the disk by name: make sure no other "typebud" volume is mounted.
for v in /Volumes/"$volname" /Volumes/"$volname "[0-9]*; do
  [ -d "$v" ] && hdiutil detach "$v" -force -quiet || true
done

# 3. Mount and let Finder lay the window out (it writes .DS_Store).
attach=$(hdiutil attach -readwrite -noverify -noautoopen "$rw")
dev=$(echo "$attach" | awk '/Apple_HFS/ {print $1; exit}')
mnt=$(echo "$attach" | awk -F'\t' '/Apple_HFS/ {print $NF; exit}')
[ -n "$dev" ] && [ -d "$mnt" ] || { echo "error: could not mount $rw" >&2; echo "$attach" >&2; exit 1; }
echo "mounted $dev at $mnt"

# Custom volume icon: set the volume root's kHasCustomIcon Finder flag.
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$mnt"
else
  xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$mnt"
fi

# bounds include the title bar; with the toolbar hidden the content area is win_w x win_h.
left=200 top=120
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volname"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$left, $top, $((left + win_w)), $((top + win_h + 28))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $icon_size
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set shows icon preview of opts to true
    set background picture of opts to file ".background:background.tiff"
    set position of item "$app_name" of container window to {$app_x, $icon_y}
    set position of item "Applications" of container window to {$apps_x, $icon_y}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

for _ in $(seq 1 20); do
  [ -f "$mnt/.DS_Store" ] && break
  sleep 0.5
done
[ -f "$mnt/.DS_Store" ] || { echo "error: Finder did not write .DS_Store (window layout missing)" >&2; exit 1; }

# 4. Tidy, flush, detach.
rm -rf "$mnt/.fseventsd" "$mnt/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$mnt" 2>/dev/null || true
sync
for i in 1 2 3 4 5; do
  if hdiutil detach "$dev" -quiet; then dev=""; break; fi
  sleep $((i * 2))
done
if [ -n "$dev" ]; then hdiutil detach "$dev" -force -quiet; dev=""; fi

# 5. Compress.
rm -f "$dmg"
case $format in
  UDZO) hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" ;;
  *) hdiutil convert -quiet "$rw" -format "$format" -o "$dmg" ;;
esac
if [ "${DMG_KEEP_RW:-0}" = 1 ]; then cp "$rw" "$out_dir/Typebud-$version-rw.dmg"; fi
hdiutil verify -quiet "$dmg"
echo "wrote $dmg ($(du -h "$dmg" | cut -f1))"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "dmg=$dmg" >> "$GITHUB_OUTPUT"; fi
