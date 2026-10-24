#!/bin/bash
# Builds a Release Shoebox.app with the CLI inside it, installs it, and
# links the CLI.
#
#   just install
#
# - The app goes to $APPLICATIONS (default /Applications).
# - $BIN_DIR (default ~/.local/bin) gets a link to the CLI in the app.
set -euo pipefail

APPLICATIONS=${APPLICATIONS:-/Applications}
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
APP_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$APP_DIR/.." && pwd)
STAGED="$ROOT/tmp/install/Shoebox.app"
TARGET="$APPLICATIONS/Shoebox.app"

"$APP_DIR/package.sh"

echo "== Install"
/usr/bin/pkill -x Shoebox || true
/bin/rm -rf "$TARGET"
/bin/cp -R "$STAGED" "$TARGET"
/bin/mkdir -p "$BIN_DIR"
/bin/ln -sf "$TARGET/Contents/Helpers/shoebox" "$BIN_DIR/shoebox"
echo "Installed $TARGET"
echo "Linked $BIN_DIR/shoebox"

if [[ "${OPEN:-1}" == 1 ]]; then
  /usr/bin/open "$TARGET"
fi
