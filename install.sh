#!/bin/bash
# install.sh — Install the Claude Code status bar
# Usage: ./install.sh [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
install.sh — Install the Claude Code status bar

What it does:
  1. Copies statusline.sh to ~/.claude/statusline.sh
  2. Adds (or updates) the "statusLine" key in ~/.claude/settings.json

Usage:
  ./install.sh [--help]

Options:
  --help, -h    Show this message and exit
EOF
    exit 0
fi

# ── Checks ───────────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is required but not installed."
    echo "  macOS:        brew install jq"
    echo "  Debian/Ubuntu: sudo apt install jq"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/statusline.sh" ]]; then
    echo "Error: statusline.sh not found in $SCRIPT_DIR"
    exit 1
fi

# ── Copy script ──────────────────────────────────────────────────────────────
mkdir -p "$HOME/.claude"
cp "$SCRIPT_DIR/statusline.sh" "$DEST"
chmod +x "$DEST"
echo "✓ Copied statusline.sh → $DEST"

# ── Update settings.json ─────────────────────────────────────────────────────
STATUS_LINE_BLOCK='{"type":"command","command":"~/.claude/statusline.sh","padding":0}'

if [[ -f "$SETTINGS" ]]; then
    # Merge: add/overwrite the statusLine key, preserve everything else
    UPDATED=$(jq --argjson sl "$STATUS_LINE_BLOCK" '. + {statusLine: $sl}' "$SETTINGS")
    echo "$UPDATED" > "$SETTINGS"
    echo "✓ Updated statusLine in $SETTINGS"
else
    # Create a minimal settings.json
    jq -n --argjson sl "$STATUS_LINE_BLOCK" '{statusLine: $sl}' > "$SETTINGS"
    echo "✓ Created $SETTINGS with statusLine"
fi

echo ""
echo "Done! Restart Claude Code to see the status bar."
