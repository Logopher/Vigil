#!/usr/bin/env bash
# validate-settings-write.sh — PreToolUse gate for Vigil settings file writes.
# Hard-blocks Write / Edit / MultiEdit tool calls targeting
# ~/.claude/settings.json and ~/.claude/settings.local.json.
# Fails open on errors.
# Mirrored from profiles/default/hooks/ — keep in sync.

set -euo pipefail

script="$HOME/.config/vigil/scripts/validate-settings-write.py"
[[ -f "$script" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$script"
