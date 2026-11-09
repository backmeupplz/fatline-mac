#!/bin/bash
# Build Fatline Dev for this Mac, quit any running copy, and open the new one.
# The app uses the connection chosen on its first launch, which Settings can change.
# Set FATLINE_NEYNAR_KEY to replace that connection for one run, which also hides the setting.
# Set FATLINE_FID as well to read an account's public feed without signing in.
# A key only goes in the running app's environment, so it's never built into the app.
set -euo pipefail
cd "$(dirname "$0")/.."

app_name="Fatline Dev"
derived=DerivedData.noindex/Dev
log=DerivedData.noindex/dev.log
app="$derived/Build/Products/Debug/$app_name.app"
mkdir -p DerivedData.noindex

key="${FATLINE_NEYNAR_KEY:-}"
if [ -z "$key" ] && [ -n "${FATLINE_FID:-}" ]; then
  echo "Warning: FATLINE_FID needs FATLINE_NEYNAR_KEY, so the feed can't load."
fi

echo "Building $app_name..."
if ! xcodebuild -project Fatline.xcodeproj -scheme Fatline -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -allowProvisioningUpdates build >"$log" 2>&1; then
  grep -E 'error:|\*\* BUILD' "$log" | tail -20 >&2 || true
  echo "Build failed. Full log: $log" >&2
  exit 1
fi

pkill -x "$app_name" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x "$app_name" >/dev/null || break
  sleep 0.2
done

options=(-n)
if [ -n "$key" ]; then options+=(--env "FATLINE_NEYNAR_KEY=$key"); fi
if [ -n "${FATLINE_FID:-}" ]; then
  open "${options[@]}" "$app" --args -FatlineFID "$FATLINE_FID"
else
  open "${options[@]}" "$app"
fi
echo "$app_name is open."
