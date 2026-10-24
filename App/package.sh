#!/bin/bash
# Builds a Release Shoebox.app with the CLI inside it, signs both, and
# copies the app to tmp/install/Shoebox.app.
#
#   App/package.sh
#
# - The CLI is Contents/Helpers/shoebox inside the app. It cannot go in
#   Contents/MacOS: the file system ignores case, so "shoebox" would replace
#   the app binary "Shoebox".
# - Both are signed with the Apple Development certificate, so Full Disk
#   Access and Keychain access stay valid between installs.
set -euo pipefail

IDENTITY=${SIGNING_IDENTITY:-D0CBC10CDDBA0EE84D8DFDDF98BB308A1DAC7A1B}
APP_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$APP_DIR/.." && pwd)
DERIVED="$APP_DIR/.build/DerivedData"
ENTITLEMENTS="$APP_DIR/Shoebox/Shoebox.entitlements"
STAGED="$ROOT/tmp/install/Shoebox.app"

echo "== Build the CLI"
cd "$ROOT"
swift build -c release --product shoebox 2>&1 | /usr/bin/tail -1
CLI="$(swift build -c release --show-bin-path)/shoebox"

echo "== Build the app"
# Drops the warnings and debug lines from package checkouts, such as the
# AWS SDK build plugin. Errors and warnings in our code stay.
hide_package_noise() {
  /usr/bin/awk '
    /\/SourcePackages\/checkouts\// { skip = 1 }
    skip && /^$/ { skip = 0; next }
    skip || /^\[debug\]:/ || /^\[#[A-Za-z]+\]:/ || /IDERunDestination/ || /^--- xcodebuild: WARNING/ || /^\{ platform:/ { next }
    { print }
  '
}

cd "$APP_DIR"
xcodegen generate --quiet
# The AWS SDK uses a build plugin. Xcode otherwise asks to trust it.
xcodebuild -project Shoebox.xcodeproj -scheme ShoeboxApp -configuration Release \
  -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=arm64" \
  -skipPackagePluginValidation -skipMacroValidation -quiet build 2>&1 | hide_package_noise

echo "== Sign"
/bin/rm -rf "$STAGED"
/bin/mkdir -p "$(dirname "$STAGED")"
/bin/cp -R "$DERIVED/Build/Products/Release/Shoebox.app" "$STAGED"
/bin/mkdir -p "$STAGED/Contents/Helpers"
/bin/cp "$CLI" "$STAGED/Contents/Helpers/shoebox"
# Sign the CLI before the app, because the app signature covers it. The CLI
# uses PhotoKit too, so it needs the same entitlements.
/usr/bin/codesign --force --options runtime --timestamp=none --identifier com.gstark.shoebox.cli \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGED/Contents/Helpers/shoebox"
/usr/bin/codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGED"
/usr/bin/codesign --verify --strict "$STAGED"
