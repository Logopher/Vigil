#!/usr/bin/env bash
# validate-memory-write.sh — PreToolUse gate for cross-project memory writes.
# Blocks Write / Edit / MultiEdit tool calls targeting
# ~/.claude/projects/<other-slug>/memory/** by comparing the target slug
# against the calling session's slug (derived from the cwd field in the
# hook's stdin JSON). Fails open on errors.
# Mirrored to profiles/permissive/hooks/ — keep in sync.

set -euo pipefail

script="$HOME/.config/vigil/scripts/validate-memory-write.py"
[[ -f "$script" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$script"
