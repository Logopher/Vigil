#!/usr/bin/env bash
# prune-worktrees.sh — Session hook for worktree cleanup
# Runs at SessionStart and SessionEnd. Prunes stale worktree metadata,
# removes leftover directories, and deletes merged orphan branches.
#
# Safety guarantees:
# - Never removes a worktree directory that has uncommitted changes.
# - Never prunes git metadata for a dirty worktree.
# - Never deletes a branch that is not fully merged into main.
# All three conditions are reported to stdout for Claude to surface.

set -euo pipefail

# Find the repo root. If not in a git repo, exit silently.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

worktree_dir="$repo_root/.claude/worktrees"

# --- Step 1: Build list of active worktree names ---
# Compare by basename only to avoid Windows/MSYS2 path format mismatches
# (git returns C:/Users/... but bash expands to /c/Users/...).
active_names=""
while IFS= read -r line; do
    case "$line" in
        worktree\ *)
            wt_path="${line#worktree }"
            wt_name="${wt_path##*/}"
            active_names="$active_names|$wt_name|"
            ;;
    esac
done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)

# --- Step 2: Identify dirty stale worktrees (before pruning metadata) ---
# A dirty worktree has a valid .git pointer and uncommitted changes.
# We protect both its directory and its git metadata.
dirty_worktrees=""
protected_names=""
if [ -d "$worktree_dir" ]; then
    for dir in "$worktree_dir"/*/; do
        [ -d "$dir" ] || continue
        dir_norm="${dir%/}"
        dir_name="${dir_norm##*/}"
        if [[ "$active_names" == *"|$dir_name|"* ]]; then
            continue  # active worktree, not stale
        fi
        if [ -f "$dir_norm/.git" ] && git -C "$dir_norm" status --porcelain 2>/dev/null | grep -q .; then
            dirty_worktrees="$dirty_worktrees  $dir_name"$'\n'
            protected_names="$protected_names|$dir_name|"
        fi
    done
fi

# --- Step 3: Prune stale worktree metadata (excluding protected) ---
# git worktree prune only removes entries whose directories are gone.
# Dirty worktrees still have their directories, so prune won't touch them.
# We verify this after pruning as a safety check.
git -C "$repo_root" worktree prune 2>/dev/null || true

# Safety check: confirm dirty worktrees still have their git metadata
if [ -n "$protected_names" ]; then
    for dir in "$worktree_dir"/*/; do
        [ -d "$dir" ] || continue
        dir_norm="${dir%/}"
        dir_name="${dir_norm##*/}"
        if [[ "$protected_names" == *"|$dir_name|"* ]] && [ ! -f "$dir_norm/.git" ]; then
            echo "WARNING: git metadata was pruned for dirty worktree: $dir_name"
        fi
    done
fi

# --- Step 4: Remove clean stale worktree directories ---
if [ -d "$worktree_dir" ]; then
    for dir in "$worktree_dir"/*/; do
        [ -d "$dir" ] || continue
        dir_norm="${dir%/}"
        dir_name="${dir_norm##*/}"
        # Skip active worktrees
        if [[ "$active_names" == *"|$dir_name|"* ]]; then
            continue
        fi
        # Skip dirty worktrees
        if [[ "$protected_names" == *"|$dir_name|"* ]]; then
            continue
        fi
        rm -rf "$dir_norm" 2>/dev/null || true
    done
    # Remove any empty directories that remain
    find "$worktree_dir" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} \; 2>/dev/null || true
fi

if [ -n "$dirty_worktrees" ]; then
    echo "Stale worktrees with uncommitted changes (not removed):"
    echo "$dirty_worktrees"
fi

# --- Step 5: Collect active branches (from worktrees) ---
active_branches="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | grep '^branch ' | sed 's|^branch refs/heads/||')"

# --- Step 6: Delete merged orphan branches, report unmerged ones ---
unmerged=""
while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    if echo "$active_branches" | grep -qxF "$branch"; then
        continue  # branch has an active worktree, skip
    fi
    # Try safe delete (only succeeds if fully merged into main)
    if git -C "$repo_root" branch -d "$branch" 2>/dev/null; then
        echo "Deleted merged branch: $branch"
    else
        unmerged="$unmerged  $branch"$'\n'
    fi
done < <(git -C "$repo_root" branch --list 'claude/*' --format='%(refname:short)' 2>/dev/null)

if [ -n "$unmerged" ]; then
    echo "Unmerged orphan claude/* branches (need manual review):"
    echo "$unmerged"
fi
