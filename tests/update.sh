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
pass() { [[ "${VIGIL_TESTS_VERBOSE:-0}" == "1" ]] && printf '  PASS  %s\n' "$1"; return 0; }
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
    HOME="$1" \
        VIGIL_HOOK_INSTALL_DIR="$1/dev-bin" \
        VIGIL_UNSAFE_SKIP_SUDO=1 \
        bash "$REPO_DIR/install.sh" >/dev/null
}
update_into() {
    HOME="$1" \
        VIGIL_HOOK_INSTALL_DIR="$1/dev-bin" \
        VIGIL_UNSAFE_SKIP_SUDO=1 \
        bash "$REPO_DIR/update.sh" -y >/dev/null
}
# Same as update_into but captures stdout+stderr (caller greps for
# manifest-layer messages like "Preserved user edits" or "no manifest
# in backup"). Returns the captured text on stdout.
update_into_capture() {
    HOME="$1" \
        VIGIL_HOOK_INSTALL_DIR="$1/dev-bin" \
        VIGIL_UNSAFE_SKIP_SUDO=1 \
        bash "$REPO_DIR/update.sh" -y 2>&1
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
check_present "vigil-aliases.sh"  "$home/.config/vigil/vigil-aliases.sh"

# -----------------------------------------------------------------------------
section "Bundled files refresh on update when user has not edited them"
# Baseline: a clean install followed by an unmodified update leaves
# every shipped file matching the repo source. This is the no-
# divergence path through the manifest layer — diverged returns
# nothing, reconcile is skipped, the existing cp-restore semantics
# act on backup-vs-fresh and the fresh copy wins.
home=$(mktmp)
install_into "$home"
update_into "$home"
expected="$(cat "$REPO_DIR/profiles/default/CLAUDE.md")"
if [[ "$(cat "$home/.claude/CLAUDE.md")" == "$expected" ]]; then
    pass "CLAUDE.md refreshed from repo on no-edit update"
else
    fail "CLAUDE.md not refreshed (still stale or differs)"
fi
if [[ ! -e "$home/.claude/CLAUDE.new.md" ]]; then
    pass "no spurious .new.<ext> file on no-edit update"
else
    fail "unexpected CLAUDE.new.md produced on no-edit update"
fi

# -----------------------------------------------------------------------------
section "User-edited Vigil file preserved; fresh version staged as .new.<ext>"
# The manifest layer: a user-edited Vigil-installed file survives
# update in place; the freshly-installed copy is staged adjacent so
# the operator can merge manually.
home=$(mktmp)
install_into "$home"
printf '%s\n' "user edit marker" > "$home/.claude/CLAUDE.md"
out=$(update_into_capture "$home")
check_contents "user edit preserved at live path" \
    "$home/.claude/CLAUDE.md" "user edit marker"
expected_fresh="$(cat "$REPO_DIR/profiles/default/CLAUDE.md")"
check_contents "fresh content staged at CLAUDE.new.md" \
    "$home/.claude/CLAUDE.new.md" "$expected_fresh"
if grep -q 'Preserved user edits' <<<"$out" && \
   grep -q '~/.claude/CLAUDE.md' <<<"$out" && \
   grep -q '~/.claude/CLAUDE.new.md' <<<"$out"; then
    pass "summary lists preserved file and staged .new.<ext> path"
else
    fail "summary missing or malformed (out=$out)"
fi

# -----------------------------------------------------------------------------
section "Multi-divergence summary lists every preserved file"
# Two edits across both install roots — summary must mention both.
home=$(mktmp)
install_into "$home"
printf '%s\n' "claude edit" > "$home/.claude/CLAUDE.md"
printf '%s\n' '{"d":"edit"}' > "$home/.config/vigil/policies/dev.json"
out=$(update_into_capture "$home")
check_contents "claude edit preserved" \
    "$home/.claude/CLAUDE.md" "claude edit"
check_contents "policy edit preserved" \
    "$home/.config/vigil/policies/dev.json" '{"d":"edit"}'
check_present "CLAUDE.new.md staged"     "$home/.claude/CLAUDE.new.md"
check_present "dev.new.json staged"      "$home/.config/vigil/policies/dev.new.json"
if grep -q 'CLAUDE.new.md' <<<"$out" && grep -q 'dev.new.json' <<<"$out"; then
    pass "summary lists both staged paths"
else
    fail "summary missing one or both staged paths (out=$out)"
fi
n_line=$(grep -oE 'Preserved user edits to [0-9]+' <<<"$out" || true)
if [[ "$n_line" == "Preserved user edits to 2" ]]; then
    pass "summary count is accurate"
else
    fail "summary count wrong: '$n_line'"
fi

# -----------------------------------------------------------------------------
section "No-manifest graceful degradation (first update post-feature)"
# An install that predates the manifest feature has no
# .install-manifest in $DEST_DIR. update.sh should warn on stderr and
# fall through to the legacy gap-fill behavior (user edits clobbered)
# without aborting. Simulated by deleting the manifest after install.
home=$(mktmp)
install_into "$home"
rm -f "$home/.config/vigil/.install-manifest"
printf '%s\n' "doomed" > "$home/.claude/CLAUDE.md"
out=$(update_into_capture "$home")
if grep -q 'no manifest in backup' <<<"$out"; then
    pass "stderr note printed when backup has no manifest"
else
    fail "expected 'no manifest in backup' note (out=$out)"
fi
expected_fresh="$(cat "$REPO_DIR/profiles/default/CLAUDE.md")"
if [[ "$(cat "$home/.claude/CLAUDE.md")" == "$expected_fresh" ]]; then
    pass "without manifest, user edit clobbered (documented degradation)"
else
    fail "without manifest, expected legacy clobber behavior"
fi
if [[ ! -e "$home/.claude/CLAUDE.new.md" ]]; then
    pass "no .new.<ext> staged on no-manifest path"
else
    fail "unexpected .new.<ext> on no-manifest path"
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
section "User-added agent and hook preserved; bundled agent also present"
home=$(mktmp)
install_into "$home"
# hooks/ is user-only post-b87386d (the installer no longer creates it),
# so pre-create it before writing the user hook.
mkdir -p "$home/.claude/hooks"
echo "user-agent" > "$home/.claude/agents/my-custom.md"
echo "user-hook"  > "$home/.claude/hooks/my-custom.sh"
update_into "$home"

check_present "user agent"           "$home/.claude/agents/my-custom.md"
check_present "user hook"            "$home/.claude/hooks/my-custom.sh"
check_present "bundled architect"    "$home/.claude/agents/architect.md"
check_present "bundled code-reviewer" "$home/.claude/agents/code-reviewer.md"

# -----------------------------------------------------------------------------
section "User-added policy preserved; bundled also present"
home=$(mktmp)
install_into "$home"
echo '{"team":"x"}' > "$home/.config/vigil/policies/myteam.json"
update_into "$home"

check_present "user policy"   "$home/.config/vigil/policies/myteam.json"
check_present "bundled dev"    "$home/.config/vigil/policies/dev.json"
check_present "bundled strict" "$home/.config/vigil/policies/strict.json"
check_present "bundled yolo"   "$home/.config/vigil/policies/yolo.json"

# -----------------------------------------------------------------------------
section "Idempotent: second update is a no-op for file presence"
update_into "$home"
check_present "user policy after second update" \
    "$home/.config/vigil/policies/myteam.json"
check_present "bundled dev after second update" \
    "$home/.config/vigil/policies/dev.json"

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

out=$(HOME="$home" PATH="$shimdir:$PATH" \
    VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    VIGIL_UNSAFE_SKIP_SUDO=1 \
    bash "$REPO_DIR/update.sh" -y 2>&1)
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
out=$(HOME="$home" \
    VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    VIGIL_UNSAFE_SKIP_SUDO=1 \
    bash "$REPO_DIR/update.sh" -y </dev/null 2>&1)
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
