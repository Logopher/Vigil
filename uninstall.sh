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
  $(display_path "$DEST_DIR/vigil-aliases.sh")
  $(display_path "$DEST_DIR/doctor.sh")
  $(display_path "$DEST_DIR/pyszz.yml")
  $(display_path "$DEST_DIR/policies/")*.json
  $(display_path "$DEST_DIR/scripts/")*
  $(display_path "$DEST_DIR/profiles/default") (symlink)
  $(display_path "$CLAUDE_DIR/CLAUDE.md")
  $(display_path "$CLAUDE_DIR/settings.json")
  $(display_path "$CLAUDE_DIR/agents/")<files installed by this repo>
  $(display_path "$CLAUDE_DIR/hooks/")<files installed by this repo>
  /usr/local/bin/vigil-hook  (requires sudo)

Claude Code runtime state in $(display_path "$CLAUDE_DIR") (credentials,
sessions, history, projects, etc.) is preserved. Files under agents/
and hooks/ that did not come from this repo are also preserved.
Empty parent directories are removed; non-empty ones are left alone.

If install.sh ran with VIGIL_HOOK_INSTALL_DIR=<dir> and
VIGIL_UNSAFE_SKIP_SUDO=1, pass the same env vars to uninstall to
remove the dispatcher from <dir>/vigil-hook without sudo.

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
# Resolve the dispatcher install dir. Mirrors install.sh's HOOK_INSTALL_DIR
# block: the override path is gated by VIGIL_HOOK_INSTALL_DIR +
# VIGIL_UNSAFE_SKIP_SUDO together, so a stale VIGIL_HOOK_INSTALL_DIR
# inherited from another context can't silently redirect uninstall to a
# wrong directory and report "Nothing to remove" while the real
# dispatcher remains.
HOOK_INSTALL_DIR="/usr/local/bin"
hook_override=0
if [[ -n "${VIGIL_HOOK_INSTALL_DIR-}" ]]; then
    if [[ "${VIGIL_UNSAFE_SKIP_SUDO-}" != "1" ]]; then
        printf 'uninstall.sh: VIGIL_HOOK_INSTALL_DIR is set but VIGIL_UNSAFE_SKIP_SUDO!=1.\n' >&2
        printf '  The override path is honored only with VIGIL_UNSAFE_SKIP_SUDO=1 to confirm\n' >&2
        printf '  intent to bypass root-ownership tamper-resistance for the dispatcher.\n' >&2
        exit 1
    fi
    # Strip a trailing slash so the path-equality compare in the removal
    # loop and the display_path output agree on canonical form.
    HOOK_INSTALL_DIR="${VIGIL_HOOK_INSTALL_DIR%/}"
    hook_override=1
fi

# -----------------------------------------------------------------------------
# Build the to-remove list by mirroring install.sh's layout.

to_remove=()
add_if_exists() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        to_remove+=("$path")
    fi
}

add_if_exists "$DEST_DIR/vigil-aliases.sh"
add_if_exists "$DEST_DIR/doctor.sh"
add_if_exists "$DEST_DIR/pyszz.yml"
add_if_exists "$DEST_DIR/active-profile"

for src in "$REPO_DIR/policies/"*; do
    fname="$(basename "$src")"
    if [[ "$fname" == *.template.* ]]; then
        add_if_exists "$DEST_DIR/policies/${fname/.template./.}"
    else
        add_if_exists "$DEST_DIR/policies/$fname"
    fi
done

while IFS= read -r -d '' f; do
    rel="${f#"$REPO_DIR/scripts/"}"
    add_if_exists "$DEST_DIR/scripts/$rel"
done < <(find "$REPO_DIR/scripts" -type f -print0)

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
        add_if_exists "$CLAUDE_DIR/$fname"
    else
        add_if_exists "$CLAUDE_DIR/$fname"
    fi
done

# Permissive profile contents. Mirrors the default loop above but targets
# the bundle directory rather than $CLAUDE_DIR.
PERMISSIVE_DEST="$DEST_DIR/profiles/permissive"
for src in "$REPO_DIR/profiles/permissive/"*; do
    fname="$(basename "$src")"
    if [[ -d "$src" ]]; then
        while IFS= read -r -d '' f; do
            rel="${f#"$src"/}"
            add_if_exists "$PERMISSIVE_DEST/$fname/$rel"
        done < <(find "$src" -type f -print0)
    elif [[ "$fname" == *.template.* ]]; then
        add_if_exists "$PERMISSIVE_DEST/${fname/.template./.}"
        add_if_exists "$PERMISSIVE_DEST/$fname"
    else
        add_if_exists "$PERMISSIVE_DEST/$fname"
    fi
