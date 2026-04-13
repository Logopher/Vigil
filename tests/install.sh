#!/usr/bin/env bash
# Tier 2 end-to-end installer tests. Each case installs into an ephemeral
# $HOME and asserts file layout, substitution completeness, symlink
# direction, hook executable bits, and refusal-on-conflict behavior.
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

# Run install.sh with the given $HOME. Suppresses stdout; stderr surfaces.
install_into() {
    local home="$1"
    shift
    HOME="$home" bash "$REPO_DIR/install.sh" "$@" >/dev/null
}

# Same but captures stderr and exit code.
install_capture() {
    local home="$1"
    local stderr_file
    stderr_file=$(mktemp)
    TMPDIRS+=("$stderr_file")
    local rc=0
    HOME="$home" bash "$REPO_DIR/install.sh" >/dev/null 2>"$stderr_file" || rc=$?
    printf '%d\n' "$rc"
    cat "$stderr_file"
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

check_file "aliases at ~/.config/claude-config/claude-aliases.sh" \
    "$home/.config/claude-config/claude-aliases.sh"
check_file "policies/dev.json generated"            "$home/.config/claude-config/policies/dev.json"
check_file "policies/strict.json generated"         "$home/.config/claude-config/policies/strict.json"
check_file "policies/yolo.json copied"              "$home/.config/claude-config/policies/yolo.json"
check_file "profile settings.json at ~/.claude"     "$home/.claude/settings.json"
check_file "profile CLAUDE.md at ~/.claude"         "$home/.claude/CLAUDE.md"

# Template source files should NOT appear in the install.
if [[ -f "$home/.config/claude-config/policies/dev.template.json" ]]; then
    fail "template source dev.template.json should not appear in install"
else
    pass "template sources not present in install"
fi

# -----------------------------------------------------------------------------
section "Symlink direction: profiles/default -> ~/.claude"
profile_symlink="$home/.config/claude-config/profiles/default"
if [[ -L "$profile_symlink" ]]; then
    actual=$(readlink "$profile_symlink")
    expected="$home/.claude"
    if [[ "$actual" == "$expected" ]]; then
        pass "profiles/default symlink targets ~/.claude"
    else
        fail "profiles/default -> '$actual' (expected '$expected')"
    fi
else
    fail "profiles/default is not a symlink"
fi

# ~/.claude must be a real directory, not a symlink.
if [[ -L "$home/.claude" ]]; then
    fail "~/.claude should be a real directory, not a symlink"
elif [[ -d "$home/.claude" ]]; then
    pass "~/.claude is a real directory"
else
    fail "~/.claude missing"
fi

# -----------------------------------------------------------------------------
section "Template substitution completeness"
leak=0
while IFS= read -r f; do
    if grep -q '{{[^}]*}}' "$f" 2>/dev/null; then
        fail "unreplaced template marker in $f"
        leak=1
    fi
done < <(find "$home/.config/claude-config" "$home/.claude" -type f \( -name '*.json' -o -name '*.sh' -o -name '*.md' \) 2>/dev/null)
[[ $leak -eq 0 ]] && pass "no unreplaced {{...}} markers in installed files"

# Positive checks: substituted values actually appear where expected.
if grep -q "Read($home/.ssh/" "$home/.config/claude-config/policies/dev.json"; then
    pass "{{HOME}} substituted in dev.json"
else
    fail "{{HOME}} not substituted in dev.json"
fi

# {{PROFILE_DIR}} substitutes to $HOME/.claude (canonical), not the symlink.
if grep -q "$home/.claude/hooks/prune-worktrees.sh" "$home/.claude/settings.json"; then
    pass "{{PROFILE_DIR}} substituted to ~/.claude in settings.json"
else
    fail "{{PROFILE_DIR}} not substituted to ~/.claude in settings.json"
fi

# -----------------------------------------------------------------------------
section "Hook executable bits"
hook_fail=0
for hook in "$home/.claude/hooks"/*.sh; do
    if [[ ! -x "$hook" ]]; then
        fail "hook not executable: $hook"
        hook_fail=1
    fi
done
[[ $hook_fail -eq 0 ]] && pass "hooks are executable"

# -----------------------------------------------------------------------------
section "Refusal: ~/.claude already exists"
home=$(mktmp)
mkdir "$home/.claude"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
stderr_text=$(printf '%s\n' "$out" | tail -n +2)
if [[ "$rc" != "0" ]] && printf '%s' "$stderr_text" | grep -qi "refuse"; then
    pass "installer refuses when ~/.claude exists"
else
    fail "expected refusal on pre-existing ~/.claude (rc=$rc)"
    printf '%s\n' "$stderr_text" >&2
fi

# -----------------------------------------------------------------------------
section "Refusal: claude-aliases.sh already exists"
home=$(mktmp)
mkdir -p "$home/.config/claude-config"
echo "existing" > "$home/.config/claude-config/claude-aliases.sh"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when claude-aliases.sh exists"
else
    fail "expected refusal on pre-existing claude-aliases.sh"
fi

# -----------------------------------------------------------------------------
section "Refusal: a policy file already exists"
home=$(mktmp)
mkdir -p "$home/.config/claude-config/policies"
echo '{}' > "$home/.config/claude-config/policies/dev.json"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when dev.json exists"
else
    fail "expected refusal on pre-existing policies/dev.json"
fi

# -----------------------------------------------------------------------------
section "Refusal: profiles/default already exists"
home=$(mktmp)
mkdir -p "$home/.config/claude-config/profiles/default"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when profiles/default exists"
else
    fail "expected refusal on pre-existing profiles/default"
fi

# -----------------------------------------------------------------------------
section "Refusal lists offending paths in stderr"
home=$(mktmp)
mkdir "$home/.claude"
out=$(install_capture "$home")
stderr_text=$(printf '%s\n' "$out" | tail -n +2)
if printf '%s' "$stderr_text" | grep -q '~/.claude'; then
    pass "refusal message names ~/.claude"
else
    fail "refusal message did not name the conflicting path"
    printf '%s\n' "$stderr_text" >&2
fi

exit $failed
