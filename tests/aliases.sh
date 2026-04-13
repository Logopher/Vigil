#!/usr/bin/env bash
# Tier 5 claude-aliases.sh behavior tests.
#
# Strategy: source the aliases file, override the internal helper
# _claude_run_with_logging with a stub that records $PWD and args to
# a capture file. This bypasses script(1) and the real claude binary
# (neither is needed to test the cd + delegate behavior of claude-dev).
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

CLEANUP=()
cleanup() {
    local p
    for p in "${CLEANUP[@]}"; do
        rm -rf "$p"
    done
}
trap cleanup EXIT

mktmp_dir() {
    local d
    d=$(mktemp -d)
    CLEANUP+=("$d")
    printf '%s' "$d"
}
mktmp_file() {
    local f
    f=$(mktemp)
    CLEANUP+=("$f")
    printf '%s' "$f"
}

# Source the aliases.
# shellcheck source=../claude-aliases.sh
source "$REPO_DIR/claude-aliases.sh"

# -----------------------------------------------------------------------------
section "Function definitions present after sourcing"
if [[ "$(type -t claude)" == "function" ]]; then
    pass "claude is a function"
else
    fail "claude is not a function (got: '$(type -t claude)')"
fi
if [[ "$(type -t claude-dev)" == "function" ]]; then
    pass "claude-dev is a function"
else
    fail "claude-dev is not a function (got: '$(type -t claude-dev)')"
fi
if [[ "$(type -t _claude_run_with_logging)" == "function" ]]; then
    pass "_claude_run_with_logging helper is a function"
else
    fail "_claude_run_with_logging helper is not a function"
fi

# -----------------------------------------------------------------------------
# Replace the helper with a stub that records where it was invoked from
# and with what arguments. Subshells inherit this redefinition.
_claude_run_with_logging() {
    {
        printf 'PHYS_PWD='
        pwd -P
        printf 'LOG_PWD=%s\n' "$PWD"
        printf 'ARGS=%s\n' "$*"
    } >> "$CAPTURE_FILE"
}

# -----------------------------------------------------------------------------
section "claude-dev cds to git repo root from a subdirectory"
repo=$(mktmp_dir)
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.test"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
echo init > "$repo/README"
git -C "$repo" add README
git -C "$repo" commit -q -m init
mkdir -p "$repo/sub/nested/deep"

CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
( cd "$repo/sub/nested/deep" && claude-dev )

captured=$(grep '^PHYS_PWD=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
expected=$(cd "$repo" && pwd -P)
if [[ "$captured" == "$expected" ]]; then
    pass "claude-dev from subdir ran in repo root"
else
    fail "claude-dev ran in '$captured' (expected '$expected')"
fi

# -----------------------------------------------------------------------------
section "claude-dev in non-git directory stays in the current directory"
nongit=$(mktmp_dir)
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
( cd "$nongit" && claude-dev )

captured=$(grep '^PHYS_PWD=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
expected=$(cd "$nongit" && pwd -P)
if [[ "$captured" == "$expected" ]]; then
    pass "claude-dev in non-git dir runs in that dir"
else
    fail "claude-dev ran in '$captured' (expected '$expected')"
fi

# -----------------------------------------------------------------------------
section "claude-dev does not disturb caller's cwd"
repo=$(mktmp_dir)
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.test"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
touch "$repo/f" && git -C "$repo" add f && git -C "$repo" commit -q -m init
mkdir -p "$repo/sub"

outer_before=$(cd "$repo/sub" && pwd -P)
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
# Invoke claude-dev from a subdir; verify that after return the caller's
# cwd is unchanged (claude-dev cds inside a subshell).
outer_after=$(cd "$repo/sub" && claude-dev && pwd -P)
if [[ "$outer_before" == "$outer_after" ]]; then
    pass "caller's cwd preserved across claude-dev"
else
    fail "caller's cwd changed: '$outer_before' -> '$outer_after'"
fi

# -----------------------------------------------------------------------------
section "claude-dev passes --settings path and user args to the helper"
repo=$(mktmp_dir)
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.test"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
touch "$repo/f" && git -C "$repo" add f && git -C "$repo" commit -q -m init

CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
( cd "$repo" && claude-dev --model claude-sonnet-4-6 "prompt text" )

args=$(grep '^ARGS=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
# Expect --settings <path-to-dev.json> at the front, then the user's args.
if [[ "$args" == *"--settings "*"/policies/dev.json"* ]]; then
    pass "claude-dev passes --settings policies/dev.json"
else
    fail "claude-dev did not pass expected --settings (got: $args)"
fi
if [[ "$args" == *"--model claude-sonnet-4-6"* ]]; then
    pass "claude-dev forwards user flags"
else
    fail "claude-dev did not forward --model (got: $args)"
fi
if [[ "$args" == *"prompt text"* ]]; then
    pass "claude-dev forwards user positional args"
else
    fail "claude-dev did not forward positional arg (got: $args)"
fi

exit $failed
