#!/usr/bin/env bash
# Refresh Vigil in place: uninstall → move user state aside
# → reinstall → restore user state. Preserves Claude Code runtime
# state and any user additions that did not originate from this repo.
#
# install.sh refuses to run if its destinations exist, so we clear
# them first by deferring to uninstall.sh (which removes only what
# this repo placed) and then moving whatever survives into a tempdir
# backup. After install.sh runs into clean dirs, `cp -r` with a
# no-overwrite flag restores the backup — freshly installed files
# always win, so the backup only fills gaps (user additions, runtime
# state). The exact flag is platform-branched: GNU coreutils ≥ 9.2
# deprecates `-n` and prefers `--update=none`; BSD `cp` supports
# only `-n`. See `COMPATIBILITY.md` → *Known portability concerns*.
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
DEST_DIR="$HOME/.config/vigil"

assume_yes=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<USAGE
Usage: ./update.sh [-y]

Reinstalls Vigil over the existing install. Runtime state
in ~/.claude/ (credentials, sessions, history, projects, etc.) and
user additions under ~/.claude/agents/, ~/.claude/hooks/, and
~/.config/vigil/ are preserved.

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
    read -r -p "This will reinstall Vigil over your existing install. Continue? [y/N] " ans
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
    # Restore Vigil-installed files from the manifest snapshot too —
    # uninstall.sh has already destroyed them by this point, and they
    # are NOT in $backup_dir/{claude,config}/ because move_contents
    # only captures what survived uninstall. The snapshot subtree is
    # the only record of pre-update Vigil content, including any user
    # edits to those files.
    if [[ -d "$backup_dir/manifest-snapshot/claude" ]]; then
        cp -r -- "$backup_dir/manifest-snapshot/claude/." "$CLAUDE_DIR/" || rc=1
    fi
    if [[ -d "$backup_dir/manifest-snapshot/config" ]]; then
        cp -r -- "$backup_dir/manifest-snapshot/config/." "$DEST_DIR/" || rc=1
    fi
    if [[ -f "$backup_dir/manifest-snapshot/.install-manifest" ]]; then
        cp -- "$backup_dir/manifest-snapshot/.install-manifest" \
              "$DEST_DIR/.install-manifest" || rc=1
    fi
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

# Snapshot the live manifest plus the live content of every manifest
# entry before uninstall removes them. uninstall.sh removes Vigil-
# installed files by name regardless of content, so a user-edited
# CLAUDE.md or policy file is destroyed at uninstall time; move_contents
# later sees only what uninstall left behind (user additions and
# runtime state). The snapshot captures the divergence evidence into
# $backup_dir/manifest-snapshot/ — deliberately separate from
# $backup_dir/{claude,config}/ so it doesn't collide with the
# move_contents staging below — so the post-install reconcile step
# can swap the user's edit back into place.
mkdir -p "$backup_dir/claude" "$backup_dir/config"
snapshot_failed=0
if [[ -f "$DEST_DIR/.install-manifest" ]]; then
    # Tolerate snapshot failures (e.g. python3 missing, disk full) by
    # falling through to the legacy gap-fill semantics — same outcome
    # as an install that predates the manifest feature. The genuine
    # failure modes that should abort the update fire later, inside
    # install.sh or the reconcile call, where keep_backup=1 makes the
    # rollback trap fire.
    if ! python3 "$REPO_DIR/scripts/install-manifest.py" snapshot "$backup_dir"; then
        snapshot_failed=1
        echo "update.sh: snapshot failed; user-edited Vigil files will be clobbered this update" >&2
    fi
fi

"$REPO_DIR/uninstall.sh" -y

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

# Identify which Vigil-installed files the user edited since the last
# install/update. install-manifest.py reads the snapshotted manifest
# under $backup_dir/manifest-snapshot/ (captured before uninstall ran)
# and prints absolute live paths whose snapshot content diverges from
# the recorded hash. The list is empty on a clean update and on first
# updates after an install that predates this feature (no snapshot →
# manifest absent → stderr note, captured but tolerated).
#
# Captures via tempfile rather than `mapfile -t … < <(…)` for two
# reasons: mapfile is bash 4+ (not on macOS system bash 3.2), and
# process substitution swallows the python3 exit code so a crash in
# diverged would silently skip reconcile instead of firing rollback.
diverged_paths=()
diverged_tmp=$(mktemp)
if [[ -f "$backup_dir/manifest-snapshot/.install-manifest" ]]; then
    python3 "$REPO_DIR/scripts/install-manifest.py" diverged "$backup_dir" > "$diverged_tmp"
    while IFS= read -r line; do
        [[ -n "$line" ]] && diverged_paths+=("$line")
    done < "$diverged_tmp"
