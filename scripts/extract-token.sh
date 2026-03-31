#!/bin/bash
# Extract Claude Code OAuth refresh_token from macOS Keychain.
# Run this on the admin machine that has already logged into Claude Code via browser.
#
# Usage: bash scripts/extract-token.sh

set -e

echo "=== Extract Claude Code OAuth Token ==="
echo ""

# Try Keychain first (macOS default)
CREDS=$(security find-generic-password -a "$USER" -s "Claude Code-credentials" -w 2>/dev/null || true)

if [[ -z "$CREDS" ]]; then
  # Fallback: check .credentials.json
  CRED_FILE="$HOME/.claude/.credentials.json"
  if [[ -f "$CRED_FILE" ]]; then
    CREDS=$(cat "$CRED_FILE")
    echo "Source: ~/.claude/.credentials.json"
  else
    echo "Error: No credentials found."
    echo ""
    echo "Make sure you have logged into Claude Code on this machine:"
    echo "  1. Run: claude"
    echo "  2. Complete the browser OAuth login"
    echo "  3. Then run this script again"
    exit 1
  fi
else
  echo "Source: macOS Keychain"
fi

# Extract refresh token
REFRESH_TOKEN=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['refreshToken'])" 2>/dev/null)

if [[ -z "$REFRESH_TOKEN" ]]; then
  echo "Error: Could not extract refreshToken from credentials."
  echo "Raw credentials structure might have changed."
  exit 1
fi

# Show masked token
MASKED="${REFRESH_TOKEN:0:20}...${REFRESH_TOKEN: -6}"
echo ""
echo "Refresh token found: $MASKED"
echo ""
echo "Add this to your gateway config.yaml:"
echo ""
echo "oauth:"
echo "  refresh_token: \"$REFRESH_TOKEN\""
echo ""
echo "IMPORTANT: After extracting, configure THIS machine to also use the gateway."
echo "Do NOT continue using Claude Code directly on this machine."
