#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -scheme Claudex -configuration Debug \
  -destination 'platform=macOS' build \
  -derivedDataPath ./build 2>&1 | tail -20
APP_PATH="./build/Build/Products/Debug/Claudex.app"
pkill -f Claudex 2>/dev/null || true
open "$APP_PATH" 2>/dev/null || echo "App built at: $APP_PATH"