#!/bin/bash
# Moves the Darwin Photos app data to Shoebox. Run it one time, before the
# first `make install` of Shoebox:
#   scripts/migrate-to-shoebox.sh
#
# 1. Quits and deletes /Applications/DarwinPhotos.app and its CLI link.
# 2. Copies config.json, failures.db, and history.json from ~/.darwin-photos
#    to ~/.shoebox. The Go tool still uses ~/.darwin-photos, so the files
#    stay there too. A file that is already in ~/.shoebox is not replaced.
# 3. Copies the iCloud session and the AWS access key to the Shoebox Keychain
#    service. macOS can ask to allow access to the iCloud session.
# 4. Copies the app preferences (the notification level).
# 5. Removes the macOS permissions of the old app.
#
# The old Keychain items stay. Delete them after Shoebox works:
#   security delete-generic-password -s com.gstark.darwin-photos -a icloud-session
#   security delete-generic-password -s com.gstark.darwin-photos -a aws-access-key
set -euo pipefail

OLD_ID=com.gstark.darwin-photos
NEW_ID=com.gstark.shoebox
OLD_APP=/Applications/DarwinPhotos.app
OLD_LINK="$HOME/.local/bin/darwin-photos"
OLD_DIR="$HOME/.darwin-photos"
NEW_DIR="$HOME/.shoebox"

echo "== Old app"
/usr/bin/pkill -x DarwinPhotos || true
if [ -d "$OLD_APP" ]; then
  /bin/rm -rf "$OLD_APP"
  echo "Deleted $OLD_APP."
fi
if [ -L "$OLD_LINK" ]; then
  /bin/rm "$OLD_LINK"
  echo "Deleted the link $OLD_LINK."
fi

echo ""
echo "== Files"
/bin/mkdir -p "$NEW_DIR"
for NAME in config.json failures.db history.json; do
  if [ ! -e "$OLD_DIR/$NAME" ]; then
    echo "Skipped $NAME: not in $OLD_DIR."
  elif [ -e "$NEW_DIR/$NAME" ]; then
    echo "Skipped $NAME: already in $NEW_DIR."
  else
    /bin/cp -p "$OLD_DIR/$NAME" "$NEW_DIR/$NAME"
    echo "Copied $NAME."
  fi
done

echo ""
echo "== Keychain"
copy_item() {
  local account=$1 label=$2 value
  if ! value=$(/usr/bin/security find-generic-password -s "$OLD_ID" -a "$account" -w 2> /dev/null); then
    echo "Skipped $account: not in the Keychain."
    return
  fi
  /usr/bin/security add-generic-password -U -s "$NEW_ID" -a "$account" -l "$label" -w "$value"
  echo "Copied $account."
}
copy_item icloud-session "shoebox iCloud session"
copy_item aws-access-key "shoebox AWS access key"

echo ""
echo "== Preferences"
if /usr/bin/defaults export "$OLD_ID" - > /dev/null 2>&1; then
  /usr/bin/defaults export "$OLD_ID" - | /usr/bin/defaults import "$NEW_ID" -
  /usr/bin/defaults delete "$OLD_ID"
  echo "Copied the preferences."
else
  echo "Skipped: no preferences."
fi

echo ""
echo "== Permissions"
/usr/bin/tccutil reset All "$OLD_ID" > /dev/null
echo "Removed the permissions of $OLD_ID."

echo ""
echo "Next: run make install. Then grant the permissions to Shoebox."
