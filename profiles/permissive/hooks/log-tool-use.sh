#!/usr/bin/env bash
# log-tool-use.sh — PreToolUse / PostToolUse hook for per-call tool logging.
# Reads ~/.config/vigil/.vigil-session for session context (the harness
# strips shell-exported env vars before invoking hooks). Delegates to
# scripts/log-tool-use.py; mirrors the prune-logs.sh pattern.
# Mirrored to profiles/permissive/hooks/ — keep in sync.

set -euo pipefail

[[ -f "$HOME/.config/vigil/.vigil-session" ]] || exit 0
script="$HOME/.config/vigil/scripts/log-tool-use.py"
[[ -f "$script" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$script" "$HOME/.config/vigil/.vigil-session" || exit 0
