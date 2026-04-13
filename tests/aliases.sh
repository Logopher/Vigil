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

# -----------------------------------------------------------------------------
section "claude-strict passes --settings policies/strict.json + user args"
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
claude-strict --model claude-sonnet-4-6 "strict prompt"

args=$(grep '^ARGS=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
if [[ "$args" == *"--settings "*"/policies/strict.json"* ]]; then
    pass "claude-strict passes --settings policies/strict.json"
else
    fail "claude-strict did not pass expected --settings (got: $args)"
fi
if [[ "$args" == *"--model claude-sonnet-4-6"* ]]; then
    pass "claude-strict forwards user flags"
else
    fail "claude-strict did not forward --model (got: $args)"
fi
if [[ "$args" == *"strict prompt"* ]]; then
    pass "claude-strict forwards user positional args"
else
    fail "claude-strict did not forward positional arg (got: $args)"
fi

# -----------------------------------------------------------------------------
section "claude-yolo passes --settings policies/yolo.json + user args"
CAPTURE_FILE=$(mktmp_file)
export CAPTURE_FILE
claude-yolo --print "yolo prompt"

args=$(grep '^ARGS=' "$CAPTURE_FILE" | head -1 | cut -d= -f2-)
if [[ "$args" == *"--settings "*"/policies/yolo.json"* ]]; then
    pass "claude-yolo passes --settings policies/yolo.json"
else
    fail "claude-yolo did not pass expected --settings (got: $args)"
fi
if [[ "$args" == *"--print"* ]]; then
    pass "claude-yolo forwards user flags"
else
    fail "claude-yolo did not forward --print (got: $args)"
fi
if [[ "$args" == *"yolo prompt"* ]]; then
    pass "claude-yolo forwards user positional args"
else
    fail "claude-yolo did not forward positional arg (got: $args)"
fi

# -----------------------------------------------------------------------------
section "Env scrub: credential vars stripped, allowlist preserved"
# Re-source aliases to restore the real _claude_run_with_logging — the
# scrub happens inside it and earlier tests have stubbed it out.
unset -f _claude_run_with_logging
# shellcheck source=../claude-aliases.sh
source "$REPO_DIR/claude-aliases.sh"

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
_claude_env_allowlist+=(ENV_CAPTURE)

# Set credential-style vars (should be scrubbed) and one of each
# allowlist category (should survive).
export AWS_SECRET_ACCESS_KEY=should-be-scrubbed
export GITHUB_TOKEN=should-be-scrubbed
export ANTHROPIC_API_KEY=should-be-scrubbed
export NPM_TOKEN=should-be-scrubbed
export MY_CUSTOM_SECRET=should-be-scrubbed
export LC_TEST_VAR=should-survive
export GIT_AUTHOR_NAME=should-survive

HOME="$fake_home" PATH="$shim_dir:$PATH" claude

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
assert_present CLAUDE_SESSION_ID
assert_present CLAUDE_LOG_DIR

# Subshell isolation: the wrapper unsets vars inside its subshell, so
# the parent test shell must still see the originals.
if [[ "${AWS_SECRET_ACCESS_KEY:-}" == "should-be-scrubbed" ]]; then
    pass "env scrub: parent shell unaffected (subshell isolation)"
else
    fail "env scrub: parent AWS_SECRET_ACCESS_KEY changed; subshell leaked"
fi

unset AWS_SECRET_ACCESS_KEY GITHUB_TOKEN ANTHROPIC_API_KEY NPM_TOKEN \
      MY_CUSTOM_SECRET LC_TEST_VAR GIT_AUTHOR_NAME ENV_CAPTURE

exit $failed
