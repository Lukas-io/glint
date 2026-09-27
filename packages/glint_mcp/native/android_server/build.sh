#!/usr/bin/env bash
# Builds glint-android-server.dex: javac against the newest android.jar, then d8.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
jar="$(ls -d "$sdk"/platforms/android-*/android.jar | sort -V | tail -1)"
d8="$(ls -d "$sdk"/build-tools/*/d8 | sort -V | tail -1)"
out="$here/build"
rm -rf "$out" && mkdir -p "$out/classes"
javac --release 11 -cp "$jar" -d "$out/classes" $(find "$here/src" -name '*.java')
"$d8" --min-api 26 --lib "$jar" --output "$out" $(find "$out/classes" -name '*.class')
mv "$out/classes.dex" "$out/glint-android-server.dex"
echo "$out/glint-android-server.dex"
