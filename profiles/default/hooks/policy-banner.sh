#!/usr/bin/env bash
# policy-banner.sh — SessionStart hook that prints the active policy.
# Reads ~/.config/vigil/.vigil-session (written by vigil-aliases.sh at
# launch; the harness strips shell-exported env vars before invoking hooks).
# Prints nothing if the marker is absent (direct claude launch).
# Mirrored to profiles/permissive/hooks/ — keep in sync.

set -euo pipefail

session_file="$HOME/.config/vigil/.vigil-session"
[[ -f "$session_file" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Read both fields in one Python call; | is not in the validated charset
# for either policy (^[a-zA-Z0-9_-]+$) or session_id ([0-9-] only,
# YYYYMMDD-HHMMSS format), making | a safe single-occurrence delimiter.
# || true is intentional: prevents set -e from aborting when Python fails.
_marker=$(python3 -c "
import sys, json
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
    print(m.get('policy', '') + '|' + m.get('session_id', ''))
except Exception:
    print('|')
" "$session_file" 2>/dev/null) || true

policy="${_marker%%|*}"
session_id="${_marker##*|}"

[[ -n "$policy" ]] || exit 0
echo "[vigil] active policy: ${policy}  |  session: ${session_id}" >&2
