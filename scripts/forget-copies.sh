#!/bin/bash
# Makes macOS forget every Rain except one, so Spotlight, the Apps view, the Dock and links all
# open the same copy. It matches Rain's bundle ID and test copies whose IDs start with it, and
# also clears records of copies that were deleted or sit in the Trash. It only touches the
# Launch Services database, never the files.
# Usage: scripts/forget-copies.sh [path to keep]    (default /Applications/Rain.app)
set -euo pipefail
KEEP="${1:-/Applications/Rain.app}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$KEEP/Contents/Info.plist" 2>/dev/null || echo local.browserpoc)"

# lsregister -dump prints one record per bundle, separated by rows of dashes, with "path:" and
# "identifier:" lines. Types like local.browserpoc.item use "type id:" instead, so they don't match.
"$LSREGISTER" -dump 2>/dev/null | awk -v want="$ID" '
  function flush() { if (path != "" && (id == want || index(id, want ".") == 1)) print path; path = ""; id = "" }
  /^-----/ { flush(); next }
  /^path:/ && path == "" { sub(/^path:[ \t]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0; next }
  /^identifier:/ && id == "" { sub(/^identifier:[ \t]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); id = $0; next }
  END { flush() }
' | sort -u | while IFS= read -r p; do
  [ "$p" = "$KEEP" ] && continue
  "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true
  echo "Took $p off the list of apps"
done
