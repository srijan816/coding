#!/usr/bin/env bash
set -uo pipefail
echo "== ClaudeDeck Doctor =="

command -v claude >/dev/null && echo "✓ claude CLI: $(which claude)" || { echo "✗ claude CLI not found"; exit 1; }
claude --version

[ -f "$HOME/Library/Application Support/ClaudeDeck/.env" ] && echo "✓ .env present" || echo "✗ .env missing — run script/bootstrap.sh"

perm=$(stat -f '%A' "$HOME/Library/Application Support/ClaudeDeck/.env" 2>/dev/null || echo "")
[ "$perm" = "600" ] && echo "✓ .env mode 600" || echo "⚠ .env mode is $perm — should be 600"

set -a; . "$HOME/Library/Application Support/ClaudeDeck/.env" 2>/dev/null; set +a

[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && echo "✓ ANTHROPIC_AUTH_TOKEN set (hidden)" || echo "✗ ANTHROPIC_AUTH_TOKEN missing"
[ -n "${ANTHROPIC_BASE_URL:-}" ] && echo "✓ ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL" || echo "✗ ANTHROPIC_BASE_URL missing"

echo "-- ping base URL --"
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" "$ANTHROPIC_BASE_URL/v1/messages" \
    -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"'"${ANTHROPIC_MODEL:-MiniMax-M2.7}"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' || echo "ping failed"
fi