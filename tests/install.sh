#!/usr/bin/env bash
# Tier 2 end-to-end installer tests. Each case installs into an ephemeral
# $HOME and asserts file layout, substitution completeness, bundle/live
# parity, hook executable bits, and refusal-on-conflict behavior.
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

# Run install.sh with the given $HOME. Suppresses stdout; stderr surfaces.
# VIGIL_HOOK_INSTALL_DIR + VIGIL_UNSAFE_SKIP_SUDO=1 redirect the dispatcher-
# install step into the ephemeral home so the test does not need sudo or
# write to /usr/local/bin. See install.sh comment block above the hook-
# install for the threat-model implication — these env vars are for tests
# and dev installs only and must not be exported in normal contexts.
#
# Override path is $home/dev-bin (not $home/.local/bin/) because
# ~/.local/bin/ is in MASTER_DENY_WRITE: creating it would cause the
# "missing ~/.local/bin should have been filtered" test below to fail.
install_into() {
    local home="$1"
    shift
    HOME="$home" \
        VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
        VIGIL_UNSAFE_SKIP_SUDO=1 \
        bash "$REPO_DIR/install.sh" "$@" >/dev/null
}

# Same but captures stderr and exit code.
install_capture() {
    local home="$1"
    local stderr_file
    stderr_file=$(mktemp)
    TMPDIRS+=("$stderr_file")
    local rc=0
    HOME="$home" \
        VIGIL_HOOK_INSTALL_DIR="$home/dev-bin" \
        VIGIL_UNSAFE_SKIP_SUDO=1 \
        bash "$REPO_DIR/install.sh" >/dev/null 2>"$stderr_file" || rc=$?
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
check_file "scripts/hooks/prepare-commit-msg installed" \
    "$home/.config/vigil/scripts/hooks/prepare-commit-msg"
if [[ -x "$home/.config/vigil/scripts/hooks/prepare-commit-msg" ]]; then
    pass "prepare-commit-msg hook is executable"
else
    fail "prepare-commit-msg hook should be executable"
fi
check_file "scripts/hooks/pre-push installed" \
    "$home/.config/vigil/scripts/hooks/pre-push"
if [[ -x "$home/.config/vigil/scripts/hooks/pre-push" ]]; then
    pass "pre-push hook is executable"
else
    fail "pre-push hook should be executable"
fi
check_file "scripts/vigil-install-review installed" \
    "$home/.config/vigil/scripts/vigil-install-review"
if [[ -x "$home/.config/vigil/scripts/vigil-install-review" ]]; then
    pass "vigil-install-review is executable"
else
    fail "vigil-install-review should be executable"
fi

# Template source files should NOT appear in the install.
if [[ -f "$home/.config/vigil/policies/dev.template.json" ]]; then
    fail "template source dev.template.json should not appear in install"
else
    pass "template sources not present in install"
fi

# -----------------------------------------------------------------------------
section "Install root is ~/.config/vigil (Vigil rebrand regression)"
# Guards against a regression where the rebrand is partially reverted and
# install.sh drops content back into the legacy ~/.config/claude-config path.
if [[ -d "$home/.config/vigil" ]]; then
    pass "install created ~/.config/vigil"
else
    fail "install did not create ~/.config/vigil"
fi
if [[ -e "$home/.config/claude-config" ]]; then
    fail "install unexpectedly created legacy ~/.config/claude-config"
else
    pass "no legacy ~/.config/claude-config created"
fi

# -----------------------------------------------------------------------------
section "Default profile bundle layout"
# Bundle at ~/.config/vigil/profiles/default/ must be a real directory
# distinct from ~/.claude/ — the redesign's load-bearing invariant for
# lossless vigil set-default swaps.
profile_bundle="$home/.config/vigil/profiles/default"
if [[ -L "$profile_bundle" ]]; then
    fail "profiles/default should be a real directory, not a symlink"
elif [[ -d "$profile_bundle" ]]; then
    pass "profiles/default is a real directory"
else
    fail "profiles/default missing"
fi

# Files the bundle must contain (mirrors what's rendered into ~/.claude).
check_file "bundle settings.json"               "$profile_bundle/settings.json"
check_file "bundle CLAUDE.md"                   "$profile_bundle/CLAUDE.md"
check_file "bundle settings.local.json"         "$profile_bundle/settings.local.json"
check_file "bundle settings.local.template.json" "$profile_bundle/settings.local.template.json"
if [[ -d "$profile_bundle/agents" ]]; then
    pass "bundle agents/ present"
else
    fail "bundle agents/ missing"
fi

# Bundle and live tree must agree on the static files — this verifies
# both copy passes ran and the second filter-sandbox-denies.py invocation
# produced byte-equal sandbox arrays. settings.local.json is included
# because no shipped template uses {{PROFILE_DIR}} — only {{HOME}} — so
# the substituted outputs at both destinations should be identical. If
# a future template introduces {{PROFILE_DIR}}, this check would need
# to be removed or split per-destination.
for f in settings.json CLAUDE.md settings.local.json settings.local.template.json; do
    if [[ -f "$profile_bundle/$f" && -f "$home/.claude/$f" ]] && \
       diff -q "$profile_bundle/$f" "$home/.claude/$f" >/dev/null 2>&1; then
        pass "bundle $f byte-equal to ~/.claude/$f"
    else
        fail "bundle $f differs from ~/.claude/$f"
    fi
done
if [[ -d "$profile_bundle/agents" && -d "$home/.claude/agents" ]] && \
   diff -rq "$profile_bundle/agents" "$home/.claude/agents" >/dev/null 2>&1; then
    pass "bundle agents/ byte-equal to ~/.claude/agents/"
else
    fail "bundle agents/ differs from ~/.claude/agents/"
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
done < <(find "$home/.config/vigil" "$home/.claude" -type f \
    \( -name '*.json' -o -name '*.sh' -o -name '*.md' \) \
    ! -name '*.template.*' \
    ! -name 'vigil-aliases.sh' 2>/dev/null)
# vigil-aliases.sh is excluded above: it contains {{PROFILE_DIR}} and
# {{HOME}} as literal sed find-patterns inside vigil_set_default, not
# as unsubstituted template markers.
[[ $leak -eq 0 ]] && pass "no unreplaced {{...}} markers in installed files"

check_file "settings.local.template.json retained in default bundle" \
    "$home/.claude/settings.local.template.json"
check_file "settings.local.template.json retained in permissive bundle" \
    "$home/.config/vigil/profiles/permissive/settings.local.template.json"

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
section "Refusal: ~/.claude/settings.json already exists"
# install.sh deliberately tolerates a bare ~/.claude/ directory so that
# Claude Code runtime state can coexist with reinstallation. Specific
# Vigil-owned files inside it are the actual conflict surface.
home=$(mktmp)
mkdir -p "$home/.claude"
touch "$home/.claude/settings.json"
out=$(install_capture "$home")
rc=$(printf '%s\n' "$out" | head -1)
stderr_text=$(printf '%s\n' "$out" | tail -n +2)
if [[ "$rc" != "0" ]] && printf '%s' "$stderr_text" | grep -qi "refuse"; then
    pass "installer refuses when ~/.claude/settings.json exists"
else
    fail "expected refusal on pre-existing ~/.claude/settings.json (rc=$rc)"
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
mkdir -p "$home/.claude"
touch "$home/.claude/settings.json"
out=$(install_capture "$home")
stderr_text=$(printf '%s\n' "$out" | tail -n +2)
if printf '%s' "$stderr_text" | grep -q '~/.claude'; then
    pass "refusal message names ~/.claude"
else
    fail "refusal message did not name the conflicting path"
    printf '%s\n' "$stderr_text" >&2
fi

exit $failed
