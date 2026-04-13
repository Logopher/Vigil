#!/usr/bin/env bash
# Tier 2 end-to-end update tests. Each section installs into an
# ephemeral $HOME, optionally seeds it with simulated runtime state
# and user additions, runs update.sh, and verifies that:
#   - bundled files come from the new install (refreshed, not stale);
#   - runtime state and user additions survive in place;
#   - failure paths preserve the backup tempdir for recovery;
#   - the confirmation prompt and -y flag behave as documented.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

TMPDIRS=()
cleanup() {
    local d
    for d in "${TMPDIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

mktmp() {
    local d
    d=$(mktemp -d)
    TMPDIRS+=("$d")
    printf '%s' "$d"
}

install_into() {
    HOME="$1" bash "$REPO_DIR/install.sh" >/dev/null
}
update_into() {
    HOME="$1" bash "$REPO_DIR/update.sh" -y >/dev/null
}

check_present() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        pass "preserved: $label"
    else
        fail "wrongly removed: $label ($path)"
    fi
}
check_contents() {
    local label="$1" path="$2" expected="$3"
    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$expected" ]]; then
        pass "contents match: $label"
    else
        fail "contents differ: $label ($path)"
    fi
}

# -----------------------------------------------------------------------------
section "Update on never-installed home"
home=$(mktmp)
update_into "$home"
check_present "settings.json"      "$home/.claude/settings.json"
check_present "claude-aliases.sh"  "$home/.config/claude-config/claude-aliases.sh"

# -----------------------------------------------------------------------------
section "Bundled files refresh on update (stale local edits lost)"
home=$(mktmp)
install_into "$home"
echo "stale" > "$home/.claude/CLAUDE.md"
update_into "$home"
expected="$(cat "$REPO_DIR/profiles/default/CLAUDE.md")"
if [[ "$(cat "$home/.claude/CLAUDE.md")" == "$expected" ]]; then
    pass "CLAUDE.md refreshed from repo"
else
    fail "CLAUDE.md not refreshed (still stale or differs)"
fi

# -----------------------------------------------------------------------------
section "Runtime state preserved across update"
home=$(mktmp)
install_into "$home"
mkdir -p "$home/.claude/projects/foo" "$home/.claude/sessions" "$home/.claude/statsig"
echo '{"key":"x"}'  > "$home/.claude/.credentials.json"
echo "session log"  > "$home/.claude/history.jsonl"
echo '{"id":"abc"}' > "$home/.claude/projects/foo/state.json"
echo "marker"       > "$home/.claude/sessions/marker.txt"
echo "stat"         > "$home/.claude/statsig/marker.txt"

update_into "$home"

check_contents "credentials"     "$home/.claude/.credentials.json"        '{"key":"x"}'
check_contents "history.jsonl"   "$home/.claude/history.jsonl"            'session log'
check_contents "project state"   "$home/.claude/projects/foo/state.json"  '{"id":"abc"}'
check_contents "session marker"  "$home/.claude/sessions/marker.txt"      'marker'
check_contents "statsig marker"  "$home/.claude/statsig/marker.txt"       'stat'

# -----------------------------------------------------------------------------
section "User-added agent and hook preserved; bundled also present"
home=$(mktmp)
install_into "$home"
echo "user-agent" > "$home/.claude/agents/my-custom.md"
echo "user-hook"  > "$home/.claude/hooks/my-custom.sh"
update_into "$home"

check_present "user agent"           "$home/.claude/agents/my-custom.md"
check_present "user hook"            "$home/.claude/hooks/my-custom.sh"
check_present "bundled architect"    "$home/.claude/agents/architect.md"
check_present "bundled code-reviewer" "$home/.claude/agents/code-reviewer.md"
check_present "bundled prune-worktrees" "$home/.claude/hooks/prune-worktrees.sh"

# -----------------------------------------------------------------------------
section "User-added policy preserved; bundled also present"
home=$(mktmp)
install_into "$home"
echo '{"team":"x"}' > "$home/.config/claude-config/policies/myteam.json"
update_into "$home"

check_present "user policy"   "$home/.config/claude-config/policies/myteam.json"
check_present "bundled dev"    "$home/.config/claude-config/policies/dev.json"
check_present "bundled strict" "$home/.config/claude-config/policies/strict.json"
check_present "bundled yolo"   "$home/.config/claude-config/policies/yolo.json"

# -----------------------------------------------------------------------------
section "Idempotent: second update is a no-op for file presence"
update_into "$home"
check_present "user policy after second update" \
    "$home/.config/claude-config/policies/myteam.json"
check_present "bundled dev after second update" \
    "$home/.config/claude-config/policies/dev.json"

# -----------------------------------------------------------------------------
section "Unknown subdir under ~/.claude preserved"
home=$(mktmp)
install_into "$home"
mkdir -p "$home/.claude/skills"
echo "skill body" > "$home/.claude/skills/foo.md"
update_into "$home"
check_contents "skills/foo.md" "$home/.claude/skills/foo.md" "skill body"

# -----------------------------------------------------------------------------
section "Failure path auto-rolls back to pre-update state"
home=$(mktmp)
install_into "$home"
echo "marker" > "$home/.claude/.credentials.json"
mkdir -p "$home/.claude/sessions"
echo "session-data" > "$home/.claude/sessions/abc.log"
# Shim python3 → false on PATH so install.sh fails at the
# filter-sandbox-denies step. update.sh's trap should rollback to
# the pre-update state and remove the backup.
shimdir=$(mktmp)
cat > "$shimdir/python3" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$shimdir/python3"

out=$(HOME="$home" PATH="$shimdir:$PATH" bash "$REPO_DIR/update.sh" -y 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
    pass "update failed as expected (rc=$rc)"
else
    fail "update unexpectedly succeeded with broken python3"
fi

if grep -q 'update aborted; rolled back' <<<"$out"; then
    pass "rollback message surfaced"
else
    fail "expected 'update aborted; rolled back' in output (out=$out)"
fi

if ! grep -q 'backup preserved at' <<<"$out"; then
    pass "no stray backup-preserved message on successful rollback"
else
    fail "unexpected 'backup preserved at' on successful rollback (out=$out)"
fi

check_contents "credentials restored after rollback" \
    "$home/.claude/.credentials.json" "marker"
check_contents "session data restored after rollback" \
    "$home/.claude/sessions/abc.log" "session-data"

# -----------------------------------------------------------------------------
section "-y skips prompt"
home=$(mktmp)
install_into "$home"
out=$(HOME="$home" bash "$REPO_DIR/update.sh" -y </dev/null 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && [[ -f "$home/.claude/settings.json" ]]; then
    pass "update -y proceeds without stdin"
else
    fail "update -y failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
section "Default invocation prompts; 'n' aborts"
home=$(mktmp)
install_into "$home"
out=$(printf 'n\n' | HOME="$home" bash "$REPO_DIR/update.sh" 2>&1)
rc=$?
if [[ $rc -ne 0 ]] && grep -qi 'abort' <<<"$out"; then
    pass "default invocation aborts on 'n'"
else
    fail "expected abort on 'n' (rc=$rc, out=$out)"
fi
if [[ -f "$home/.claude/settings.json" ]]; then
    pass "install untouched after declined update"
else
    fail "install removed despite declined update"
fi

exit $failed
