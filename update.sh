#!/usr/bin/env bash
# Refresh claude-config in place: uninstall → move user state aside
# → reinstall → restore user state. Preserves Claude Code runtime
# state and any user additions that did not originate from this repo.
#
# install.sh refuses to run if its destinations exist, so we clear
# them first by deferring to uninstall.sh (which removes only what
# this repo placed) and then moving whatever survives into a tempdir
# backup. After install.sh runs into clean dirs, `cp -rn` restores
# the backup — the -n flag means freshly installed files always win,
# so the backup only fills gaps (user additions, runtime state).
#
# On clean exit the backup is removed. On failure after the backup
# has been populated, we auto-rollback: wipe whatever install.sh left
# behind (it is partial/broken by assumption) and copy the backup
# back verbatim, restoring the pre-update state. Only if the rollback
# itself fails do we fall back to preserving the backup at its tempdir
# path and printing that path for manual recovery.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
DEST_DIR="$HOME/.config/claude-config"

assume_yes=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<USAGE
Usage: ./update.sh [-y]

Reinstalls claude-config over the existing install. Runtime state
in ~/.claude/ (credentials, sessions, history, projects, etc.) and
user additions under ~/.claude/agents/, ~/.claude/hooks/, and
~/.config/claude-config/ are preserved.

Pass -y to skip the confirmation prompt (and forward it to uninstall.sh).
USAGE
            exit 0
            ;;
        -y) assume_yes=1 ;;
        *)
            printf 'Unknown option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

if [[ $assume_yes -eq 0 ]]; then
    read -r -p "This will reinstall claude-config over your existing install. Continue? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Aborted." >&2; exit 1 ;;
    esac
fi

backup_dir="$(mktemp -d)"
# keep_backup=0 until the move-aside starts. Before that, the backup
# is empty, so any failure (e.g., uninstall.sh exits non-zero) should
# silently clean it up rather than print a misleading "preserved" path.
keep_backup=0

# Restore the live dirs from $backup_dir. Called from the EXIT trap
# when a failure occurs after the backup has been populated. Wipes
# whatever install.sh partially wrote (broken by assumption) and
# copies the backup back verbatim. Disables errexit for the duration
# so a single cp/rm hiccup doesn't abort mid-rollback; returns
# non-zero if any step fails so the trap can fall back to preserving
# the backup.
#
# Narrow caveat: `keep_backup` is set to 1 before move_contents, so a
# mid-move_contents failure (mv of the entry list partially succeeds)
# could leave live-dir entries neither in the backup nor recoverable
# by rollback. Accepted: mv-of-entries-at-once is atomic enough in
# practice that closing this window is not worth the complexity.
rollback() {
    set +e
    local rc=0 dir
    shopt -s nullglob dotglob
    for dir in "$CLAUDE_DIR" "$DEST_DIR"; do
        if [[ -d "$dir" ]]; then
            local entries=("$dir"/*)
            if (( ${#entries[@]} > 0 )); then
                rm -rf -- "${entries[@]}" || rc=1
            fi
        else
            mkdir -p "$dir" || rc=1
        fi
    done
    shopt -u nullglob dotglob
    cp -r -- "$backup_dir/claude/." "$CLAUDE_DIR/" || rc=1
    cp -r -- "$backup_dir/config/." "$DEST_DIR/"   || rc=1
    return $rc
}

on_exit() {
    if [[ $keep_backup -eq 1 ]]; then
        if rollback; then
            rm -rf "$backup_dir"
            echo "update.sh: update aborted; rolled back to pre-update state" >&2
        else
            echo "update.sh: error encountered AND rollback failed; backup preserved at $backup_dir" >&2
        fi
    else
        rm -rf "$backup_dir"
    fi
}
trap on_exit EXIT

"$REPO_DIR/uninstall.sh" -y

mkdir -p "$backup_dir/claude" "$backup_dir/config"

# Move every entry (including dotfiles) out of $src into $dst, then
# rmdir the now-empty $src so install.sh's "refuses if exists" check
# does not trip. rmdir is best-effort: if $src somehow became
# non-empty (e.g., a nested user dir uninstall couldn't tidy), the
# move-aside failed to clear it and install.sh will surface the
# conflict — better than silently overwriting.
move_contents() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 0
    shopt -s dotglob
    local entries=("$src"/*)
    shopt -u dotglob
    if (( ${#entries[@]} > 0 )); then
        mv -- "${entries[@]}" "$dst/"
    fi
    rmdir "$src" 2>/dev/null || true
}
# From here on, the backup may hold load-bearing state — flip the
# trap into "preserve on any failure" mode before the first mv.
keep_backup=1
move_contents "$CLAUDE_DIR" "$backup_dir/claude"
move_contents "$DEST_DIR"   "$backup_dir/config"

"$REPO_DIR/install.sh"

# cp -rn: backups fill gaps but never overwrite freshly installed
# files. Bundled files always come from the new install (uninstall
# removed the old ones; backup never had them). User additions and
# runtime state come from the backup. Errors here are real (disk
# full, permissions) — let them propagate so the trap preserves the
# backup for manual recovery.
cp -rn "$backup_dir/claude/." "$CLAUDE_DIR/"
cp -rn "$backup_dir/config/." "$DEST_DIR/"

keep_backup=0
echo "Updated."
