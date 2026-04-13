#!/usr/bin/env bash
# Install claude-config into ~/.config/claude-config and ~/.claude.
#
# The installer refuses to run if any destination node already exists.
# There is no --force flag: re-installation requires manual cleanup
# first. This friction prevents the installer from ever clobbering
# Claude Code's runtime state (credentials, sessions, history) that
# lives alongside the profile in ~/.claude.
#
# {{PROFILE_DIR}} is substituted to $HOME/.claude — the canonical
# location of the default profile — not the convenience symlink at
# $DEST_DIR/profiles/default.
set -euo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/claude-config"
CLAUDE_DIR="$HOME/.claude"

display_path() { printf '%s' "${1/#$HOME/\~}"; }

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<USAGE
Usage: ./install.sh

Copies claude-config into:
  $(display_path "$DEST_DIR")/    (aliases, policies, profile symlink)
  $(display_path "$CLAUDE_DIR")/              (default profile — real directory)

The installer refuses to run if any destination already exists,
including $(display_path "$CLAUDE_DIR"), $(display_path "$DEST_DIR/claude-aliases.sh"),
any $(display_path "$DEST_DIR/policies")/*.json, or $(display_path "$DEST_DIR/profiles/default").

There is no --force. If re-installing, remove these manually first.
If any destination holds Claude Code runtime state (credentials,
sessions, history), move it somewhere safe before removal —
the installer will not do it for you.
USAGE
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Collect conflicts up-front; exit before writing anything.

conflicts=()
check_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        conflicts+=("$path")
    fi
}

check_path "$CLAUDE_DIR"
check_path "$DEST_DIR/claude-aliases.sh"
check_path "$DEST_DIR/profiles/default"
check_path "$DEST_DIR/scripts"

for src in "$REPO_DIR/policies/"*; do
    fname="$(basename "$src")"
    if [[ "$fname" == *.template.* ]]; then
        check_path "$DEST_DIR/policies/${fname/.template./.}"
    else
        check_path "$DEST_DIR/policies/$fname"
    fi
done

if [[ ${#conflicts[@]} -gt 0 ]]; then
    {
        echo "Installer refuses to run: one or more destinations already exist."
        echo
        echo "Remove these manually before re-installing:"
        for p in "${conflicts[@]}"; do
            echo "  $(display_path "$p")"
        done
        echo
        echo "If any contain Claude Code runtime state (credentials, history,"
        echo "sessions, etc.), move that state somewhere safe first — the"
        echo "installer will not preserve it for you."
    } >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Install.

mkdir -p "$DEST_DIR/policies" "$DEST_DIR/profiles" "$DEST_DIR/scripts" "$CLAUDE_DIR"

cp "$REPO_DIR/claude-aliases.sh" "$DEST_DIR/claude-aliases.sh"

# Management scripts the user can invoke later (e.g., after installing
# a tool that creates new credential paths they want denied).
for src in "$REPO_DIR/scripts/"*; do
    cp "$src" "$DEST_DIR/scripts/"
done
chmod +x "$DEST_DIR/scripts/"*.py 2>/dev/null || true
chmod +x "$DEST_DIR/scripts/"*.sh 2>/dev/null || true

for src in "$REPO_DIR/policies/"*; do
    fname="$(basename "$src")"
    if [[ "$fname" == *.template.* ]]; then
        dest_name="${fname/.template./.}"
        sed "s|{{HOME}}|$HOME|g" "$src" > "$DEST_DIR/policies/$dest_name"
    else
        cp "$src" "$DEST_DIR/policies/$fname"
    fi
done

# Default profile installs directly into ~/.claude. {{PROFILE_DIR}}
# substitutes to $CLAUDE_DIR — the canonical path — so settings.json
# hook references never require resolving through the symlink.
src_profile="$REPO_DIR/profiles/default"
for src in "$src_profile"/*; do
    fname="$(basename "$src")"
    if [[ -d "$src" ]]; then
        cp -r "$src" "$CLAUDE_DIR/"
    elif [[ "$fname" == *.template.* ]]; then
        dest_name="${fname/.template./.}"
        sed -e "s|{{PROFILE_DIR}}|$CLAUDE_DIR|g" -e "s|{{HOME}}|$HOME|g" "$src" > "$CLAUDE_DIR/$dest_name"
    else
        cp "$src" "$CLAUDE_DIR/$fname"
    fi
done

for hook in "$CLAUDE_DIR/hooks/"*.sh; do
    chmod +x "$hook"
done

# Filter sandbox.filesystem.denyRead to paths that currently exist.
# Bubblewrap requires each tmpfs-mount target to exist; a missing entry
# causes sandbox init to fail closed for every subprocess. See
# scripts/filter-sandbox-denies.py for details.
python3 "$DEST_DIR/scripts/filter-sandbox-denies.py" "$CLAUDE_DIR/settings.json"

# Convenience symlink: lets users and docs reference the default profile
# at the same path as other (hypothetical) profiles under profiles/.
ln -s "$CLAUDE_DIR" "$DEST_DIR/profiles/default"

# -----------------------------------------------------------------------------
DEST_DISPLAY="$(display_path "$DEST_DIR")"
CLAUDE_DISPLAY="$(display_path "$CLAUDE_DIR")"

cat <<MSG

Installed:
  $DEST_DISPLAY/
  $CLAUDE_DISPLAY/

The default profile lives at $CLAUDE_DISPLAY. A convenience symlink
at $DEST_DISPLAY/profiles/default points to it.

If not already sourcing from your shell rc, add:
  [ -f $DEST_DISPLAY/claude-aliases.sh ] && source $DEST_DISPLAY/claude-aliases.sh
MSG
