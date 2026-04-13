#!/usr/bin/env bash
# Tier 2 end-to-end installer tests. Each case installs into an ephemeral
# $HOME and asserts file layout, substitution completeness, executable
# bits, symlink target, and backup behavior. All side effects are confined
# to mktemp'd directories which are removed on exit.
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

# Run install.sh into the given ephemeral $HOME. Stdout suppressed;
# stderr surfaces install errors.
install_into() {
    local home="$1"
    shift
    HOME="$home" bash "$REPO_DIR/install.sh" "$@" >/dev/null
}

# -----------------------------------------------------------------------------
section "Fresh install layout"
home=$(mktmp)
install_into "$home"

check_file() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass "$label"
    else
        fail "$label (missing: $path)"
    fi
}

check_file "claude-aliases.sh installed"            "$home/.config/claude-config/claude-aliases.sh"
check_file "policies/dev.json generated"            "$home/.config/claude-config/policies/dev.json"
check_file "policies/strict.json generated"         "$home/.config/claude-config/policies/strict.json"
check_file "policies/yolo.json copied"              "$home/.config/claude-config/policies/yolo.json"
check_file "profile settings.json generated"        "$home/.config/claude-config/profiles/default/settings.json"
check_file "profile CLAUDE.md installed"            "$home/.config/claude-config/profiles/default/CLAUDE.md"

# Template source files should NOT be at the install destination.
if [[ -f "$home/.config/claude-config/policies/dev.template.json" ]]; then
    fail "template source dev.template.json should not appear in install"
else
    pass "template sources not present in install"
fi

# -----------------------------------------------------------------------------
section "Symlink target"
expected_target="$home/.config/claude-config/profiles/default"
actual_target=$(readlink "$home/.claude" 2>/dev/null || printf '')
if [[ "$actual_target" == "$expected_target" ]]; then
    pass "~/.claude -> expected profile path"
else
    fail "~/.claude -> '$actual_target' (expected '$expected_target')"
fi

# -----------------------------------------------------------------------------
section "Template substitution completeness"
leak=0
while IFS= read -r f; do
    if grep -q '{{[^}]*}}' "$f" 2>/dev/null; then
        fail "unreplaced template marker in $f"
        leak=1
    fi
done < <(find "$home/.config/claude-config" -type f \( -name '*.json' -o -name '*.sh' -o -name '*.md' \))
[[ $leak -eq 0 ]] && pass "no unreplaced {{...}} markers in installed files"

# Positive checks: substituted values actually appear where expected.
if grep -q "Read($home/.ssh/" "$home/.config/claude-config/policies/dev.json"; then
    pass "{{HOME}} substituted in dev.json"
else
    fail "{{HOME}} not substituted in dev.json"
fi

profile_dir="$home/.config/claude-config/profiles/default"
if grep -q "$profile_dir/hooks/prune-worktrees.sh" "$profile_dir/settings.json"; then
    pass "{{PROFILE_DIR}} substituted in profile settings.json"
else
    fail "{{PROFILE_DIR}} not substituted in profile settings.json"
fi

# -----------------------------------------------------------------------------
section "Hook executable bits"
hook_fail=0
for hook in "$profile_dir/hooks"/*.sh; do
    if [[ ! -x "$hook" ]]; then
        fail "hook not executable: $hook"
        hook_fail=1
    fi
done
[[ $hook_fail -eq 0 ]] && pass "hooks are executable"

# -----------------------------------------------------------------------------
section "Backup-aside on existing install (no --force)"
home=$(mktmp)
mkdir -p "$home/.config/claude-config"
echo "sentinel" > "$home/.config/claude-config/sentinel.txt"
install_into "$home"

if [[ -f "$home/.config/claude-config/sentinel.txt" ]]; then
    fail "sentinel still in new install (should have been moved aside)"
else
    backup_matches=( "$home/.config/claude-config".bak-* )
    if [[ ${#backup_matches[@]} -gt 0 && -f "${backup_matches[0]}/sentinel.txt" ]]; then
        pass "pre-existing install moved to .bak-<timestamp>"
    else
        fail "no .bak-<timestamp> directory containing the sentinel"
    fi
fi

# -----------------------------------------------------------------------------
section "--force skips backup"
home=$(mktmp)
mkdir -p "$home/.config/claude-config"
echo "sentinel" > "$home/.config/claude-config/sentinel.txt"
install_into "$home" --force

backup_matches=( "$home/.config/claude-config".bak-* )
if [[ ${#backup_matches[@]} -gt 0 ]]; then
    fail "--force should not create backup directory (found: ${backup_matches[0]})"
elif [[ -f "$home/.config/claude-config/sentinel.txt" ]]; then
    fail "sentinel should be gone after --force install"
else
    pass "--force overwrites without backup"
fi

# -----------------------------------------------------------------------------
section "Second install produces identical content"
home=$(mktmp)
install_into "$home"
first_snap=$(mktmp)
cp -r "$home/.config/claude-config" "$first_snap/"

install_into "$home" --force
second_snap=$(mktmp)
cp -r "$home/.config/claude-config" "$second_snap/"

if diff -r "$first_snap/claude-config" "$second_snap/claude-config" >/dev/null 2>&1; then
    pass "re-install content identical"
else
    fail "re-install content differs from first install"
    diff -r "$first_snap/claude-config" "$second_snap/claude-config" 2>&1 | head -20 >&2 || true
fi

exit $failed
