#!/usr/bin/env bash
# Tier 4 prune-logs.py behavior tests. Builds a temp --log-dir with
# crafted session pairs at various ages and sizes, invokes the
# pruner, and asserts the right files survive.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/prune-logs.py"

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

CLEANUP=()
trap 'for p in "${CLEANUP[@]}"; do rm -rf "$p"; done' EXIT

# make_pair <dir> <stamp> <age-seconds> <size-bytes>
# Creates session-<stamp>.{log,txt} with the given size and backdates
# mtime by age-seconds so the live-floor doesn't protect them. Uses
# Python to set mtime portably — `touch -d @epoch` is GNU-only.
make_pair() {
    local dir="$1" stamp="$2" age="$3" size="$4"
    local ext
    for ext in log txt; do
        local p="$dir/session-$stamp.$ext"
        head -c "$size" /dev/zero > "$p"
        python3 -c "import os, time; t=time.time()-$age; os.utime('$p',(t,t))"
    done
}

assert_exists() {
    if [[ -e "$1" ]]; then pass "exists: ${1##*/}"; else fail "missing: ${1##*/}"; fi
}
assert_gone() {
    if [[ ! -e "$1" ]]; then pass "pruned: ${1##*/}"; else fail "still present: ${1##*/}"; fi
}

# -----------------------------------------------------------------------------
section "Age pass deletes old pairs, keeps new"
d=$(mktemp -d); CLEANUP+=("$d")
make_pair "$d" "20250101-120000" $((100*86400)) 1000   # 100d old
make_pair "$d" "20260301-120000" $((43*86400))  1000   # 43d old
make_pair "$d" "20260413-140000" 3600           1000   # 1h old
python3 "$SCRIPT" --log-dir "$d" --older-than 90d --quiet
assert_gone   "$d/session-20250101-120000.log"
assert_gone   "$d/session-20250101-120000.txt"
assert_exists "$d/session-20260301-120000.log"
assert_exists "$d/session-20260413-140000.log"

# -----------------------------------------------------------------------------
section "Live floor protects files with recent mtime"
d=$(mktemp -d); CLEANUP+=("$d")
# Filename stamp parses as 100d-old, but mtime is fresh — should be kept.
make_pair "$d" "20250101-120000" 30 1000
python3 "$SCRIPT" --log-dir "$d" --older-than 0d --quiet
assert_exists "$d/session-20250101-120000.log"
assert_exists "$d/session-20250101-120000.txt"

# -----------------------------------------------------------------------------
section "Size cap deletes oldest-first until under cap"
d=$(mktemp -d); CLEANUP+=("$d")
make_pair "$d" "20260101-120000" $((30*86400)) 1000    # oldest
make_pair "$d" "20260201-120000" $((20*86400)) 1000
make_pair "$d" "20260301-120000" $((10*86400)) 1000    # newest (of these 3)
# Three pairs = 6000B. Cap at 3000B should leave one pair (2000B).
python3 "$SCRIPT" --log-dir "$d" --older-than 999d --max-total-size 3000 --quiet
assert_gone   "$d/session-20260101-120000.log"
assert_gone   "$d/session-20260201-120000.log"
assert_exists "$d/session-20260301-120000.log"
assert_exists "$d/session-20260301-120000.txt"

# -----------------------------------------------------------------------------
section "Dry-run deletes nothing"
d=$(mktemp -d); CLEANUP+=("$d")
make_pair "$d" "20250101-120000" $((100*86400)) 1000
out=$(python3 "$SCRIPT" --log-dir "$d" --older-than 90d --dry-run)
assert_exists "$d/session-20250101-120000.log"
assert_exists "$d/session-20250101-120000.txt"
if [[ "$out" == *"would prune 1"* ]]; then
    pass "dry-run output mentions 'would prune 1'"
else
    fail "dry-run output unexpected: $out"
fi

# -----------------------------------------------------------------------------
section "Orphan log (missing .txt) is prunable"
d=$(mktemp -d); CLEANUP+=("$d")
make_pair "$d" "20250101-120000" $((100*86400)) 1000
rm "$d/session-20250101-120000.txt"
python3 "$SCRIPT" --log-dir "$d" --older-than 90d --quiet
assert_gone "$d/session-20250101-120000.log"

# -----------------------------------------------------------------------------
section "Non-matching files are never touched"
d=$(mktemp -d); CLEANUP+=("$d")
make_pair "$d" "20250101-120000" $((100*86400)) 1000
echo "keep me" > "$d/notes.txt"
echo "keep me" > "$d/session-badname.log"
mkdir "$d/subdir"
python3 -c "import os,time; t=time.time()-100*86400
for p in ['$d/notes.txt','$d/session-badname.log']: os.utime(p,(t,t))"
python3 "$SCRIPT" --log-dir "$d" --older-than 90d --quiet
assert_gone   "$d/session-20250101-120000.log"
assert_exists "$d/notes.txt"
assert_exists "$d/session-badname.log"
assert_exists "$d/subdir"

# -----------------------------------------------------------------------------
section "Missing log-dir is a no-op, not an error"
if python3 "$SCRIPT" --log-dir /nonexistent/nope --quiet; then
    pass "exit 0 when log-dir absent"
else
    fail "nonzero exit when log-dir absent"
fi

# -----------------------------------------------------------------------------
printf '\n'
if [[ $failed -eq 0 ]]; then
    echo "prune-logs: all passed"
    exit 0
else
    echo "prune-logs: FAILED"
    exit 1
fi
