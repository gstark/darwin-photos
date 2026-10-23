#!/bin/bash
# Builds Shoebox.app, signs it with the Apple Development certificate,
# and copies it to tmp/Shoebox.app.
#
#   App/build.sh [--open]
#
# The signature must stay the same between builds. macOS ties Full Disk Access
# and Keychain access to it.
set -euo pipefail

# SHA-1 of the valid "Apple Development: Gavin Stark (UW3ZHT9E8E)" certificate.
# A revoked certificate has the same name, so the name alone is ambiguous.
IDENTITY=${SIGNING_IDENTITY:-D0CBC10CDDBA0EE84D8DFDDF98BB308A1DAC7A1B}
APP_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$APP_DIR/.." && pwd)
DERIVED="$APP_DIR/.build/DerivedData"
APP="$ROOT/tmp/Shoebox.app"

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
xcodebuild -project Shoebox.xcodeproj -scheme ShoeboxApp -configuration Debug \
  -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=arm64" \
  -skipPackagePluginValidation -skipMacroValidation -quiet build 2>&1 | hide_package_noise

# Quit a running copy, so that the new build starts.
/usr/bin/pkill -x Shoebox || true
/bin/mkdir -p "$ROOT/tmp"
/bin/rm -rf "$APP"
/bin/cp -R "$DERIVED/Build/Products/Debug/Shoebox.app" "$APP"
/usr/bin/codesign --force --options runtime --timestamp=none \
  --entitlements "$APP_DIR/Shoebox/Shoebox.entitlements" --sign "$IDENTITY" "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
  /usr/bin/open "$APP"
fi
