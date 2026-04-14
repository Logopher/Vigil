#!/usr/bin/env bash
# End-to-end tests for scripts/vigil-review.py against real fixture repos.
# Sanitizer correctness lives in vigil-review-sanitizer.py; this suite
# exercises the CLI surface (range handling, trailer lookup, --prompt
# semantics, --from-hook self-check).
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/vigil-review.py"

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

# Init a repo with: an initial empty commit, then a commit whose subject
# contains a raw ANSI clear-screen sequence. Two commits so HEAD~1..HEAD
# is non-empty and HEAD..HEAD is empty.
seed_repo() {
    local repo="$1"
    (
        cd "$repo"
        git init -q
        git config user.email test@example.invalid
        git config user.name vigil-review-test
        git commit --allow-empty -qm 'initial'
        echo a > a.txt
        git add a.txt
        # ESC[2J ESC[H = clear screen + cursor home — the canonical
        # "hide your tracks" prompt for a paranoid review tool.
        git commit -qm "$(printf 'hostile\033[2J\033[Hsubject')"
    )
}

# -----------------------------------------------------------------------------
section "Empty range exits 0 with informative message"
repo=$(mktmp)
seed_repo "$repo"
out=$(python3 "$SCRIPT" -C "$repo" 'HEAD..HEAD' 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && grep -q 'No commits in range' <<< "$out"; then
    pass "empty range: rc=0, message present"
else
    fail "empty range (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "Hostile ESC sequence in commit subject is stripped from output"
repo=$(mktmp)
seed_repo "$repo"
# --from-hook avoids any interactive prompt; we only care about rendered output.
out=$(python3 "$SCRIPT" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1)
rc=$?
esc_count=$(printf '%s' "$out" | tr -d -c $'\033' | wc -c | tr -d ' ')
if [[ $rc -eq 0 && "$esc_count" == "0" ]]; then
    pass "no ESC byte (0x1b) in rendered output"
else
    fail "rc=$rc, ESC count=$esc_count"
fi

# -----------------------------------------------------------------------------
section "Vigil-Session trailer: missing transcript falls back cleanly"
repo=$(mktmp)
logdir=$(mktmp)
(
    cd "$repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name vigil-review-test
    git commit --allow-empty -qm 'first'
    git commit --allow-empty -qm "$(printf 'second\n\nVigil-Session: 20260414-000000')"
)
out=$(VIGIL_LOG_DIR="$logdir" python3 "$SCRIPT" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1)
if grep -q 'transcript not on this host' <<< "$out"; then
    pass "missing transcript yields informative note"
else
    fail "expected fallback note (got: $out)"
fi

# -----------------------------------------------------------------------------
section "Vigil-Session trailer: present transcript path is rendered"
touch "$logdir/session-20260414-000000.txt"
out=$(VIGIL_LOG_DIR="$logdir" python3 "$SCRIPT" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1)
if grep -q "$logdir/session-20260414-000000.txt" <<< "$out"; then
    pass "transcript path rendered when file exists"
else
    fail "expected transcript path (got: $out)"
fi

# -----------------------------------------------------------------------------
section "--prompt: y → exit 0; anything else → exit 1"
# /dev/tty is preferred but unavailable under setsid (no controlling
# terminal in the new session) — the script falls back to stdin. macOS
# bsd-base lacks setsid; skip these assertions there rather than fail
# spuriously.
if command -v setsid >/dev/null 2>&1; then
    repo=$(mktmp)
    seed_repo "$repo"
    rc=0
    setsid python3 "$SCRIPT" -C "$repo" --prompt 'HEAD~1..HEAD' >/dev/null 2>&1 <<< 'y' || rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "--prompt y → exit 0"
    else
        fail "--prompt y → exit $rc"
    fi
    rc=0
    setsid python3 "$SCRIPT" -C "$repo" --prompt 'HEAD~1..HEAD' >/dev/null 2>&1 <<< 'n' || rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--prompt n → exit 1"
    else
        fail "--prompt n → exit $rc"
    fi
else
    printf '  SKIP  setsid unavailable (--prompt interactive tests)\n'
fi

# -----------------------------------------------------------------------------
section "--from-hook: clean script passes self-check"
repo=$(mktmp)
seed_repo "$repo"
rc=0
out=$(python3 "$SCRIPT" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "self-check passes for repo-local script"
else
    fail "self-check should pass (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "--from-hook: world-writable script fails self-check with rc=2"
copy_dir=$(mktmp)
copy="$copy_dir/vigil-review.py"
cp "$SCRIPT" "$copy"
chmod 755 "$copy"
chmod o+w "$copy"
rc=0
out=$(python3 "$copy" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1) || rc=$?
if [[ $rc -eq 2 ]] && grep -q 'world-writable' <<< "$out"; then
    pass "world-writable script: rc=2 + diagnostic"
else
    fail "expected rc=2 + 'world-writable' (rc=$rc, out: $out)"
fi

exit $failed
