#!/usr/bin/env bash
# End-to-end tests for doctor.sh. Each case installs into an ephemeral
# $HOME, mutates the install to simulate a failure mode, runs doctor.sh
# against that $HOME, and asserts on exit code + stdout/stderr text.
#
# doctor.sh must be read-only — these tests also confirm it never
# touches the install (snapshot-and-compare).
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO_DIR/doctor.sh"

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

# Install into the given ephemeral $HOME.
install_into() {
    local home="$1"
    HOME="$home" bash "$REPO_DIR/install.sh" >/dev/null
}

# Run doctor with $HOME set; capture combined stdout+stderr and exit code.
# Echoes "<rc>\n<output>" so callers can split with `head -1` / `tail -n +2`.
run_doctor() {
    local home="$1"
    local rc=0
    local out
    out=$(HOME="$home" bash "$DOCTOR" 2>&1) || rc=$?
    printf '%d\n%s' "$rc" "$out"
}

# Snapshot every regular file's size+mtime under the install tree. Used
# to assert doctor.sh is non-mutating. Uses `stat` (with a per-platform
# format string) instead of `find -printf` so the test stays portable
# to BSD / macOS where -printf is unavailable.
snapshot_install() {
    local home="$1"
    local fmt
    case "$(uname -s)" in
        Darwin|FreeBSD|NetBSD|OpenBSD) fmt=(stat -f '%N %z %m') ;;
        *)                              fmt=(stat -c '%n %s %Y') ;;
    esac
    find "$home/.config/vigil" "$home/.claude" -type f 2>/dev/null \
        | sort \
        | while IFS= read -r f; do
            "${fmt[@]}" -- "$f"
        done
}

# -----------------------------------------------------------------------------
section "Healthy install: exits 0, all PASS"
home=$(mktmp)
install_into "$home"
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "0" ]]; then
    pass "doctor exits 0 on healthy install"
else
    fail "expected exit 0 on healthy install (rc=$rc)"
    printf '%s\n' "$out" >&2
fi
if grep -q "all checks passed\|passed with .* warning" <<< "$out"; then
    pass "summary line reports success"
else
    fail "expected success summary (got: $out)"
fi

# -----------------------------------------------------------------------------
section "Read-only: doctor never modifies the install"
home=$(mktmp)
install_into "$home"
before=$(snapshot_install "$home")
run_doctor "$home" >/dev/null
after=$(snapshot_install "$home")
if [[ "$before" == "$after" ]]; then
    pass "no install files mutated by doctor.sh"
else
    fail "doctor.sh mutated the install"
    diff <(printf '%s' "$before") <(printf '%s' "$after") >&2 || true
fi

# -----------------------------------------------------------------------------
section "Corrupted settings.json -> FAIL"
home=$(mktmp)
install_into "$home"
echo "{ this is not json" > "$home/.claude/settings.json"
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "1" ]]; then
    pass "doctor exits 1 on corrupted settings.json"
else
    fail "expected exit 1 on bad JSON (rc=$rc)"
fi
if grep -q "not valid JSON" <<< "$out"; then
    pass "JSON failure message present"
else
    fail "expected 'not valid JSON' in output (got: $out)"
fi

# -----------------------------------------------------------------------------
section "Missing hook script -> FAIL"
home=$(mktmp)
install_into "$home"
rm "$home/.claude/hooks/prune-worktrees.sh"
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "1" ]] && grep -q "hook missing" <<< "$out"; then
    pass "doctor exits 1 and reports missing hook"
else
    fail "expected exit 1 + 'hook missing' (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "Non-executable hook -> FAIL"
home=$(mktmp)
install_into "$home"
chmod -x "$home/.claude/hooks/prune-worktrees.sh"
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "1" ]] && grep -q "not executable" <<< "$out"; then
    pass "doctor exits 1 and reports non-executable hook"
else
    fail "expected exit 1 + 'not executable' (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "Stale deny lists -> FAIL"
home=$(mktmp)
install_into "$home"
# Create ~/.aws after install: filter would now add it, but JSON is stale.
mkdir -p "$home/.aws"
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "1" ]] && grep -q "stale\|drift" <<< "$out"; then
    pass "doctor exits 1 and reports stale deny lists"
else
    fail "expected exit 1 + stale/drift mention (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "Missing rc source line -> WARN, not FAIL"
home=$(mktmp)
install_into "$home"
# Ephemeral $HOME has no rc files at all — wrapper is unsourced.
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "0" ]] && grep -q "WARN" <<< "$out" && grep -q "vigil-aliases.sh not referenced" <<< "$out"; then
    pass "missing rc source produces WARN with exit 0"
else
    fail "expected exit 0 with WARN about missing rc source (rc=$rc, out: $out)"
fi

# Now drop a sourcing line into ~/.bashrc and re-run; warning should clear.
echo 'source ~/.config/vigil/vigil-aliases.sh' > "$home/.bashrc"
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "0" ]] && grep -q "vigil-aliases.sh referenced in" <<< "$out"; then
    pass "rc source line detected after add"
else
    fail "expected PASS on rc source line (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "Installed copy is invokable via shebang"
home=$(mktmp)
install_into "$home"
installed_doctor="$home/.config/vigil/doctor.sh"
rc=0
HOME="$home" "$installed_doctor" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then
    pass "installed doctor.sh runs via its shebang and exits 0"
else
    fail "installed doctor.sh failed to run (rc=$rc)"
fi

# -----------------------------------------------------------------------------
section "Missing installed tree -> FAIL"
home=$(mktmp)
# No install at all — every required path absent.
result=$(run_doctor "$home")
rc=$(printf '%s\n' "$result" | head -1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [[ "$rc" == "1" ]] && grep -q "missing:" <<< "$out"; then
    pass "doctor exits 1 when nothing is installed"
else
    fail "expected exit 1 + missing-path messages on empty \$HOME (rc=$rc)"
fi

exit $failed
