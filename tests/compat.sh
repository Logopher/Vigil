#!/usr/bin/env bash
# Tier 6 platform compatibility. Two parts:
#
#   (a) Static: extract the `case "$(uname)"` patterns from
#       claude-aliases.sh and verify each platform COMPATIBILITY.md
#       claims to support ("Tested" or "Adapted") is matched by
#       some branch.
#
#   (b) Runtime: invoke the script(1) syntax corresponding to the
#       current OS to confirm the branch actually works. The other
#       OS's branch is SKIPped (it would require that other OS).
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ALIASES="$REPO_DIR/claude-aliases.sh"

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
skip() { printf '  SKIP  %s\n' "$1"; }
section() { printf '\n-- %s --\n' "$1"; }

TMPDIRS=()
cleanup() {
    local p
    for p in "${TMPDIRS[@]}"; do
        rm -rf "$p"
    done
}
trap cleanup EXIT

mktmp_file() {
    local f
    f=$(mktemp)
    TMPDIRS+=("$f")
    printf '%s' "$f"
}

# -----------------------------------------------------------------------------
section "case patterns match every supported uname"

# Expected `uname` outputs for each platform COMPATIBILITY.md lists with
# status Tested or Adapted. The Windows/MSYS2 entry is Untested in the
# matrix and deliberately omitted; if it becomes Adapted, add it here and
# ensure a matching branch exists.
expected_uname_values=(
    Linux
    Darwin
    FreeBSD
    OpenBSD
    NetBSD
)

# Extract patterns from the case statement. A pattern line looks like:
#     Darwin|*BSD)
# or:
#     *)
# Capture the token before the first ')'.
mapfile -t patterns < <(
    sed -n '/case "\$(uname)" in/,/esac/p' "$ALIASES" \
        | grep -oE '^[[:space:]]*[A-Za-z0-9_*|]+\)' \
        | sed -E 's/^[[:space:]]+//; s/\)$//' \
        | grep -v '^esac$' || true
)

if [[ ${#patterns[@]} -eq 0 ]]; then
    fail "could not extract case patterns from $ALIASES"
    exit 1
fi
pass "extracted case patterns: ${patterns[*]}"

matches_any_pattern() {
    local os="$1" pattern alt
    for pattern in "${patterns[@]}"; do
        IFS='|' read -ra alts <<< "$pattern"
        for alt in "${alts[@]}"; do
            # shellcheck disable=SC2254
            case "$os" in
                $alt) return 0 ;;
            esac
        done
    done
    return 1
}

for os in "${expected_uname_values[@]}"; do
    if matches_any_pattern "$os"; then
        pass "uname=$os matches a case branch"
    else
        fail "uname=$os is not matched by any branch in $ALIASES"
    fi
done

# -----------------------------------------------------------------------------
section "script(1) syntax works on this platform"

logfile=$(mktmp_file)
case "$(uname)" in
    Darwin|*BSD)
        # BSD script(1): script [-q] file command...
        if script -q "$logfile" true 2>/dev/null; then
            pass "BSD script(1) invocation succeeds on $(uname)"
        else
            fail "BSD script(1) invocation failed on $(uname)"
        fi
        skip "util-linux script(1) — not on Linux"
        ;;
    *)
        # util-linux script(1): script -B file -c cmd
        if script -B "$logfile" -c "true" >/dev/null 2>&1; then
            pass "util-linux script(1) invocation succeeds on $(uname)"
        else
            fail "util-linux script(1) invocation failed on $(uname)"
        fi
        skip "BSD script(1) — not on macOS or BSD"
        ;;
esac

exit $failed
