#!/bin/bash
# Builds the app and opens it. Extra arguments go to the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" release
if [ "$#" -gt 0 ]; then
  open "$ROOT/build.noindex/Rain.app" --args "$@"
else
  open "$ROOT/build.noindex/Rain.app"
fi
