#!/usr/bin/env bash
# Tier 2 end-to-end uninstall tests. Each case installs into an ephemeral
# $HOME, optionally seeds it with simulated Claude Code runtime state and
# user-added agents/hooks, then uninstalls and verifies that:
#   - all files placed by install.sh are removed;
#   - simulated runtime state under ~/.claude is preserved;
#   - user additions under ~/.claude/agents/ and hooks/ are preserved;
#   - empty parent directories are tidied up;
#   - non-empty parent dirs (because of preserved state) are left alone.
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

uninstall_into() {
    HOME="$1" bash "$REPO_DIR/uninstall.sh" -y >/dev/null
}

check_absent() {
    local label="$1" path="$2"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        pass "removed: $label"
    else
        fail "still present: $label ($path)"
    fi
}
check_present() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        pass "preserved: $label"
    else
        fail "wrongly removed: $label ($path)"
    fi
}

# -----------------------------------------------------------------------------
section "Empty install: uninstall removes every placed file"
home=$(mktmp)
install_into "$home"
uninstall_into "$home"

check_absent "claude-aliases.sh"   "$home/.config/vigil/claude-aliases.sh"
check_absent "doctor.sh"           "$home/.config/vigil/doctor.sh"
check_absent "policies/dev.json"   "$home/.config/vigil/policies/dev.json"
check_absent "policies/strict.json" "$home/.config/vigil/policies/strict.json"
check_absent "policies/yolo.json"  "$home/.config/vigil/policies/yolo.json"
check_absent "scripts/filter-sandbox-denies.py" \
    "$home/.config/vigil/scripts/filter-sandbox-denies.py"
check_absent "profiles/default symlink" "$home/.config/vigil/profiles/default"
check_absent "settings.json"       "$home/.claude/settings.json"
check_absent "CLAUDE.md"           "$home/.claude/CLAUDE.md"

# -----------------------------------------------------------------------------
section "Empty install: parent directories are tidied up"
if [[ ! -d "$home/.claude" ]]; then
    pass "~/.claude removed (was empty)"
else
    fail "~/.claude still present after empty uninstall"
fi
if [[ ! -d "$home/.config/vigil" ]]; then
    pass "~/.config/vigil removed"
else
    fail "~/.config/vigil still present after empty uninstall"
fi

# -----------------------------------------------------------------------------
section "Runtime state under ~/.claude is preserved"
home=$(mktmp)
install_into "$home"
# Simulate Claude Code runtime state — none of these files originate
# from install.sh and uninstall must not touch them.
mkdir -p "$home/.claude/projects/foo" "$home/.claude/sessions" "$home/.claude/statsig"
echo '{"key":"x"}'   > "$home/.claude/.credentials.json"
echo "session log"   > "$home/.claude/history.jsonl"
echo '{"id":"abc"}'  > "$home/.claude/projects/foo/state.json"
# Add user files under bundled subdirs that uninstall must NOT touch.
echo "user-agent"    > "$home/.claude/agents/my-custom-agent.md"
echo "user-hook"     > "$home/.claude/hooks/my-custom-hook.sh"

uninstall_into "$home"

check_present "~/.claude/.credentials.json"        "$home/.claude/.credentials.json"
check_present "~/.claude/history.jsonl"            "$home/.claude/history.jsonl"
check_present "~/.claude/projects/foo/state.json"  "$home/.claude/projects/foo/state.json"
check_present "~/.claude/sessions/"                "$home/.claude/sessions"
check_present "~/.claude/statsig/"                 "$home/.claude/statsig"

# -----------------------------------------------------------------------------
section "User additions under agents/ and hooks/ preserved"
check_present "user agent" "$home/.claude/agents/my-custom-agent.md"
check_present "user hook"  "$home/.claude/hooks/my-custom-hook.sh"

# Bundled files should be gone.
for src in "$REPO_DIR/profiles/default/agents/"*; do
    check_absent "bundled agent $(basename "$src")" \
        "$home/.claude/agents/$(basename "$src")"
done
for src in "$REPO_DIR/profiles/default/hooks/"*; do
    check_absent "bundled hook $(basename "$src")" \
        "$home/.claude/hooks/$(basename "$src")"
done

# Non-empty parent dirs must remain.
if [[ -d "$home/.claude/agents" ]]; then
    pass "~/.claude/agents/ retained (non-empty)"
else
    fail "~/.claude/agents/ removed despite user file"
fi
if [[ -d "$home/.claude/hooks" ]]; then
    pass "~/.claude/hooks/ retained (non-empty)"
else
    fail "~/.claude/hooks/ removed despite user file"
fi
if [[ -d "$home/.claude" ]]; then
    pass "~/.claude/ retained (non-empty)"
else
    fail "~/.claude/ removed despite preserved runtime state"
fi

# -----------------------------------------------------------------------------
section "Idempotent: second uninstall is a no-op"
out=$(HOME="$home" bash "$REPO_DIR/uninstall.sh" -y 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && grep -qi "nothing to remove" <<<"$out"; then
    pass "second uninstall reports nothing to remove"
else
    fail "second uninstall: rc=$rc out=$out"
fi

# -----------------------------------------------------------------------------
section "Default invocation (no -y) requires confirmation"
home=$(mktmp)
install_into "$home"
out=$(printf 'n\n' | HOME="$home" bash "$REPO_DIR/uninstall.sh" 2>&1)
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "abort" <<<"$out"; then
    pass "uninstall without -y respects 'n'"
else
    fail "expected abort on 'n' (rc=$rc, out=$out)"
fi
if [[ -f "$home/.claude/settings.json" ]]; then
    pass "files preserved after declined uninstall"
else
    fail "files removed despite declined uninstall"
fi

# -----------------------------------------------------------------------------
section "Default invocation: 'y' on stdin proceeds"
out=$(printf 'y\n' | HOME="$home" bash "$REPO_DIR/uninstall.sh" 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && [[ ! -f "$home/.claude/settings.json" ]]; then
    pass "uninstall without -y proceeds on 'y'"
else
    fail "expected successful uninstall on 'y' (rc=$rc, out=$out)"
fi

exit $failed
