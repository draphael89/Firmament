#!/bin/bash
# Firmament session capture — Claude Code SessionEnd hook.
#
# Copies the finished session transcript into Firmament's agent inbox using
# the durable-import convention (.partial write, atomic rename). The core
# service imports it as an Agents-facet entry; capture is automatic-always
# per the operator's decision, with audit/Trash/bulk-delete in the vault.
#
# Install (in ~/.claude/settings.json):
#   "hooks": {
#     "SessionEnd": [{"hooks": [{"type": "command",
#       "command": "/path/to/firmament-capture.sh"}]}]
#   }
set -euo pipefail

INBOX="${FIRMAMENT_AGENT_INBOX:-$HOME/Library/Application Support/Firmament/agent-inbox/claude_code}"
mkdir -p "$INBOX"

payload=$(cat)
transcript_path=$(printf '%s' "$payload" | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("transcript_path",""))' 2>/dev/null || true)

[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || exit 0

base="$(basename "$transcript_path" .jsonl)-$(date +%s).jsonl"
cp "$transcript_path" "$INBOX/$base.partial"
mv "$INBOX/$base.partial" "$INBOX/$base"
