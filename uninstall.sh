#!/usr/bin/env bash
# Uninstall Vigil. Removes only files placed by install.sh;
# Claude Code runtime state in ~/.claude/ (credentials, sessions,
# history, projects, etc.) is preserved, as are any user additions
# under ~/.claude/agents/ and ~/.claude/hooks/ that did not originate
# from this repo.
set -euo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/vigil"
CLAUDE_DIR="$HOME/.claude"

display_path() { printf '%s' "${1/#$HOME/\~}"; }

assume_yes=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<USAGE
Usage: ./uninstall.sh [-y]

Removes files placed by install.sh:
  $(display_path "$DEST_DIR/claude-aliases.sh")
  $(display_path "$DEST_DIR/doctor.sh")
  $(display_path "$DEST_DIR/policies/")*.json
  $(display_path "$DEST_DIR/scripts/")*
  $(display_path "$DEST_DIR/profiles/default") (symlink)
  $(display_path "$CLAUDE_DIR/CLAUDE.md")
  $(display_path "$CLAUDE_DIR/settings.json")
  $(display_path "$CLAUDE_DIR/agents/")<files installed by this repo>
  $(display_path "$CLAUDE_DIR/hooks/")<files installed by this repo>

Claude Code runtime state in $(display_path "$CLAUDE_DIR") (credentials,
sessions, history, projects, etc.) is preserved. Files under agents/
and hooks/ that did not come from this repo are also preserved.
Empty parent directories are removed; non-empty ones are left alone.

Pass -y to skip the confirmation prompt.
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

# -----------------------------------------------------------------------------
# Build the to-remove list by mirroring install.sh's layout.

to_remove=()
add_if_exists() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        to_remove+=("$path")
    fi
}

add_if_exists "$DEST_DIR/claude-aliases.sh"
add_if_exists "$DEST_DIR/doctor.sh"

for src in "$REPO_DIR/policies/"*; do
    fname="$(basename "$src")"
    if [[ "$fname" == *.template.* ]]; then
        add_if_exists "$DEST_DIR/policies/${fname/.template./.}"
    else
        add_if_exists "$DEST_DIR/policies/$fname"
    fi
done

for src in "$REPO_DIR/scripts/"*; do
    add_if_exists "$DEST_DIR/scripts/$(basename "$src")"
done

add_if_exists "$DEST_DIR/profiles/default"

# Profile contents inside $CLAUDE_DIR. For directories (agents/, hooks/),
# only remove the specific files that exist in the repo — leave any
# user-added files alone.
for src in "$REPO_DIR/profiles/default/"*; do
    fname="$(basename "$src")"
    if [[ -d "$src" ]]; then
        while IFS= read -r -d '' f; do
            rel="${f#"$src"/}"
            add_if_exists "$CLAUDE_DIR/$fname/$rel"
        done < <(find "$src" -type f -print0)
    elif [[ "$fname" == *.template.* ]]; then
        add_if_exists "$CLAUDE_DIR/${fname/.template./.}"
    else
        add_if_exists "$CLAUDE_DIR/$fname"
    fi
done

if [[ ${#to_remove[@]} -eq 0 ]]; then
    echo "Nothing to remove. Vigil does not appear to be installed." >&2
    exit 0
fi

# -----------------------------------------------------------------------------
echo "Will remove:"
for p in "${to_remove[@]}"; do
    echo "  $(display_path "$p")"
done
echo
echo "Claude Code runtime state in $(display_path "$CLAUDE_DIR") (credentials,"
echo "sessions, history, projects, etc.) will be preserved."
echo

if [[ $assume_yes -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Aborted." >&2; exit 1 ;;
    esac
fi

for p in "${to_remove[@]}"; do
    rm -f -- "$p"
done

# Tidy up directories created by install.sh. rmdir refuses non-empty
# dirs, so user additions and runtime state are preserved automatically.
# Subdirs under profiles/default/ are derived from the repo so new ones
# (e.g., commands/) are picked up without editing this script.
empty_dirs=("$DEST_DIR/policies" "$DEST_DIR/scripts" "$DEST_DIR/profiles")
for src in "$REPO_DIR/profiles/default/"*; do
    [[ -d "$src" ]] && empty_dirs+=("$CLAUDE_DIR/$(basename "$src")")
done
empty_dirs+=("$DEST_DIR" "$CLAUDE_DIR")
rmdir -- "${empty_dirs[@]}" 2>/dev/null || true

echo "Done."
