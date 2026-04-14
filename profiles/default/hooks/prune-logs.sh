#!/usr/bin/env bash
# prune-logs.sh — Session hook for ~/claude-logs retention.
# Runs at SessionStart. Deletes session-*.{log,txt} pairs older than
# 90 days and trims total size to 2G, oldest-first. A 10-minute mtime
# floor in the Python script protects the session that just started.
#
# Cannot read CLAUDE_LOG_DIR — the harness scrubs hook env vars — so
# we rely on the script's default of ~/claude-logs.

set -eu

script="$HOME/.config/vigil/scripts/prune-logs.py"
[ -f "$script" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$script" --quiet --older-than 90d --max-total-size 2G || true
