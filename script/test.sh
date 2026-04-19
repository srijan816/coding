#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild test \
  -scheme Claudex \
  -destination 'platform=macOS' \
  -only-testing:ClaudexTests \
  -derivedDataPath ./build 2>&1 | tail -30