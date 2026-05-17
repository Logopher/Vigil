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

uninstall_into() {
    HOME="$1" \
        VIGIL_HOOK_INSTALL_DIR="$1/dev-bin" \
        VIGIL_UNSAFE_SKIP_SUDO=1 \
        bash "$REPO_DIR/uninstall.sh" -y >/dev/null
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

check_absent "vigil-aliases.sh"   "$home/.config/vigil/vigil-aliases.sh"
check_absent "doctor.sh"           "$home/.config/vigil/doctor.sh"
check_absent "pyszz.yml"           "$home/.config/vigil/pyszz.yml"
check_absent "policies/dev.json"   "$home/.config/vigil/policies/dev.json"
check_absent "policies/strict.json" "$home/.config/vigil/policies/strict.json"
check_absent "policies/yolo.json"  "$home/.config/vigil/policies/yolo.json"
while IFS= read -r -d '' f; do
    rel="${f#"$REPO_DIR/scripts/"}"
    check_absent "scripts/$rel" "$home/.config/vigil/scripts/$rel"
done < <(find "$REPO_DIR/scripts" -type f -print0)
# Default profile bundle: contents removed, directory tidied up.
check_absent "bundle settings.json"               "$home/.config/vigil/profiles/default/settings.json"
check_absent "bundle CLAUDE.md"                   "$home/.config/vigil/profiles/default/CLAUDE.md"
check_absent "bundle settings.local.json"         "$home/.config/vigil/profiles/default/settings.local.json"
check_absent "bundle settings.local.template.json" "$home/.config/vigil/profiles/default/settings.local.template.json"
for src in "$REPO_DIR/profiles/default/agents/"*; do
    check_absent "bundle agents/$(basename "$src")" \
        "$home/.config/vigil/profiles/default/agents/$(basename "$src")"
done
check_absent "profiles/default directory" "$home/.config/vigil/profiles/default"
check_absent "settings.json"       "$home/.claude/settings.json"
check_absent "CLAUDE.md"           "$home/.claude/CLAUDE.md"
check_absent "vigil-hook dispatcher" "$home/dev-bin/vigil-hook"

# -----------------------------------------------------------------------------
section "Empty install: parent directories are tidied up"
# sessions/ checked before its parent so a regression in the empty_dirs
# ordering surfaces here rather than as a confusing "$DEST_DIR still present"
# message whose root cause is one level deeper.
if [[ ! -d "$home/.config/vigil/sessions" ]]; then
    pass "~/.config/vigil/sessions removed (was empty)"
else
    fail "~/.config/vigil/sessions still present after empty uninstall"
fi
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
mkdir -p "$home/.claude/projects/foo" "$home/.claude/sessions" "$home/.claude/statsig" \
         "$home/.claude/hooks"
echo '{"key":"x"}'   > "$home/.claude/.credentials.json"
echo "session log"   > "$home/.claude/history.jsonl"
echo '{"id":"abc"}'  > "$home/.claude/projects/foo/state.json"
# Add user files under agents/ (bundled) and hooks/ (user-only post-b87386d)
# that uninstall must NOT touch.
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
# Closed stdin catches any accidental interactive prompt.
out=$(HOME="$home" \
    VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    VIGIL_UNSAFE_SKIP_SUDO=1 \
    bash "$REPO_DIR/uninstall.sh" -y </dev/null 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && grep -qi "nothing to remove" <<<"$out"; then
    pass "second uninstall reports nothing to remove"
else
    fail "second uninstall: rc=$rc out=$out"
fi
check_absent "vigil-hook dispatcher (idempotent)" "$home/dev-bin/vigil-hook"

# -----------------------------------------------------------------------------
section "Default invocation (no -y) requires confirmation"
home=$(mktmp)
install_into "$home"
out=$(printf 'n\n' | HOME="$home" \
    VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    VIGIL_UNSAFE_SKIP_SUDO=1 \
    bash "$REPO_DIR/uninstall.sh" 2>&1)
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
out=$(printf 'y\n' | HOME="$home" \
    VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    VIGIL_UNSAFE_SKIP_SUDO=1 \
    bash "$REPO_DIR/uninstall.sh" 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && [[ ! -f "$home/.claude/settings.json" ]]; then
    pass "uninstall without -y proceeds on 'y'"
else
    fail "expected successful uninstall on 'y' (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
section "Bare VIGIL_HOOK_INSTALL_DIR without VIGIL_UNSAFE_SKIP_SUDO errors out"
# Parity with install.sh: a stale VIGIL_HOOK_INSTALL_DIR inherited from
# another context must not silently redirect uninstall.
home=$(mktmp)
out=$(HOME="$home" VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    bash "$REPO_DIR/uninstall.sh" -y 2>&1)
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "VIGIL_HOOK_INSTALL_DIR is set" <<<"$out"; then
    pass "bare override errors out"
else
    fail "expected error (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
section "Foreign dispatcher at override path is removed"
# A dispatcher that doesn't match the repo's current build (different version,
# leftover from a previous install, etc.) is still removed — no hash check.
home=$(mktmp)
install_into "$home"
echo "this is not the real vigil-hook" > "$home/dev-bin/vigil-hook"
uninstall_into "$home"
check_absent "foreign dispatcher" "$home/dev-bin/vigil-hook"
check_absent "settings.json after foreign-dispatcher uninstall" "$home/.claude/settings.json"

# -----------------------------------------------------------------------------
section "Missing dispatcher: uninstall succeeds without error"
home=$(mktmp)
install_into "$home"
rm -f "$home/dev-bin/vigil-hook"
out=$(HOME="$home" \
    VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
    VIGIL_UNSAFE_SKIP_SUDO=1 \
    bash "$REPO_DIR/uninstall.sh" -y 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "uninstall with missing dispatcher succeeds"
else
    fail "missing dispatcher: rc=$rc out=$out"
fi
check_absent "settings.json after missing-dispatcher uninstall" "$home/.claude/settings.json"

exit $failed
