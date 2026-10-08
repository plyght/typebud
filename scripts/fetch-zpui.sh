#!/bin/sh
# Check out zpui (github.com/plyght/zpui) at the commit build.zig pins, into ./zpui.
# typebud depends on it as a path dependency (build.zig.zon).
set -eu
cd "$(dirname "$0")/.."
rev=$(sed -n 's/^pub const zpui_commit = "\([0-9a-f]*\)";/\1/p' build.zig)
if [ -e zpui/.git ] || [ -L zpui ]; then
  echo "zpui/ already present; checking out $rev"
  git -C zpui fetch --quiet origin "$rev" 2>/dev/null || true
  git -C zpui checkout --quiet "$rev"
  exit 0
fi
git init --quiet zpui
git -C zpui remote add origin https://github.com/plyght/zpui.git
git -C zpui fetch --quiet --depth 1 origin "$rev"
git -C zpui checkout --quiet FETCH_HEAD
echo "zpui checked out at $rev"
