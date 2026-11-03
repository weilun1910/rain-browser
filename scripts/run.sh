#!/bin/bash
# Builds the app and opens it. Extra arguments go to the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" release
if [ "$#" -gt 0 ]; then
  open "$ROOT/build/BrowserPOC.app" --args "$@"
else
  open "$ROOT/build/BrowserPOC.app"
fi
