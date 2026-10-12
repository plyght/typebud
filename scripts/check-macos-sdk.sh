#!/bin/sh
# Fails unless every slice of a macOS binary declares minos 12.0 and an SDK >= 26.0
# (LC_BUILD_VERSION). AppKit gives the macOS 26 design (Liquid Glass controls, sidebar
# and window chrome) only to binaries linked on or after the 26 SDK; see
# packaging/macos_sdk.zig.
#   scripts/check-macos-sdk.sh zig-out/bin/typebud [Typebud.app/Contents/MacOS/typebud ...]
set -eu
echo "build machine SDK: $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo none)"
status=0
for bin in "$@"; do
  for arch in $(lipo -archs "$bin"); do
    info=$(otool -arch "$arch" -l "$bin" | awk '/cmd LC_BUILD_VERSION/ {f=1} f && $1=="minos" {m=$2} f && $1=="sdk" {print m, $2; exit}')
    minos=${info% *} sdk=${info#* }
    echo "$bin ($arch): minos $minos sdk $sdk"
    major=${sdk%%.*}
    case "$major" in ''|*[!0-9]*) major=0 ;; esac
    if [ -z "$info" ] || [ "$minos" != "12.0" ] || [ "$major" -lt 26 ]; then
      echo "::error::$bin ($arch) declares minos '$minos' sdk '$sdk' (want minos 12.0, sdk >= 26.0)"
      status=1
    fi
  done
done
exit $status