done

# Dispatcher at $HOOK_INSTALL_DIR. Removed unconditionally if present
# (no hash check) — a stale dispatcher left over from a previous Vigil
# install is precisely what uninstall should clear, and removing a
# foreign replacement is a defensive win rather than a regression.
hook_path="$HOOK_INSTALL_DIR/vigil-hook"
hook_needs_sudo=0
if [[ -e "$hook_path" ]]; then
    to_remove+=("$hook_path")
    if [[ $hook_override -eq 0 ]]; then
        hook_needs_sudo=1
    fi
fi

if [[ ${#to_remove[@]} -eq 0 ]]; then
    echo "Nothing to remove. Vigil does not appear to be installed." >&2
    exit 0
fi

# When the dispatcher requires sudo but sudo is missing, degrade gracefully:
# show the full removal plan first, then either skip the dispatcher in -y
# mode with a warning or ask for explicit confirmation in interactive mode.
# The previous behavior — exit 1 before printing the preview — left the user
# without information about what else would have been removed.
sudo_missing=0
if [[ $hook_needs_sudo -eq 1 ]] && ! command -v sudo >/dev/null 2>&1; then
    sudo_missing=1
fi

# -----------------------------------------------------------------------------
echo "Will remove:"
for p in "${to_remove[@]}"; do
    if [[ "$p" == "$hook_path" && $hook_needs_sudo -eq 1 ]]; then
        if [[ $sudo_missing -eq 1 ]]; then
            echo "  $(display_path "$p")  (sudo unavailable — will SKIP)"
        else
            echo "  $(display_path "$p")  (sudo)"
        fi
    else
        echo "  $(display_path "$p")"
    fi
done
echo
echo "Claude Code runtime state in $(display_path "$CLAUDE_DIR") (credentials,"
echo "sessions, history, projects, etc.) will be preserved."
echo

if [[ $assume_yes -eq 0 ]]; then
    if [[ $sudo_missing -eq 1 ]]; then
        read -r -p "Proceed (dispatcher will be skipped)? [y/N] " ans
    else
        read -r -p "Proceed? [y/N] " ans
    fi
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Aborted." >&2; exit 1 ;;
    esac
elif [[ $sudo_missing -eq 1 ]]; then
    printf 'uninstall.sh: WARNING — sudo not found; %s will be skipped.\n' "$hook_path" >&2
fi

for p in "${to_remove[@]}"; do
    if [[ "$p" == "$hook_path" && $hook_needs_sudo -eq 1 ]]; then
        if [[ $sudo_missing -eq 1 ]]; then
            continue
        fi
        sudo rm -f -- "$p"
    else
        rm -f -- "$p"
    fi
done

# Tidy up directories created by install.sh. rmdir refuses non-empty
# dirs, so user additions and runtime state are preserved automatically.
# Subdirs under profiles/default/ are derived from the repo so new ones
# (e.g., commands/) are picked up without editing this script.
empty_dirs=("$DEST_DIR/policies")
while IFS= read -r -d '' d; do
    rel="${d#"$REPO_DIR/scripts"}"
    empty_dirs+=("$DEST_DIR/scripts$rel")
done < <(find "$REPO_DIR/scripts" -mindepth 1 -depth -type d -print0)
empty_dirs+=("$DEST_DIR/scripts")
for src in "$REPO_DIR/profiles/permissive/"*; do
    [[ -d "$src" ]] && empty_dirs+=("$PERMISSIVE_DEST/$(basename "$src")")
done
empty_dirs+=("$PERMISSIVE_DEST" "$DEST_DIR/profiles")
for src in "$REPO_DIR/profiles/default/"*; do
    [[ -d "$src" ]] && empty_dirs+=("$CLAUDE_DIR/$(basename "$src")")
done
empty_dirs+=("$DEST_DIR" "$CLAUDE_DIR")
rmdir -- "${empty_dirs[@]}" 2>/dev/null || true

echo "Done."
