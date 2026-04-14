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

check_file "aliases at ~/.config/vigil/vigil-aliases.sh" \
    "$home/.config/vigil/vigil-aliases.sh"
check_file "doctor.sh at ~/.config/vigil/doctor.sh" \
    "$home/.config/vigil/doctor.sh"
if [[ -x "$home/.config/vigil/doctor.sh" ]]; then
    pass "doctor.sh is executable"
else
    fail "doctor.sh should be executable"
fi
check_file "policies/dev.json generated"            "$home/.config/vigil/policies/dev.json"
check_file "policies/strict.json generated"         "$home/.config/vigil/policies/strict.json"
check_file "policies/yolo.json copied"              "$home/.config/vigil/policies/yolo.json"
check_file "profile settings.json at ~/.claude"     "$home/.claude/settings.json"
check_file "profile CLAUDE.md at ~/.claude"         "$home/.claude/CLAUDE.md"
check_file "scripts/filter-sandbox-denies.py installed" \
    "$home/.config/vigil/scripts/filter-sandbox-denies.py"

# Template source files should NOT appear in the install.
if [[ -f "$home/.config/vigil/policies/dev.template.json" ]]; then
    fail "template source dev.template.json should not appear in install"
else
    pass "template sources not present in install"
fi

# -----------------------------------------------------------------------------
section "Symlink direction: profiles/default -> ~/.claude"
profile_symlink="$home/.config/vigil/profiles/default"
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
done < <(find "$home/.config/vigil" "$home/.claude" -type f \( -name '*.json' -o -name '*.sh' -o -name '*.md' \) 2>/dev/null)
[[ $leak -eq 0 ]] && pass "no unreplaced {{...}} markers in installed files"

# Positive checks: substituted values actually appear where expected.
if grep -q "Read($home/.ssh/" "$home/.config/vigil/policies/dev.json"; then
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
section "denyRead filtered to extant paths"
# The ephemeral $HOME has none of the credential directories, so the
# installer's filter pass should have dropped every denyRead entry.
denyread_count=$(python3 -c "
import json, sys
with open('$home/.claude/settings.json') as f:
    s = json.load(f)
entries = s.get('sandbox', {}).get('filesystem', {}).get('denyRead', [])
print(len(entries))
")
if [[ "$denyread_count" == "0" ]]; then
    pass "all non-existent denyRead entries filtered out"
else
    fail "expected 0 denyRead entries in ephemeral \$HOME (got $denyread_count)"
fi

# Positive case: pre-create ~/.ssh as a real directory so one entry survives;
# pre-create ~/.aws as a symlink so it is dropped (the bwrap-incompatible
# case discovered in production).
home=$(mktmp)
mkdir -p "$home/.ssh"
mkdir -p "$home/aws-target"
ln -s "$home/aws-target" "$home/.aws"
install_into "$home"
remaining=$(python3 -c "
import json
with open('$home/.claude/settings.json') as f:
    s = json.load(f)
entries = s.get('sandbox', {}).get('filesystem', {}).get('denyRead', [])
print('\n'.join(entries))
")
if grep -q "$home/.ssh" <<< "$remaining"; then
    pass "real directory retained in denyRead"
else
    fail "pre-existing ~/.ssh should be in denyRead (got: $remaining)"
fi
if grep -q "$home/.aws" <<< "$remaining"; then
    fail "symlinked ~/.aws should have been filtered out (bwrap-incompatible)"
else
    pass "symlinked path filtered from denyRead"
fi

# -----------------------------------------------------------------------------
section "denyWrite filtered to extant paths"
# The default profile declares system paths (/etc, /usr, /var, /opt) and
# user paths (~/.local/bin, ~/.local/lib, ~/bin) under denyWrite. After
# install in an ephemeral $HOME, only the system paths that exist on the
# host should remain; the user paths should all be filtered out.
home=$(mktmp)
install_into "$home"
denywrite=$(python3 -c "
import json
with open('$home/.claude/settings.json') as f:
    s = json.load(f)
entries = s.get('sandbox', {}).get('filesystem', {}).get('denyWrite', [])
print('\n'.join(entries))
")
# /etc always exists.
if grep -qx '/etc/' <<< "$denywrite"; then
    pass "real system path /etc/ retained in denyWrite"
else
    fail "expected /etc/ in denyWrite (got: $denywrite)"
fi
# Ephemeral $HOME has no ~/.local/bin.
if grep -q "$home/.local/bin" <<< "$denywrite"; then
    fail "missing ~/.local/bin should have been filtered from denyWrite"
else
    pass "missing ~/.local/bin filtered from denyWrite"
fi
if grep -q "$home/bin" <<< "$denywrite"; then
    fail "missing ~/bin should have been filtered from denyWrite"
else
    pass "missing ~/bin filtered from denyWrite"
fi

# Positive case: pre-create ~/.local/bin and re-install; entry should
# survive the filter pass.
home=$(mktmp)
mkdir -p "$home/.local/bin"
install_into "$home"
denywrite=$(python3 -c "
import json
with open('$home/.claude/settings.json') as f:
    s = json.load(f)
entries = s.get('sandbox', {}).get('filesystem', {}).get('denyWrite', [])
print('\n'.join(entries))
")
if grep -q "$home/.local/bin" <<< "$denywrite"; then
    pass "pre-existing ~/.local/bin retained in denyWrite"
else
    fail "expected ~/.local/bin in denyWrite when present (got: $denywrite)"
fi

# Symlinks under denyWrite must be dropped too — same bwrap-incompatible
# failure mode that motivates the filter for denyRead.
home=$(mktmp)
mkdir -p "$home/local-bin-target"
mkdir -p "$home/.local"
ln -s "$home/local-bin-target" "$home/.local/bin"
install_into "$home"
denywrite=$(python3 -c "
import json
with open('$home/.claude/settings.json') as f:
    s = json.load(f)
entries = s.get('sandbox', {}).get('filesystem', {}).get('denyWrite', [])
print('\n'.join(entries))
")
if grep -q "$home/.local/bin" <<< "$denywrite"; then
    fail "symlinked ~/.local/bin should have been filtered (bwrap-incompatible)"
else
    pass "symlinked ~/.local/bin filtered from denyWrite"
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
section "Refusal: vigil-aliases.sh already exists"
home=$(mktmp)
mkdir -p "$home/.config/vigil"
echo "existing" > "$home/.config/vigil/vigil-aliases.sh"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when vigil-aliases.sh exists"
else
    fail "expected refusal on pre-existing vigil-aliases.sh"
fi

# -----------------------------------------------------------------------------
section "Refusal: a policy file already exists"
home=$(mktmp)
mkdir -p "$home/.config/vigil/policies"
echo '{}' > "$home/.config/vigil/policies/dev.json"
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
mkdir -p "$home/.config/vigil/profiles/default"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when profiles/default exists"
else
    fail "expected refusal on pre-existing profiles/default"
fi

# -----------------------------------------------------------------------------
section "Refusal: doctor.sh already exists"
home=$(mktmp)
mkdir -p "$home/.config/vigil"
echo "existing" > "$home/.config/vigil/doctor.sh"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when doctor.sh exists"
else
    fail "expected refusal on pre-existing doctor.sh"
fi

# -----------------------------------------------------------------------------
section "Refusal: scripts/ already exists"
home=$(mktmp)
mkdir -p "$home/.config/vigil/scripts"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
if [[ "$rc" != "0" ]]; then
    pass "installer refuses when scripts/ exists"
else
    fail "expected refusal on pre-existing scripts/"
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
