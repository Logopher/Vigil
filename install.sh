#!/usr/bin/env bash
# Install the claude-config tree to $HOME/.config/claude-config/ and
# symlink ~/.claude to the default profile.
set -euo pipefail
shopt -s nullglob

FORCE=0
for arg in "$@"; do
    case "$arg" in
        -f|--force)
            FORCE=1
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: ./install.sh [--force]

Copies claude-config into ~/.config/claude-config/ and symlinks
~/.claude to the default profile. Any existing install or ~/.claude
is moved to a timestamped backup. --force skips the backup and
overwrites directly.
USAGE
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/claude-config"
CLAUDE_LINK="$HOME/.claude"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

move_aside() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ "$FORCE" -eq 1 ]]; then
        rm -rf -- "$path"
        return 0
    fi
    local backup="${path}.bak-${TIMESTAMP}"
    mv -- "$path" "$backup"
    printf 'Moved %s to %s\n' "$path" "$backup"
}

move_aside "$DEST_DIR"
mkdir -p "$DEST_DIR"

cp "$REPO_DIR/claude-aliases.sh" "$DEST_DIR/claude-aliases.sh"

mkdir -p "$DEST_DIR/policies"
for policy in "$REPO_DIR/policies/"*.json; do
    cp "$policy" "$DEST_DIR/policies/"
done

for src_profile in "$REPO_DIR/profiles/"*/; do
    name="$(basename "$src_profile")"
    dest_profile="$DEST_DIR/profiles/$name"
    mkdir -p "$dest_profile"
    for src in "$src_profile"*; do
        fname="$(basename "$src")"
        if [[ -d "$src" ]]; then
            cp -r "$src" "$dest_profile/"
        elif [[ "$fname" == *.template.* ]]; then
            dest_name="${fname/.template./.}"
            sed "s|{{PROFILE_DIR}}|$dest_profile|g" "$src" > "$dest_profile/$dest_name"
        else
            cp "$src" "$dest_profile/$fname"
        fi
    done
    for hook in "$dest_profile/hooks/"*.sh; do
        chmod +x "$hook"
    done
done

move_aside "$CLAUDE_LINK"
ln -s "$DEST_DIR/profiles/default" "$CLAUDE_LINK"

cat <<MSG

Installed to $DEST_DIR
Linked $CLAUDE_LINK -> $DEST_DIR/profiles/default

If not already present, add to your shell rc:
  [ -f "$DEST_DIR/claude-aliases.sh" ] && source "$DEST_DIR/claude-aliases.sh"
MSG
