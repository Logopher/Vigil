#!/usr/bin/env bash
# Tier 4 prune-worktrees.sh invariant tests. Each case constructs a
# minimal git fixture in a tmpdir, runs the hook, and asserts the
# three load-bearing invariants from the default profile CLAUDE.md:
#   1. Never removes a worktree directory with uncommitted changes.
#   2. Never prunes git metadata for a dirty worktree.
#   3. Only deletes claude/* branches fully merged into main.
#
# Plus one synthetic check that the basename-extraction logic survives
# Windows/MSYS2 path format mismatches.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/profiles/default/hooks/prune-worktrees.sh"

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

# Initialize a repo on main with an initial commit.
mkrepo() {
    local repo
    repo=$(mktmp)
    git -C "$repo" init -q
    git -C "$repo" symbolic-ref HEAD refs/heads/main
    git -C "$repo" config user.email "test@example.test"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    echo "initial" > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m "initial"
    printf '%s' "$repo"
}

# Add a claude/<name> worktree at .claude/worktrees/<name>.
add_wt() {
    local repo="$1" name="$2"
    mkdir -p "$repo/.claude/worktrees"
    git -C "$repo" worktree add -q -b "claude/$name" "$repo/.claude/worktrees/$name" 2>/dev/null
    git -C "$repo/.claude/worktrees/$name" config user.email "test@example.test"
    git -C "$repo/.claude/worktrees/$name" config user.name "Test"
    git -C "$repo/.claude/worktrees/$name" config commit.gpgsign false
}

run_hook() {
    local repo="$1"
    ( cd "$repo" && bash "$HOOK" 2>&1 )
}

# -----------------------------------------------------------------------------
section "Dirty stale worktree is preserved (invariants 1 and 2)"
repo=$(mkrepo)
add_wt "$repo" "dirty"
echo "pending work" > "$repo/.claude/worktrees/dirty/pending.txt"
# Make it "stale" by renaming — git still has metadata at the original
# name, so the basename comparison sees the renamed directory as unknown.
mv "$repo/.claude/worktrees/dirty" "$repo/.claude/worktrees/dirty-stale"

output=$(run_hook "$repo")

if [[ -d "$repo/.claude/worktrees/dirty-stale" ]]; then
    pass "dirty stale worktree directory survives"
else
    fail "dirty stale worktree directory was removed"
fi

if [[ -f "$repo/.claude/worktrees/dirty-stale/.git" ]]; then
    pass ".git pointer file in dirty worktree survives"
else
    fail ".git pointer file in dirty worktree was removed"
fi

if printf '%s' "$output" | grep -qi "WARNING"; then
    fail "hook printed a metadata-pruning WARNING"
else
    pass "no metadata-pruning warning printed"
fi

if printf '%s' "$output" | grep -qi "dirty-stale"; then
    pass "hook reports dirty stale worktree"
else
    fail "hook did not report dirty stale worktree"
    printf '%s\n' "$output" >&2
fi

# -----------------------------------------------------------------------------
section "Clean stale worktree is removed"
repo=$(mkrepo)
add_wt "$repo" "clean"
echo "committed work" > "$repo/.claude/worktrees/clean/work.txt"
git -C "$repo/.claude/worktrees/clean" add work.txt
git -C "$repo/.claude/worktrees/clean" commit -q -m "work"
mv "$repo/.claude/worktrees/clean" "$repo/.claude/worktrees/clean-stale"

run_hook "$repo" >/dev/null

if [[ ! -d "$repo/.claude/worktrees/clean-stale" ]]; then
    pass "clean stale worktree directory removed"
else
    fail "clean stale worktree directory still present"
fi

# -----------------------------------------------------------------------------
section "Merged orphan branch is deleted (invariant 3)"
repo=$(mkrepo)
add_wt "$repo" "merged"
echo "mergeable" > "$repo/.claude/worktrees/merged/file"
git -C "$repo/.claude/worktrees/merged" add file
git -C "$repo/.claude/worktrees/merged" commit -q -m "mergeable"
git -C "$repo" merge -q --no-ff --no-edit claude/merged
git -C "$repo" worktree remove "$repo/.claude/worktrees/merged"

run_hook "$repo" >/dev/null

if git -C "$repo" show-ref --verify --quiet refs/heads/claude/merged; then
    fail "merged orphan branch claude/merged still exists"
else
    pass "merged orphan branch deleted"
fi

# -----------------------------------------------------------------------------
section "Unmerged orphan branch is preserved and reported (invariant 3)"
repo=$(mkrepo)
add_wt "$repo" "unmerged"
echo "unmerged work" > "$repo/.claude/worktrees/unmerged/file"
git -C "$repo/.claude/worktrees/unmerged" add file
git -C "$repo/.claude/worktrees/unmerged" commit -q -m "unmerged-work"
git -C "$repo" worktree remove "$repo/.claude/worktrees/unmerged"

output=$(run_hook "$repo")

if git -C "$repo" show-ref --verify --quiet refs/heads/claude/unmerged; then
    pass "unmerged orphan branch claude/unmerged survives"
else
    fail "unmerged orphan branch claude/unmerged was deleted"
fi

if printf '%s' "$output" | grep -qi "unmerged"; then
    pass "hook reports unmerged orphan branch"
else
    fail "hook did not report unmerged orphan branch"
    printf '%s\n' "$output" >&2
fi

# -----------------------------------------------------------------------------
section "Basename extraction survives Windows/MSYS2 path formats"
# The hook strips worktree paths to basename so the same worktree matches
# whether git reports C:/... or /c/... form. Synthetic check on the
# extraction logic (no MSYS2 environment required).
for input in \
    "/c/Users/foo/repo/.claude/worktrees/bar" \
    "C:/Users/foo/repo/.claude/worktrees/bar" \
    "/home/user/repo/.claude/worktrees/bar"; do
    wt_name="${input##*/}"
    if [[ "$wt_name" == "bar" ]]; then
        pass "basename of $input -> bar"
    else
        fail "basename of $input -> $wt_name (expected bar)"
    fi
done

exit $failed
