#!/usr/bin/env bash
set -euo pipefail

# Ensure bootstrap has run
SUPPORT="$HOME/Library/Application Support/ClaudeDeck"
[ -f "$SUPPORT/.env" ] || { echo "Run bootstrap.sh first"; exit 1; }

# Load .env
set -a; . "$SUPPORT/.env"; set +a

# 1. Create temp dir and settings file
TMPDIR=$(mktemp -d)
SETTINGS="$TMPDIR/settings.json"
cat > "$SETTINGS" <<EOF
{"env":{"ANTHROPIC_BASE_URL":"$ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN":"$ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL":"${ANTHROPIC_MODEL:-MiniMax-M2.7}"}}
EOF

# 2. Spawn claude in stream-json mode and send a single prompt
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Say only the word PONG and nothing else."}]}}' \
  | claude --bare -p --output-format stream-json --input-format stream-json \
    --settings "$SETTINGS" --cwd "$TMPDIR" 2>/dev/null \
  | tee "$TMPDIR/out.jsonl"

# 3. Validate
if grep -q '"PONG"' "$TMPDIR/out.jsonl"; then
  echo "✓ integration pass"
else
  echo "✗ integration fail — see $TMPDIR/out.jsonl"
  exit 1
fi

# Cleanup
rm -rf "$TMPDIR"