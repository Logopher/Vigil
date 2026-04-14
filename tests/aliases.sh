#!/usr/bin/env bash
# Tier 5 vigil-aliases.sh behavior tests.
#
# Strategy: source the aliases file, override the internal helper
# _vigil_run_with_logging with a stub that records $PWD and args to
# a capture file. This bypasses script(1) and the real claude binary
# (neither is needed to test the cd + delegate behavior of vigil-dev).
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
# shellcheck source=../vigil-aliases.sh
source "$REPO_DIR/vigil-aliases.sh"

# -----------------------------------------------------------------------------
section "Function definitions present after sourcing"
if [[ "$(type -t vigil)" == "function" ]]; then
    pass "vigil is a function"
else
    fail "vigil is not a function (got: '$(type -t vigil)')"
fi
# After the rebrand, 'claude' must NOT be a shell function — it should fall
# through to the upstream Claude Code binary (whatever 'command claude' resolves).
if [[ "$(type -t claude 2>/dev/null)" == "function" ]]; then
    fail "claude should not be a shell function after rebrand"
else
    pass "claude is not shadowed by a shell function"
fi
if [[ "$(type -t vigil-dev)" == "function" ]]; then
    pass "vigil-dev is a function"
else
    fail "vigil-dev is not a function (got: '$(type -t vigil-dev)')"
fi
if [[ "$(type -t _vigil_run_with_logging)" == "function" ]]; then
    pass "_vigil_run_with_logging helper is a function"
else
    fail "_vigil_run_with_logging helper is not a function"
fi

# -----------------------------------------------------------------------------
# Replace the helper with a stub that records where it was invoked from
# and with what arguments. Subshells inherit this redefinition.
_vigil_run_with_logging() {
    {
        printf 'PHYS_PWD='
        pwd -P
        printf 'LOG_PWD=%s\n' "$PWD"
        printf 'ARGS=%s\n' "$*"
    } >> "$CAPTURE_FILE"
}

# -----------------------------------------------------------------------------
section "vigil-dev cds to git repo root from a subdirectory"
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
( cd "$repo/sub/nested/deep" && vigil-dev )

