#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/.build/glint-siminject.dylib}"
mkdir -p "$(dirname "$out")"
log="$(mktemp)"
tmp="$out.building.$$"
trap 'rm -f "$log" "$tmp"' EXIT
fail() {
  cat "$log" >&2
  exit 1
}
xcrun --sdk iphonesimulator clang -arch arm64 -arch x86_64 -mios-simulator-version-min=15.0 \
  -dynamiclib -fobjc-arc -fmodules \
  -framework Foundation -framework AVFoundation -framework CoreImage -framework UIKit \
  -framework CoreMedia -framework CoreVideo -framework ImageIO \
  -install_name @rpath/glint-siminject.dylib -o "$tmp" "$here"/*.m >"$log" 2>&1 || fail
codesign -f -s - "$tmp" >"$log" 2>&1 || fail
codesign -v "$tmp" >"$log" 2>&1 || fail
mv -f "$tmp" "$out"
echo "$out"
