#!/usr/bin/env bash
# Tier 2 unit tests for scripts/filter-sandbox-denies.py. The script
# now owns the master deny lists in code and rebuilds the JSON arrays
# from (master ∩ filesystem state) on every run. These tests exercise
# the reactive behavior in isolation from install.sh.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/filter-sandbox-denies.py"

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

# Run the script with $HOME pointed at a sandbox directory. Returns the
# JSON payload after rewriting.
run_script() {
    local home="$1" settings="$2"
    HOME="$home" python3 "$SCRIPT" "$settings" >/dev/null
}

# Build a minimal settings.json without any denyRead/denyWrite keys.
seed_empty_settings() {
    local path="$1"
    cat > "$path" <<'JSON'
{
  "sandbox": {
    "enabled": true,
    "filesystem": {}
  }
}
JSON
}

read_array() {
    local settings="$1" key="$2"
    python3 -c "
import json, sys
with open('$settings') as f:
    s = json.load(f)
arr = s.get('sandbox', {}).get('filesystem', {}).get('$key', [])
print('\n'.join(arr))
"
}

# -----------------------------------------------------------------------------
section "Populates arrays from master list when keys are absent"
home=$(mktmp)
settings="$home/settings.json"
seed_empty_settings "$settings"
run_script "$home" "$settings"

# /etc, /usr, /var, /opt always exist on a real Linux host — they must
# show up in denyWrite even though the seed file had no keys at all.
denywrite=$(read_array "$settings" denyWrite)
if grep -qx '/etc/' <<< "$denywrite"; then
    pass "denyWrite created and populated with /etc/"
else
    fail "expected /etc/ in denyWrite (got: $denywrite)"
fi

# Empty $HOME means no user-side denyRead entries should pass the check.
denyread=$(read_array "$settings" denyRead)
if [[ -z "$denyread" ]]; then
    pass "denyRead empty for ephemeral \$HOME"
else
    fail "expected empty denyRead (got: $denyread)"
fi

# -----------------------------------------------------------------------------
section "Reactive: newly created path appears on next run"
mkdir -p "$home/.ssh"
run_script "$home" "$settings"
denyread=$(read_array "$settings" denyRead)
if grep -q "$home/.ssh" <<< "$denyread"; then
    pass "newly-created ~/.ssh added to denyRead on rerun"
else
    fail "expected ~/.ssh in denyRead after creation (got: $denyread)"
fi

# -----------------------------------------------------------------------------
section "Reactive: removed path drops out on next run"
rm -rf "$home/.ssh"
run_script "$home" "$settings"
denyread=$(read_array "$settings" denyRead)
if grep -q "$home/.ssh" <<< "$denyread"; then
    fail "removed ~/.ssh should drop from denyRead (got: $denyread)"
else
    pass "removed ~/.ssh dropped from denyRead on rerun"
fi

# -----------------------------------------------------------------------------
section "Symlinks are rejected (bwrap-incompatible)"
mkdir -p "$home/aws-target"
ln -s "$home/aws-target" "$home/.aws"
run_script "$home" "$settings"
denyread=$(read_array "$settings" denyRead)
if grep -q "$home/.aws" <<< "$denyread"; then
    fail "symlinked ~/.aws should not appear in denyRead (got: $denyread)"
else
    pass "symlinked ~/.aws filtered out"
fi

# Symlink under denyWrite is rejected too.
mkdir -p "$home/local-bin-target" "$home/.local"
ln -s "$home/local-bin-target" "$home/.local/bin"
run_script "$home" "$settings"
denywrite=$(read_array "$settings" denyWrite)
if grep -q "$home/.local/bin" <<< "$denywrite"; then
    fail "symlinked ~/.local/bin should not appear in denyWrite (got: $denywrite)"
else
    pass "symlinked ~/.local/bin filtered out"
fi

# -----------------------------------------------------------------------------
section "File-typed entry: directory at file path is rejected"
home=$(mktmp)
settings="$home/settings.json"
seed_empty_settings "$settings"
mkdir -p "$home/.netrc"  # master list expects a file here, not a dir
run_script "$home" "$settings"
denyread=$(read_array "$settings" denyRead)
if grep -q "$home/.netrc" <<< "$denyread"; then
    fail "directory at ~/.netrc (file-typed entry) should be filtered (got: $denyread)"
else
    pass "wrong-type ~/.netrc filtered out"
fi

# Now make it a real file and verify it appears.
rm -rf "$home/.netrc"
: > "$home/.netrc"
run_script "$home" "$settings"
denyread=$(read_array "$settings" denyRead)
if grep -q "$home/.netrc" <<< "$denyread"; then
    pass "real file ~/.netrc included after creation"
else
    fail "expected ~/.netrc in denyRead after creation (got: $denyread)"
fi

# -----------------------------------------------------------------------------
section "Master list is authoritative: stale JSON entries are overwritten"
home=$(mktmp)
settings="$home/settings.json"
cat > "$settings" <<'JSON'
{
  "sandbox": {
    "filesystem": {
      "denyRead": ["/some/bogus/path", "/another/lie"],
      "denyWrite": ["/etc/", "/imaginary/"]
    }
  }
}
JSON
run_script "$home" "$settings"
denyread=$(read_array "$settings" denyRead)
denywrite=$(read_array "$settings" denyWrite)
if grep -q "/some/bogus/path" <<< "$denyread" || grep -q "/imaginary/" <<< "$denywrite"; then
    fail "stale JSON entries should be overwritten by master rebuild"
    printf 'denyRead:\n%s\ndenyWrite:\n%s\n' "$denyread" "$denywrite" >&2
else
    pass "stale JSON entries overwritten by rebuild"
fi
if grep -qx '/etc/' <<< "$denywrite"; then
    pass "master entry /etc/ present after rebuild"
else
    fail "master entry /etc/ should be present (got: $denywrite)"
fi

# -----------------------------------------------------------------------------
section "Missing target file errors out"
home=$(mktmp)
rc=0
HOME="$home" python3 "$SCRIPT" "$home/missing.json" >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
    pass "non-zero exit when target file does not exist"
else
    fail "expected non-zero exit on missing target"
fi

# -----------------------------------------------------------------------------
section "Idempotent: two consecutive runs yield identical output"
home=$(mktmp)
settings="$home/settings.json"
seed_empty_settings "$settings"
mkdir -p "$home/.ssh"
run_script "$home" "$settings"
first=$(cat "$settings")
run_script "$home" "$settings"
second=$(cat "$settings")
if [[ "$first" == "$second" ]]; then
    pass "second run produced identical settings.json"
else
    fail "expected idempotent rewrite"
    diff <(printf '%s' "$first") <(printf '%s' "$second") >&2 || true
fi

exit $failed
