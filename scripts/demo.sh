#!/bin/bash
# Builds the app, seeds the demo profile if there isn't one yet, and opens the app on it.
# The demo is a made-up student's browser: notes, Google Docs, Notion pages, Granola meetings,
# six weeks of history and four spaces. See Demo/SCENARIOS.md for what to try.
#
# Usage: scripts/demo.sh [--reset] [--seed-only] [--offline] [--no-build] [--models <dir>] [--profile <dir>]
#   --reset      seed again from scratch. Anything changed in the demo profile is lost.
#   --seed-only  seed, don't open the app.
#   --offline    don't fetch page text or site icons. Pages use their stored excerpts.
#   --models     a folder with the verified model files to copy in. Without it, the app
#                downloads them on first launch.
#   --profile    where the demo profile lives. By default demo-profile.nosync in the project folder.
#
# It only ever writes to an empty folder or to a demo profile it made before, and never to
# ~/Library/Application Support/BrowserPOC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The project folder holds app.nosync. Worktrees live further down inside it.
project="$ROOT"
while [ "$project" != "/" ] && [ "$(basename "$project")" != "app.nosync" ]; do project="$(dirname "$project")"; done
if [ "$project" = "/" ]; then project="$(dirname "$ROOT")"; else project="$(dirname "$project")"; fi

PROFILE="$project/demo-profile.nosync"
MODELS="${DEMO_MODELS_DIR:-}"
reset=0; seed_only=0; offline=0; build=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reset) reset=1 ;;
    --seed-only) seed_only=1 ;;
    --offline) offline=1 ;;
    --no-build) build=0 ;;
    --models) MODELS="$2"; shift ;;
    --profile) PROFILE="$2"; shift ;;
    *) echo "Unknown option $1. See the top of scripts/demo.sh." >&2; exit 2 ;;
  esac
  shift
done

REAL="$HOME/Library/Application Support/BrowserPOC"
case "$PROFILE/" in
  "$REAL/"*) echo "Refusing: $PROFILE is the app's real support folder." >&2; exit 1 ;;
esac
case "$REAL/" in
  "$PROFILE/"*) echo "Refusing: $PROFILE holds the app's real support folder." >&2; exit 1 ;;
esac

MARKER="$PROFILE/.rain-demo-profile"
need_seed=0
if [ ! -e "$PROFILE" ]; then
  need_seed=1
elif [ -f "$MARKER" ]; then
  if [ "$reset" = 1 ] || ! grep -q '"complete" : true' "$MARKER"; then need_seed=1; fi
elif [ -z "$(ls -A "$PROFILE" | grep -v '^.DS_Store$' || true)" ]; then
  need_seed=1
else
  echo "Refusing: $PROFILE isn't empty and isn't a demo profile. Move it, or pass --profile <empty folder>." >&2
  exit 1
fi

if [ "$build" = 1 ] || [ ! -x "$ROOT/build.noindex/Rain.app/Contents/MacOS/BrowserPOC" ]; then
  "$ROOT/scripts/build.sh" release
fi
BIN="$ROOT/build.noindex/Rain.app/Contents/MacOS/BrowserPOC"

if [ "$need_seed" = 1 ]; then
  args=(--seed-demo "$PROFILE" --demo-content "$ROOT/Demo")
  [ -n "$MODELS" ] && args+=(--models-from "$MODELS")
  [ "$offline" = 1 ] && args+=(--offline)
  echo "Seeding the demo profile in $PROFILE"
  "$BIN" "${args[@]}"
else
  echo "Using the demo profile in $PROFILE (pass --reset to start it over)"
fi

if [ "$seed_only" = 0 ]; then
  # -n starts a separate copy, so a copy already open on your own profile stays as it is.
  open -n "$ROOT/build.noindex/Rain.app" --args --data-dir "$PROFILE"
fi
