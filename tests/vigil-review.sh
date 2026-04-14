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

# Identity passed via -c per invocation, never stored in repo .git/config —
# the sandbox blocks persistent git-config writes (see
# `feat(config): block persistent git-config and hooks writes...`).
GIT_ID=(-c user.email=test@example.invalid -c user.name=vigil-review-test)

# Two-commit repo: empty initial + one with an ANSI clear-screen subject.
# --cleanup=verbatim keeps the literal ESC bytes intact regardless of git's
# default commit.cleanup behavior, which varies by version.
seed_repo() {
    local repo="$1"
    (
        cd "$repo"
        git init -q
        git "${GIT_ID[@]}" commit --allow-empty -qm 'initial'
        echo a > a.txt
        git add a.txt
        git "${GIT_ID[@]}" commit --cleanup=verbatim \
            -qm "$(printf 'hostile\033[2J\033[Hsubject')"
    )
}

# Run vigil-review --prompt under a real pty so /dev/tty is usable. The
# script refuses to fall back to a non-TTY stdin (would consume hook
# protocol data), so simulating with `setsid + heredoc` is no longer
# valid — the test must provide a real terminal.
prompt_via_pty() {
    local repo="$1" answer="$2"
    python3 - "$SCRIPT" "$repo" "$answer" <<'PY'
import os, pty, sys
script, repo, answer = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.execvp('python3', ['python3', script, '-C', repo, '--prompt', 'HEAD~1..HEAD'])
os.write(fd, (answer + '\n').encode())
try:
    while os.read(fd, 4096):
        pass
except OSError:
    pass
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
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
    git "${GIT_ID[@]}" commit --allow-empty -qm 'first'
    git "${GIT_ID[@]}" commit --allow-empty --cleanup=verbatim \
        -qm "$(printf 'second\n\nVigil-Session: 20260414-000000')"
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
section "Vigil-Session trailer: malformed id is rejected"
bad_repo=$(mktmp)
(
    cd "$bad_repo"
    git init -q
    git "${GIT_ID[@]}" commit --allow-empty -qm 'first'
    git "${GIT_ID[@]}" commit --allow-empty --cleanup=verbatim \
        -qm "$(printf 'sneaky\n\nVigil-Session: ../../etc/passwd')"
)
out=$(VIGIL_LOG_DIR="$logdir" python3 "$SCRIPT" -C "$bad_repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1)
# The commit body itself will echo "Vigil-Session: ../../etc/passwd" verbatim
# (that is what the attacker committed); check specifically that the
# Transcript: line shows the rejection rather than a derived path under
# $logdir.
transcript_line=$(grep '^Transcript:' <<< "$out" || true)
if grep -q 'invalid Vigil-Session id (rejected)' <<< "$transcript_line" \
        && ! grep -q "$logdir" <<< "$transcript_line"; then
    pass "traversal-shaped session id is rejected; no derived path rendered"
else
    fail "expected rejection on Transcript line (got: $transcript_line)"
fi

# -----------------------------------------------------------------------------
section "--prompt: y → exit 0; anything else → exit 1"
repo=$(mktmp)
seed_repo "$repo"
rc=0
prompt_via_pty "$repo" y >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "--prompt y → exit 0"
else
    fail "--prompt y → exit $rc"
fi
rc=0
prompt_via_pty "$repo" n >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
    pass "--prompt n → exit 1"
else
    fail "--prompt n → exit $rc"
fi

# -----------------------------------------------------------------------------
section "--prompt: refuses non-TTY stdin without /dev/tty"
# setsid removes the controlling terminal, so /dev/tty is unavailable.
# The script must NOT silently consume the heredoc — that would let a
# pre-push hook invocation eat ref protocol data as the answer.
if command -v setsid >/dev/null 2>&1; then
    rc=0
    out=$(setsid python3 "$SCRIPT" -C "$repo" --prompt 'HEAD~1..HEAD' <<< 'y' 2>&1) || rc=$?
    if [[ $rc -eq 1 ]] && grep -q 'cannot prompt safely' <<< "$out"; then
        pass "no /dev/tty + non-TTY stdin → loud refusal, exit 1"
    else
        fail "expected loud refusal (rc=$rc, out: $out)"
    fi
else
    printf '  SKIP  setsid unavailable\n'
fi

# -----------------------------------------------------------------------------
section "--from-hook: clean script passes self-check"
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

# -----------------------------------------------------------------------------
section "--from-hook: world-writable parent dir fails self-check"
copy_dir=$(mktmp)
copy="$copy_dir/vigil-review.py"
cp "$SCRIPT" "$copy"
chmod 755 "$copy"
chmod o+w "$copy_dir"
rc=0
out=$(python3 "$copy" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1) || rc=$?
if [[ $rc -eq 2 ]] && grep -q 'parent dir is world-writable' <<< "$out"; then
    pass "world-writable parent dir: rc=2 + diagnostic"
else
    fail "expected rc=2 + 'parent dir is world-writable' (rc=$rc, out: $out)"
fi

# -----------------------------------------------------------------------------
section "Non-UTF-8 bytes in commit do not crash the viewer"
# Commit a file whose path is non-UTF-8. `git show --stat` will emit those
# bytes; without errors='replace' on the subprocess decode, the viewer
# would die with UnicodeDecodeError before sanitization runs.
repo=$(mktmp)
(
    cd "$repo"
    git init -q
    git "${GIT_ID[@]}" commit --allow-empty -qm 'initial'
    # Latin-1 byte 0xFF is invalid as a stand-alone UTF-8 byte.
    fname=$(printf 'name-\xff.txt')
    printf 'x\n' > "$fname"
    git add -- "$fname"
    git "${GIT_ID[@]}" -c core.quotepath=false commit -qm 'add non-utf8 path'
)
rc=0
out=$(python3 "$SCRIPT" -C "$repo" --from-hook 'HEAD~1..HEAD' </dev/null 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "viewer survives non-UTF-8 bytes in commit"
else
    fail "viewer crashed on non-UTF-8 (rc=$rc, out: $out)"
fi

exit $failed
