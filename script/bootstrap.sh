#!/usr/bin/env bash
set -euo pipefail

# Verify Xcode and claude are installed
command -v xcodebuild >/dev/null || { echo "Xcode CLT not found"; exit 1; }
command -v claude >/dev/null || echo "WARN: claude CLI not on PATH — app will prompt later"

# Create app support dir
SUPPORT="$HOME/Library/Application Support/ClaudeDeck"
mkdir -p "$SUPPORT"

# Seed .env if missing
if [ ! -f "$SUPPORT/.env" ]; then
  cp "$(dirname "$0")/../.env.example" "$SUPPORT/.env"
  chmod 600 "$SUPPORT/.env"
  echo "Created $SUPPORT/.env — edit to add your MiniMax API key"
fi
echo "Bootstrap complete. Open ClaudeDeck.xcodeproj in Xcode and press Run."