#!/bin/bash
# Runs the self test against a throwaway index inside .build/selftest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c debug --scratch-path "$ROOT/.build"
mkdir -p "$ROOT/.build/selftest"
"$ROOT/.build/debug/BrowserPOC" --selftest --workdir "$ROOT/.build/selftest/run"
