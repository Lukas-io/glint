#!/usr/bin/env bash
set -euo pipefail
platform="$1"
device="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"
log="$root/device-check-flutter-run.log"

(cd "$root/fixtures/counter_app" && flutter run -d "$device" > "$log" 2>&1) &
run_pid=$!
trap 'status=$?; kill "$run_pid" 2>/dev/null || true; exit $status' EXIT

deadline=$((SECONDS + 1200))
until grep -qE 'is available at: http' "$log"; do
  if ! kill -0 "$run_pid" 2>/dev/null; then echo "flutter run exited early"; tail -50 "$log"; exit 1; fi
  if [ $SECONDS -gt $deadline ]; then echo "app did not start within 20 minutes"; tail -50 "$log"; exit 1; fi
  sleep 5
done
vm_uri="$(grep -m1 -oE 'http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9_=+/-]+/' "$log")"
echo "app running, VM service at $vm_uri"

cd "$root"
if [ "$platform" = android ]; then
  dart run tool/device_check.dart --platform android --device "$device" --vm-uri "$vm_uri" \
    --adb-path "${ANDROID_HOME:-$ANDROID_SDK_ROOT}/platform-tools/adb"
else
  dart run tool/device_check.dart --platform "$platform" --device "$device" --vm-uri "$vm_uri"
fi
