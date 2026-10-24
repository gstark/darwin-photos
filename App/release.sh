#!/bin/bash
# Builds a Release Shoebox.app, publishes it as a GitHub release, and
# updates the cask in the gstark/tap Homebrew tap.
#
#   just homebrew
#
# The version is the CFBundleShortVersionString in App/project.yml plus a
# time stamp, so each release has a new version.
set -euo pipefail

REPO=gstark/shoebox
TAP=gstark/tap
CASK=shoebox
APP_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$APP_DIR/.." && pwd)
STAGED="$ROOT/tmp/install/Shoebox.app"

cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has changes. Commit them first." >&2
  exit 1
fi

base=$(/usr/bin/awk '/CFBundleShortVersionString:/ { gsub(/"/, "", $2); print $2; exit }' "$APP_DIR/project.yml")
version="$base-$(/bin/date +%Y%m%d%H%M)"
zip="$ROOT/tmp/release/Shoebox-$version.zip"

"$APP_DIR/package.sh"

echo "== Publish"
/bin/rm -rf "$ROOT/tmp/release"
/bin/mkdir -p "$ROOT/tmp/release"
/usr/bin/ditto -c -k --keepParent "$STAGED" "$zip"
sha=$(/usr/bin/shasum -a 256 "$zip" | /usr/bin/cut -d' ' -f1)

git push origin "$(git branch --show-current)"
gh release create "v$version" "$zip" -R "$REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "Shoebox $version" \
  --notes "Build of $(git rev-parse --short HEAD)."

echo "== Update the cask"
tap_dir=$(brew --repository "$TAP")
git -C "$tap_dir" pull --ff-only
/bin/mkdir -p "$tap_dir/Casks"
cat > "$tap_dir/Casks/$CASK.rb" <<EOF
cask "$CASK" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$REPO/releases/download/v#{version}/Shoebox-#{version}.zip"
  name "Shoebox"
  desc "Back up iCloud Photos to a drive or S3"
  homepage "https://github.com/$REPO"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Shoebox.app"
  binary "#{appdir}/Shoebox.app/Contents/Helpers/shoebox"

  # The build is signed but not notarized, so remove the quarantine flag to let it open.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Shoebox.app"]
  end

  uninstall quit: "com.gstark.shoebox"
end
EOF
git -C "$tap_dir" add "Casks/$CASK.rb"
git -C "$tap_dir" commit -m "$CASK $version"
git -C "$tap_dir" push

echo "Released $version. Run 'brew install $TAP/$CASK' to install it."
