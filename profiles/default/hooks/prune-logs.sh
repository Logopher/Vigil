#!/usr/bin/env bash
# prune-logs.sh — Session hook for ~/vigil-logs retention.
# Runs at SessionStart. Deletes session-*.txt files (and any orphaned
# .log companions) older than 180 days and trims total size to 2G,
# oldest-first. A 10-minute mtime floor in the Python script protects
# the session that just started.
#
# Cannot read VIGIL_LOG_DIR — the harness scrubs hook env vars — so
# we rely on the script's default of ~/vigil-logs.

set -eu

script="$HOME/.config/vigil/scripts/prune-logs.py"
[ -f "$script" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$script" --quiet --older-than 180d --max-total-size 2G || true
