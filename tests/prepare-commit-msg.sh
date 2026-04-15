#!/usr/bin/env bash
# Tests for the prepare-commit-msg trailer-stamp hook template.
# Each case installs the hook into a fresh fixture repo and inspects
# `git log -1 --format=%B` after a commit.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/scripts/hooks/prepare-commit-msg"

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

# Per-invocation identity; sandbox blocks persistent git-config writes.
GIT_ID=(-c user.email=test@example.invalid -c user.name=vigil-hook-test)

# Initialize a repo with the hook installed and one initial commit.
seed_repo() {
    local repo="$1"
    git init -q "$repo"
    install -m 0755 "$HOOK" "$repo/.git/hooks/prepare-commit-msg"
    (cd "$repo" && env -u VIGIL_SESSION_ID \
        git "${GIT_ID[@]}" commit --allow-empty -qm 'initial')
}

trailer_count() {
    local repo="$1"
    (cd "$repo" && git log -1 --format=%B) \
        | grep -c '^Vigil-Session:' || true
}

last_trailer() {
    local repo="$1"
    (cd "$repo" && git log -1 --format=%B) \
        | grep '^Vigil-Session:' | tail -n1
}

# -----------------------------------------------------------------------------
section "Unset VIGIL_SESSION_ID writes no trailer"
repo=$(mktmp)
seed_repo "$repo"
(cd "$repo" && env -u VIGIL_SESSION_ID \
    git "${GIT_ID[@]}" commit --allow-empty -qm 'no session')
n=$(trailer_count "$repo")
[[ "$n" == "0" ]] && pass "no trailer when unset" \
    || fail "expected 0 trailers, got $n"

# -----------------------------------------------------------------------------
section "Valid id stamps exactly one trailer"
repo=$(mktmp)
seed_repo "$repo"
(cd "$repo" && VIGIL_SESSION_ID=20260414-120000 \
    git "${GIT_ID[@]}" commit --allow-empty -qm 'in session')
n=$(trailer_count "$repo")
t=$(last_trailer "$repo")
[[ "$n" == "1" && "$t" == "Vigil-Session: 20260414-120000" ]] \
    && pass "one trailer with correct value" \
    || fail "expected 1 trailer 20260414-120000, got n=$n value='$t'"

# -----------------------------------------------------------------------------
section "Amend with same id is idempotent"
repo=$(mktmp)
seed_repo "$repo"
(cd "$repo" && VIGIL_SESSION_ID=20260414-120000 \
    git "${GIT_ID[@]}" commit --allow-empty -qm 'in session')
(cd "$repo" && VIGIL_SESSION_ID=20260414-120000 \
    git "${GIT_ID[@]}" commit --amend --allow-empty --no-edit -q)
n=$(trailer_count "$repo")
[[ "$n" == "1" ]] && pass "amend same id keeps one trailer" \
    || fail "expected 1 trailer after amend, got $n"

# -----------------------------------------------------------------------------
section "Amend with different id appends a second"
repo=$(mktmp)
seed_repo "$repo"
(cd "$repo" && VIGIL_SESSION_ID=20260414-120000 \
    git "${GIT_ID[@]}" commit --allow-empty -qm 'in session')
(cd "$repo" && VIGIL_SESSION_ID=20260415-090000 \
    git "${GIT_ID[@]}" commit --amend --allow-empty --no-edit -q)
n=$(trailer_count "$repo")
[[ "$n" == "2" ]] && pass "amend different id appends" \
    || fail "expected 2 trailers after cross-session amend, got $n"

# -----------------------------------------------------------------------------
section "Malformed VIGIL_SESSION_ID is rejected silently"
for bad in '../../../tmp/pwned' 'not-a-date' '20260414' '20260414-12000' \
           '20260414-120000;rm -rf' '20260414-12000a'; do
    repo=$(mktmp)
    seed_repo "$repo"
    (cd "$repo" && VIGIL_SESSION_ID="$bad" \
        git "${GIT_ID[@]}" commit --allow-empty -qm 'malformed') \
        || { fail "commit failed for malformed id '$bad'"; continue; }
    n=$(trailer_count "$repo")
    [[ "$n" == "0" ]] && pass "rejected: $bad" \
        || fail "expected 0 trailers for '$bad', got $n"
done

# -----------------------------------------------------------------------------
section "Merge source skipped"
repo=$(mktmp)
seed_repo "$repo"
(
    cd "$repo"
    git "${GIT_ID[@]}" checkout -q -b feature
    git "${GIT_ID[@]}" commit --allow-empty -qm 'feature work'
    git "${GIT_ID[@]}" checkout -q master 2>/dev/null \
        || git "${GIT_ID[@]}" checkout -q main
    git "${GIT_ID[@]}" commit --allow-empty -qm 'main moves on'
    VIGIL_SESSION_ID=20260414-120000 \
        git "${GIT_ID[@]}" merge --no-ff --no-edit -q feature
)
n=$(trailer_count "$repo")
[[ "$n" == "0" ]] && pass "merge commit not stamped" \
    || fail "expected 0 trailers on merge commit, got $n"

# -----------------------------------------------------------------------------
section "Squash-merge source skipped"
# `git merge --squash` populates .git/SQUASH_MSG; the follow-up `git
# commit` invokes prepare-commit-msg with source="squash". (Autosquash
# via `git commit --squash=<sha>` is a different workflow and uses
# source="message" — those should be stamped, not skipped.)
repo=$(mktmp)
seed_repo "$repo"
(
    cd "$repo"
    git "${GIT_ID[@]}" checkout -q -b feature
    echo x > x.txt && git add x.txt
    git "${GIT_ID[@]}" commit -qm 'feature work'
    git "${GIT_ID[@]}" checkout -q master 2>/dev/null \
        || git "${GIT_ID[@]}" checkout -q main
    git "${GIT_ID[@]}" merge --squash feature -q
    VIGIL_SESSION_ID=20260414-120000 \
        git "${GIT_ID[@]}" commit --no-edit -q
)
n=$(trailer_count "$repo")
[[ "$n" == "0" ]] && pass "squash-merge commit not stamped" \
    || fail "expected 0 trailers on squash-merge commit, got $n"

# -----------------------------------------------------------------------------
echo
if [[ $failed -eq 0 ]]; then
    echo "All prepare-commit-msg tests passed."
    exit 0
else
    echo "Some prepare-commit-msg tests FAILED." >&2
    exit 1
fi
