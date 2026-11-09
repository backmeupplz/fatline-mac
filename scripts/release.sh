#!/bin/bash
# Test the committed code, then build a notarized Fatline, ready to upload as a disk image.
# This never uploads the image anywhere. README.md has the one-time Apple setup.
set -euo pipefail
cd "$(dirname "$0")/.."

work=DerivedData.noindex/Release
profile=${FATLINE_NOTARY_PROFILE:-fatline-notary}

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or discard these changes first, so the build matches a commit:" >&2
  git status --short >&2
  exit 1
fi

if [ ! -f Signing.local.xcconfig ]; then
  echo "Copy Signing.local.example.xcconfig to Signing.local.xcconfig and fill it in first." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q 'Developer ID Application'; then
  echo "This Mac has no Developer ID Application certificate. README.md says how to make one." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  echo "The notary login isn't saved as $profile. README.md has the command for it." >&2
  exit 1
fi

rm -rf "$work"
mkdir -p "$work"

echo "Running the tests..."
if ! xcodebuild test -project Fatline.xcodeproj -scheme Fatline \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData.noindex/Tests \
  -allowProvisioningUpdates >"$work/tests.log" 2>&1; then
  grep -E 'error:|failed \(|\*\* TEST' "$work/tests.log" | tail -30 >&2 || true
  echo "Tests failed, so nothing was built. Full log: $work/tests.log" >&2
  exit 1
fi
grep -E 'Executed [0-9]+ test' "$work/tests.log" | tail -1 | sed 's/^[[:space:]]*//' || true

archive="$work/Fatline.xcarchive"
echo "Archiving..."
if ! xcodebuild archive -project Fatline.xcodeproj -scheme Fatline -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath DerivedData.noindex/Archive \
  -allowProvisioningUpdates >"$work/archive.log" 2>&1; then
  grep -E 'error:|\*\* ARCHIVE' "$work/archive.log" | tail -20 >&2 || true
  echo "Archive failed. Full log: $work/archive.log" >&2
  exit 1
fi

echo "Signing with Developer ID..."
if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$work/export" -allowProvisioningUpdates >"$work/export.log" 2>&1; then
  tail -20 "$work/export.log" >&2 || true
  echo "Signing failed. Full log: $work/export.log" >&2
  exit 1
fi

app="$work/export/Fatline.app"
plist="$app/Contents/Info.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = com.example.fatline ]; then
  echo "The app still has the example bundle ID. Set FATLINE_BUNDLE_ID in Signing.local.xcconfig." >&2
  exit 1
fi
if [ ! -f "$app/Contents/embedded.provisionprofile" ]; then
  echo "The app has no provisioning profile, so it couldn't save its posting key." >&2
  exit 1
fi

# The app gets its own ticket first, so it still opens offline once it's out of the disk image.
echo "Notarizing the app, which usually takes a few minutes..."
ditto -c -k --keepParent "$app" "$work/notarize.zip"
xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vvv -t exec "$app"
rm "$work/notarize.zip"

echo "Making the disk image..."
dmg="$work/Fatline.dmg"
stage="$work/dmg"
mkdir "$stage"
ditto "$app" "$stage/Fatline.app"
ln -s /Applications "$stage/Applications"
# Finder's saved window: the app on the left, Applications on the right.
cp scripts/dmg.DS_Store "$stage/.DS_Store"
hdiutil create -quiet -volname Fatline -srcfolder "$stage" -fs APFS -format ULFO "$dmg"
rm -rf "$stage"

identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p')
codesign --sign "$identity" --timestamp "$dmg"

echo "Notarizing the disk image..."
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl -a -vvv -t open --context context:primary-signature "$dmg"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
echo "Ready to upload: $dmg"
echo "Version $version from $(git rev-parse --short HEAD)"
shasum -a 256 "$dmg"