captured=$(grep '^PHYS_PWD=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
expected=$(cd "$repo" && pwd -P)
if [[ "$captured" == "$expected" ]]; then
    pass "vigil-dev from subdir ran in repo root"
else
    fail "vigil-dev ran in '$captured' (expected '$expected')"
fi

# -----------------------------------------------------------------------------
section "vigil-dev in non-git directory stays in the current directory"
nongit=$(mktmp_dir)
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
( cd "$nongit" && vigil-dev )

captured=$(grep '^PHYS_PWD=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
expected=$(cd "$nongit" && pwd -P)
if [[ "$captured" == "$expected" ]]; then
    pass "vigil-dev in non-git dir runs in that dir"
else
    fail "vigil-dev ran in '$captured' (expected '$expected')"
fi

# -----------------------------------------------------------------------------
section "vigil-dev does not disturb caller's cwd"
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
# Invoke vigil-dev from a subdir; verify that after return the caller's
# cwd is unchanged (vigil-dev cds inside a subshell).
outer_after=$(cd "$repo/sub" && vigil-dev && pwd -P)
if [[ "$outer_before" == "$outer_after" ]]; then
    pass "caller's cwd preserved across vigil-dev"
else
    fail "caller's cwd changed: '$outer_before' -> '$outer_after'"
fi

# -----------------------------------------------------------------------------
section "vigil-dev passes --settings path and user args to the helper"
repo=$(mktmp_dir)
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.test"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
touch "$repo/f" && git -C "$repo" add f && git -C "$repo" commit -q -m init

CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
( cd "$repo" && vigil-dev --model claude-sonnet-4-6 "prompt text" )

args=$(grep '^ARGS=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
# Expect --settings <path-to-dev.json> at the front, then the user's args.
if [[ "$args" == *"--settings "*"/policies/dev.json"* ]]; then
    pass "vigil-dev passes --settings policies/dev.json"
else
    fail "vigil-dev did not pass expected --settings (got: $args)"
fi
if [[ "$args" == *"--model claude-sonnet-4-6"* ]]; then
    pass "vigil-dev forwards user flags"
else
    fail "vigil-dev did not forward --model (got: $args)"
fi
if [[ "$args" == *"prompt text"* ]]; then
    pass "vigil-dev forwards user positional args"
else
    fail "vigil-dev did not forward positional arg (got: $args)"
fi

# -----------------------------------------------------------------------------
section "vigil-strict passes --settings policies/strict.json + user args"
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
vigil-strict --model claude-sonnet-4-6 "strict prompt"

args=$(grep '^ARGS=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
if [[ "$args" == *"--settings "*"/policies/strict.json"* ]]; then
    pass "vigil-strict passes --settings policies/strict.json"
else
    fail "vigil-strict did not pass expected --settings (got: $args)"
fi
if [[ "$args" == *"--model claude-sonnet-4-6"* ]]; then
    pass "vigil-strict forwards user flags"
else
    fail "vigil-strict did not forward --model (got: $args)"
fi
if [[ "$args" == *"strict prompt"* ]]; then
    pass "vigil-strict forwards user positional args"
else
    fail "vigil-strict did not forward positional arg (got: $args)"
fi

# -----------------------------------------------------------------------------
section "vigil-yolo passes --settings policies/yolo.json + user args"
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
vigil-yolo --print "yolo prompt"

args=$(grep '^ARGS=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
if [[ "$args" == *"--settings "*"/policies/yolo.json"* ]]; then
    pass "vigil-yolo passes --settings policies/yolo.json"
else
    fail "vigil-yolo did not pass expected --settings (got: $args)"
fi
if [[ "$args" == *"--print"* ]]; then
    pass "vigil-yolo forwards user flags"
else
    fail "vigil-yolo did not forward --print (got: $args)"
fi
if [[ "$args" == *"yolo prompt"* ]]; then
    pass "vigil-yolo forwards user positional args"
else
    fail "vigil-yolo did not forward positional arg (got: $args)"
fi

# -----------------------------------------------------------------------------
section "Env scrub: credential vars stripped, allowlist preserved"
# Re-source aliases to restore the real _vigil_run_with_logging — the
# scrub happens inside it and earlier tests have stubbed it out.
unset -f _vigil_run_with_logging
# shellcheck source=../vigil-aliases.sh
source "$REPO_DIR/vigil-aliases.sh"

shim_dir=$(mktmp_dir)
fake_home=$(mktmp_dir)

# Stub script(1) to bypass the real binary and exec the inner command
# directly. Recognizes both util-linux (-B file -c cmd) and BSD
# ([-q] file cmd...) forms used by the production wrapper.
cat > "$shim_dir/script" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    -B)
        shift; shift; shift  # drop -B, logfile, -c
        exec bash -c "$1"
        ;;
    -q)
        shift; shift  # drop -q, logfile
        exec "$@"
        ;;
    *)
        echo "stub script: unrecognized form: $*" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$shim_dir/script"

# Stub claude: dump its inherited env to a capture file so the test
# can assert on what survived the scrub.
ENV_CAPTURE=$(mktmp_file)
export ENV_CAPTURE
cat > "$shim_dir/claude" <<STUB
#!/usr/bin/env bash
env > "$ENV_CAPTURE"
STUB
chmod +x "$shim_dir/claude"

# Allow ENV_CAPTURE through the scrub so the stub can write it back.
_vigil_env_allowlist+=(ENV_CAPTURE)

# Set credential-style vars (should be scrubbed) and one of each
# allowlist category (should survive).
export AWS_SECRET_ACCESS_KEY=should-be-scrubbed
export GITHUB_TOKEN=should-be-scrubbed
export ANTHROPIC_API_KEY=should-be-scrubbed
export NPM_TOKEN=should-be-scrubbed
export MY_CUSTOM_SECRET=should-be-scrubbed
export LC_TEST_VAR=should-survive
export GIT_AUTHOR_NAME=should-survive

HOME="$fake_home" PATH="$shim_dir:$PATH" vigil

assert_absent() {
    local var="$1"
    if grep -q "^$var=" "$ENV_CAPTURE"; then
        fail "env scrub: $var leaked into claude env"
    else
        pass "env scrub: $var removed"
    fi
}
assert_present() {
    local var="$1"
    if grep -q "^$var=" "$ENV_CAPTURE"; then
        pass "env scrub: $var preserved"
    else
        fail "env scrub: $var missing from claude env"
    fi
}

assert_absent AWS_SECRET_ACCESS_KEY
assert_absent GITHUB_TOKEN
assert_absent ANTHROPIC_API_KEY
assert_absent NPM_TOKEN
assert_absent MY_CUSTOM_SECRET

assert_present PATH
assert_present HOME
assert_present LC_TEST_VAR
assert_present GIT_AUTHOR_NAME
assert_present VIGIL_SESSION_ID
assert_present VIGIL_LOG_DIR

# Subshell isolation: the wrapper unsets vars inside its subshell, so
# the parent test shell must still see the originals.
if [[ "${AWS_SECRET_ACCESS_KEY:-}" == "should-be-scrubbed" ]]; then
    pass "env scrub: parent shell unaffected (subshell isolation)"
else
    fail "env scrub: parent AWS_SECRET_ACCESS_KEY changed; subshell leaked"
fi

unset AWS_SECRET_ACCESS_KEY GITHUB_TOKEN ANTHROPIC_API_KEY NPM_TOKEN \
      MY_CUSTOM_SECRET LC_TEST_VAR GIT_AUTHOR_NAME ENV_CAPTURE

# -----------------------------------------------------------------------------
section "vigil-log: error when no transcripts present"
fake_home=$(mktmp_dir)
out=$(HOME="$fake_home" vigil-log 2>&1)
rc=$?
if [[ $rc -ne 0 ]] && grep -q "no transcripts" <<<"$out"; then
    pass "vigil-log errors when no transcripts present"
else
    fail "vigil-log should fail with 'no transcripts' (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
section "vigil-log: index selection (no arg, -1, -2, out-of-range)"
fake_home=$(mktmp_dir)
mkdir -p "$fake_home/vigil-logs"
# Lex-sortable timestamps so newest = highest = ...0412.
echo "session A" > "$fake_home/vigil-logs/session-20260410-100000.txt"
echo "session B" > "$fake_home/vigil-logs/session-20260411-100000.txt"
echo "session C" > "$fake_home/vigil-logs/session-20260412-100000.txt"

out=$(HOME="$fake_home" PAGER=cat vigil-log)
if [[ "$out" == "session C" ]]; then
    pass "vigil-log (no arg) returns most recent"
else
    fail "vigil-log no-arg got '$out' (expected 'session C')"
fi

out=$(HOME="$fake_home" PAGER=cat vigil-log -1)
if [[ "$out" == "session B" ]]; then
    pass "vigil-log -1 returns previous"
else
    fail "vigil-log -1 got '$out' (expected 'session B')"
fi

out=$(HOME="$fake_home" PAGER=cat vigil-log -2)
if [[ "$out" == "session A" ]]; then
    pass "vigil-log -2 returns two-back"
else
    fail "vigil-log -2 got '$out' (expected 'session A')"
fi

out=$(HOME="$fake_home" PAGER=cat vigil-log -5 2>&1)
rc=$?
if [[ $rc -ne 0 ]] && grep -q "only" <<<"$out"; then
    pass "vigil-log out-of-range -N errors"
else
    fail "vigil-log -5 should error 'only N available' (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
section "vigil-log: date prefix matching (compact + dashed forms)"
# Two transcripts on the same day; date-prefix returns the most recent.
echo "morning" > "$fake_home/vigil-logs/session-20260413-090000.txt"
echo "evening" > "$fake_home/vigil-logs/session-20260413-180000.txt"

out=$(HOME="$fake_home" PAGER=cat vigil-log 20260413)
if [[ "$out" == "evening" ]]; then
    pass "vigil-log <YYYYMMDD> returns most recent of that day"
else
    fail "vigil-log 20260413 got '$out' (expected 'evening')"
fi

out=$(HOME="$fake_home" PAGER=cat vigil-log 2026-04-13)
if [[ "$out" == "evening" ]]; then
    pass "vigil-log <YYYY-MM-DD> strips dashes for match"
else
    fail "vigil-log 2026-04-13 got '$out' (expected 'evening')"
fi

out=$(HOME="$fake_home" PAGER=cat vigil-log 19990101 2>&1)
rc=$?
if [[ $rc -ne 0 ]] && grep -q "no transcript matching" <<<"$out"; then
    pass "vigil-log <unmatched date> errors"
else
    fail "vigil-log 19990101 should error (rc=$rc, out=$out)"
fi

# Multi-word PAGER (e.g. PAGER="less -R") must work via eval path.
out=$(HOME="$fake_home" PAGER="cat -" vigil-log)
if [[ -n "$out" ]]; then
    pass "vigil-log handles multi-word PAGER"
else
    fail "vigil-log multi-word PAGER produced no output"
fi

exit $failed
