#!/bin/bash
# Looks for the files behind the Messages assets (ZSAVEDASSETTYPE = 12).
# Reads only. Run from a terminal that has Full Disk Access:
#   scripts/messages-check.sh
# A failed query does not stop the other checks.
set -uo pipefail

LIBRARY="$HOME/Pictures/Photos Library.photoslibrary"
SYNDICATION="$HOME/Library/Photos/Libraries/Syndication.photoslibrary"
db() { echo "file:${1// /%20}/database/Photos.sqlite?immutable=1"; }
# -init /dev/null ignores ~/.sqliterc.
sql() { /usr/bin/sqlite3 -init /dev/null -readonly -header -column "$(db "$LIBRARY")" "$@"; }
TYPE12="a.ZSAVEDASSETTYPE = 12 AND a.ZTRASHEDSTATE = 0"

echo "== Assets by ZSAVEDASSETTYPE"
sql "SELECT ZSAVEDASSETTYPE AS type, count(*) AS assets FROM ZASSET WHERE ZTRASHEDSTATE = 0 GROUP BY 1"

echo ""
echo "== Messages assets by kind, cloud state, and year"
sql "SELECT a.ZKIND AS kind, a.ZCLOUDLOCALSTATE AS cloud_state, strftime('%Y', a.ZDATECREATED + 978307200, 'unixepoch') AS year, count(*) AS assets FROM ZASSET a WHERE $TYPE12 GROUP BY 1, 2, 3"

echo ""
echo "== Resources of the Messages assets"
sql "SELECT r.ZRESOURCETYPE AS type, r.ZLOCALAVAILABILITY AS local, r.ZREMOTEAVAILABILITY AS remote, (r.ZFINGERPRINT IS NOT NULL AND r.ZFINGERPRINT != '') AS fingerprint, count(*) AS resources, sum(r.ZDATALENGTH) AS bytes FROM ZINTERNALRESOURCE r JOIN ZASSET a ON r.ZASSET = a.Z_PK WHERE $TYPE12 GROUP BY 1, 2, 3, 4"

echo ""
echo "== 5 samples"
sql "SELECT a.ZUUID AS uuid, a.ZDIRECTORY AS directory, a.ZFILENAME AS filename, aa.ZORIGINALFILENAME AS original, cm.ZCLOUDMASTERGUID AS master FROM ZASSET a LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON a.ZADDITIONALATTRIBUTES = aa.Z_PK LEFT JOIN ZCLOUDMASTER cm ON a.ZMASTER = cm.Z_PK WHERE $TYPE12 LIMIT 5"

echo ""
echo "== Files in the library originals folder"
found=0; missing=0
while IFS=$'\t' read -r directory filename; do
  if [ -f "$LIBRARY/originals/$directory/$filename" ]; then found=$((found + 1)); else missing=$((missing + 1)); fi
done < <(/usr/bin/sqlite3 -init /dev/null -readonly -list -noheader -separator $'\t' "$(db "$LIBRARY")" "SELECT a.ZDIRECTORY, a.ZFILENAME FROM ZASSET a WHERE $TYPE12")
echo "found: $found, missing: $missing"

echo ""
echo "== Syndication library (Shared with You)"
if [ ! -d "$SYNDICATION" ]; then
  echo "no syndication library"
  exit 0
fi
/usr/bin/du -sh "$SYNDICATION"
ssql() { /usr/bin/sqlite3 -init /dev/null -readonly -header -column "$(db "$SYNDICATION")" "$@"; }
IN=$(/usr/bin/sqlite3 -init /dev/null -readonly -list -noheader "$(db "$LIBRARY")" "SELECT a.ZUUID FROM ZASSET a WHERE $TYPE12" | /usr/bin/sed "s/.*/'&'/" | /usr/bin/paste -sd, -)

echo ""
echo "== Syndication assets by ZSAVEDASSETTYPE, kind, and trash state"
ssql "SELECT ZSAVEDASSETTYPE AS type, ZKIND AS kind, ZTRASHEDSTATE AS trashed, count(*) AS assets FROM ZASSET GROUP BY 1, 2, 3"

for scope in "the 257 Messages assets:a.ZUUID IN ($IN)" "all syndication assets:1"; do
  label=${scope%%:*}; where=${scope#*:}
  echo ""
  echo "== Original resources of $label"
  ssql "SELECT r.ZRESOURCETYPE AS type, r.ZLOCALAVAILABILITY AS local, count(*) AS resources, sum(r.ZDATALENGTH) AS bytes FROM ZINTERNALRESOURCE r JOIN ZASSET a ON r.ZASSET = a.Z_PK WHERE ($where) AND r.ZRESOURCETYPE = (CASE WHEN a.ZKIND = 1 THEN 1 ELSE 0 END) GROUP BY 1, 2"
  echo "== Files in the syndication originals folder for $label"
  found=0; missing=0
  while IFS=$'\t' read -r directory filename; do
    if [ -f "$SYNDICATION/originals/$directory/$filename" ]; then found=$((found + 1)); else missing=$((missing + 1)); fi
  done < <(/usr/bin/sqlite3 -init /dev/null -readonly -list -noheader -separator $'\t' "$(db "$SYNDICATION")" "SELECT a.ZDIRECTORY, a.ZFILENAME FROM ZASSET a WHERE $where")
  echo "found: $found, missing: $missing"
done

echo ""
echo "== Top folders in the syndication library"
/usr/bin/du -sh "$SYNDICATION"/* 2>/dev/null | /usr/bin/sort -rh | /usr/bin/head -8