else
    echo "update.sh: no manifest in backup; user-edited Vigil files will be clobbered this update" >&2
fi
rm -f -- "$diverged_tmp"

"$REPO_DIR/install.sh"

# Reconcile diverged paths: for each file the user edited, rename the
# freshly-installed copy to <name>.new.<ext> and restore the user's
# edit into place. Emits TSV "<preserved>\t<staged>" per pair. Single
# Python invocation so a mid-reconcile failure is one exit code from
# bash's view — the existing rollback() trap then erases the partial
# swap and restores pre-update state.
reconciled_tsv=""
if (( ${#diverged_paths[@]} > 0 )); then
    reconciled_tsv=$(
        python3 "$REPO_DIR/scripts/install-manifest.py" reconcile "$backup_dir"
    )
fi

# Restore: backups fill gaps but never overwrite freshly installed
# files. Bundled files always come from the new install (uninstall
# removed the old ones; backup never had them). User additions and
# runtime state come from the backup. Errors here are real (disk
# full, permissions) — let them propagate so the trap preserves the
# backup for manual recovery.
#
# Flag selection: GNU coreutils ≥ 9.2 emits a deprecation warning for
# `cp -n` and prefers `--update=none`; BSD `cp` (macOS, *BSD) supports
# only `-n`. Both flags have identical "skip if dest exists, exit 0"
# semantics, so `set -euo pipefail` behaviour is unaffected.
case "$(uname)" in
    Darwin|*BSD) CP_NO_OVERWRITE=(-n) ;;
    *)           CP_NO_OVERWRITE=(--update=none) ;;
esac
cp -r "${CP_NO_OVERWRITE[@]}" "$backup_dir/claude/." "$CLAUDE_DIR/"
cp -r "${CP_NO_OVERWRITE[@]}" "$backup_dir/config/." "$DEST_DIR/"

keep_backup=0
echo "Updated."

# Repeat the snapshot-failure warning on stdout if it fired earlier
# (the stderr line is easy to miss when stdout is redirected). The
# downgrade is the same regardless: any user edits to Vigil files
# were clobbered by the fresh install in this run.
if [[ $snapshot_failed -eq 1 ]]; then
    printf '\nNote: pre-update snapshot failed; any user edits to Vigil-managed\n'
    printf 'files were clobbered by the fresh install in this run.\n'
fi

# Summarize preserved user edits, if any. Each line of reconciled_tsv
# is "<preserved-path>\t<staged-path>" (staged is empty when the file
# is no longer part of the fresh install, so the user's edit is the
# only copy). The trailing nudge points the operator at the manifest
# writer in case they want to accept their edit as the new baseline
# and avoid the same flag on the next update.
if [[ -n "$reconciled_tsv" ]]; then
    n_preserved=$(printf '%s\n' "$reconciled_tsv" | wc -l | tr -d ' ')
    printf '\nPreserved user edits to %d Vigil-managed file(s). Fresh versions are\n' "$n_preserved"
    printf 'staged adjacent as <name>.new.<ext>:\n\n'
    while IFS=$'\t' read -r preserved staged; do
        display_preserved="${preserved/#$HOME/\~}"
        if [[ -n "$staged" ]]; then
            display_staged="${staged/#$HOME/\~}"
            printf '  %s\n    (new at %s)\n' "$display_preserved" "$display_staged"
        else
            printf '  %s\n    (no staged copy — fresh install no longer ships this file)\n' "$display_preserved"
        fi
    done <<< "$reconciled_tsv"
    printf '\nReview each .new.<ext> file. To accept the upstream version, replace\n'
    printf 'the live file with it; to keep your edit, delete the .new.<ext> file.\n'
    printf 'Either way, re-run the manifest writer or the next update will keep\n'
    printf 'flagging the same divergence:\n'
    printf '    python3 ~/.config/vigil/scripts/install-manifest.py write\n'
fi
