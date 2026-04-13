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
# On clean exit the backup is removed. On failure it is preserved
# and its path is printed so the operator can recover manually.
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
on_exit() {
    if [[ $keep_backup -eq 1 ]]; then
        echo "update.sh: error encountered; backup preserved at $backup_dir" >&2
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
