#!/usr/bin/env bash
# Install Vigil into ~/.config/vigil, ~/.claude, and /usr/local/bin/.
#
# The installer refuses to run if any user-owned destination already exists.
# There is no --force flag: re-installation requires manual cleanup first.
# This friction prevents the installer from ever clobbering Claude Code's
# runtime state (credentials, sessions, history) that lives alongside the
# profile in ~/.claude.
#
# vigil-hook (the dispatcher invoked by every PreToolUse/PostToolUse/
# SessionStart/SessionEnd hook in settings.json) is installed to
# /usr/local/bin/ via sudo so an attacker confined to the user's profile
# can't easily replace it. The sudo prompt fires once during install.
#
# {{HOME}} is substituted in policy and template files. {{PROFILE_DIR}} is
# substituted in profile templates to the live profile directory (e.g.
# $HOME/.claude for default).
set -euo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/vigil"
CLAUDE_DIR="$HOME/.claude"

display_path() { printf '%s' "${1/#$HOME/\~}"; }

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<USAGE
Usage: ./install.sh

Copies Vigil into:
  $(display_path "$DEST_DIR")/      (aliases, policies, scripts)
  $(display_path "$CLAUDE_DIR")/                (default profile — real directory)
  /usr/local/bin/vigil-hook         (dispatcher; sudo install for tamper-resistance)

The installer refuses to run if any user-owned Vigil destination already exists.
Checked paths inside $(display_path "$CLAUDE_DIR")/:
  settings.json  settings.local.json  settings.local.template.json
  CLAUDE.md  hooks/  agents/  default.zip
Checked paths inside $(display_path "$DEST_DIR")/:
  vigil-aliases.sh  doctor.sh  scripts/  pyszz.yml
  profiles/default  profiles/permissive  policies/*.json

The /usr/local/bin/vigil-hook destination is reinstalled in place via
\`sudo install\`; existing copies are overwritten without prompting.
Set VIGIL_HOOK_INSTALL_DIR=<dir> together with VIGIL_UNSAFE_SKIP_SUDO=1
to redirect this step to a writable directory and skip sudo (intended
for tests and dev installs only — this bypasses tamper-resistance for
the dispatcher binary).

There is no --force. If re-installing, remove user-owned conflicts manually first.
Claude Code runtime state in $(display_path "$CLAUDE_DIR")/ (projects/, sessions/,
history.jsonl, etc.) is not checked and will not be touched.
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

check_path "$CLAUDE_DIR/settings.json"
check_path "$CLAUDE_DIR/settings.local.json"
check_path "$CLAUDE_DIR/settings.local.template.json"
check_path "$CLAUDE_DIR/CLAUDE.md"
check_path "$CLAUDE_DIR/hooks"
check_path "$CLAUDE_DIR/agents"
check_path "$CLAUDE_DIR/default.zip"
check_path "$DEST_DIR/vigil-aliases.sh"
check_path "$DEST_DIR/doctor.sh"
check_path "$DEST_DIR/pyszz.yml"
check_path "$DEST_DIR/profiles/default"
check_path "$DEST_DIR/profiles/permissive"
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

cp "$REPO_DIR/vigil-aliases.sh" "$DEST_DIR/vigil-aliases.sh"
cp "$REPO_DIR/doctor.sh" "$DEST_DIR/doctor.sh"
chmod +x "$DEST_DIR/doctor.sh"
cp "$REPO_DIR/pyszz.yml" "$DEST_DIR/pyszz.yml"

# Install vigil-hook to a root-owned system path. Hooks in settings.json
# invoke this binary by bare name; PATH lookup resolves it. Placing it
# outside ~/ raises the bar for an attacker who has compromised the user's
# profile but lacks root — they can't replace the dispatcher to neutralize
# validate-memory-write or validate-settings-write.
#
# The override path is gated by two env vars together — VIGIL_HOOK_INSTALL_DIR
# names a destination and VIGIL_UNSAFE_SKIP_SUDO=1 confirms the operator
# intends to bypass root-ownership tamper-resistance. A bare path env var
# inherited from another context (CI, a leaked export) fails closed without
# the confirmation flag, so accidental degradation of a real install
# requires two unrelated mistakes rather than one.
HOOK_INSTALL_DIR="/usr/local/bin"
hook_override=0
if [[ -n "${VIGIL_HOOK_INSTALL_DIR-}" ]]; then
    if [[ "${VIGIL_UNSAFE_SKIP_SUDO-}" != "1" ]]; then
        printf 'install.sh: VIGIL_HOOK_INSTALL_DIR is set but VIGIL_UNSAFE_SKIP_SUDO!=1.\n' >&2
        printf '  The override path is honored only with VIGIL_UNSAFE_SKIP_SUDO=1 to confirm\n' >&2
        printf '  intent to bypass root-ownership tamper-resistance for the dispatcher.\n' >&2
        exit 1
    fi
    HOOK_INSTALL_DIR="$VIGIL_HOOK_INSTALL_DIR"
    hook_override=1
fi

if [[ $hook_override -eq 1 ]]; then
    printf 'install.sh: WARNING — installing vigil-hook to %s/ without sudo;\n' "$HOOK_INSTALL_DIR" >&2
    printf '  this bypasses root-ownership tamper-resistance for the dispatcher.\n' >&2
    mkdir -p "$HOOK_INSTALL_DIR"
    install -m 0755 \
        "$REPO_DIR/scripts/vigil-hook" "$HOOK_INSTALL_DIR/vigil-hook"
else
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'install.sh: sudo not found; cannot install %s/vigil-hook\n' "$HOOK_INSTALL_DIR" >&2
        exit 1
    fi
    printf 'Installing vigil-hook to %s/ (sudo prompt may follow)...\n' "$HOOK_INSTALL_DIR"
    sudo install -m 0755 -o root -g root \
        "$REPO_DIR/scripts/vigil-hook" "$HOOK_INSTALL_DIR/vigil-hook"
fi

# Management scripts the user can invoke later (e.g., after installing
# a tool that creates new credential paths they want denied). The
# `hooks/` subdirectory ships git-hook templates consumed by Phase D's
# vigil-install-review; they are not auto-installed into any repo.
while IFS= read -r -d '' f; do
    rel="${f#"$REPO_DIR/scripts/"}"
    mkdir -p "$(dirname "$DEST_DIR/scripts/$rel")"
    cp "$f" "$DEST_DIR/scripts/$rel"
done < <(find "$REPO_DIR/scripts" -type f -print0)
chmod +x "$DEST_DIR/scripts/"*.py 2>/dev/null || true
chmod +x "$DEST_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$DEST_DIR/scripts/hooks/"* 2>/dev/null || true
# Extension-less binaries: vigil-install-review is operator-invoked,
# vigil-hook is the per-user backup of the dispatcher (the live one runs
# from /usr/local/bin/). Neither matches the *.py / *.sh globs above.
chmod +x "$DEST_DIR/scripts/vigil-install-review" 2>/dev/null || true
chmod +x "$DEST_DIR/scripts/vigil-hook" 2>/dev/null || true

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
# Templates are kept alongside their generated output so that
# vigil set-default can regenerate settings.local.json after a swap.
src_profile="$REPO_DIR/profiles/default"
for src in "$src_profile"/*; do
    fname="$(basename "$src")"
    if [[ -d "$src" ]]; then
        cp -r "$src" "$CLAUDE_DIR/"
    elif [[ "$fname" == *.template.* ]]; then
        dest_name="${fname/.template./.}"
        sed -e "s|{{PROFILE_DIR}}|$CLAUDE_DIR|g" -e "s|{{HOME}}|$HOME|g" "$src" > "$CLAUDE_DIR/$dest_name"
        cp "$src" "$CLAUDE_DIR/$fname"
    else
        cp "$src" "$CLAUDE_DIR/$fname"
    fi
done

# Populate sandbox.filesystem.denyRead and denyWrite from the master
# lists embedded in scripts/filter-sandbox-denies.py, intersected with
# paths that currently exist on this host. Bubblewrap requires each
# tmpfs-mount target to exist; a missing entry causes sandbox init to
# fail closed for every subprocess. The script can be re-run anytime
# to pick up newly created or removed paths. See the script header
# for details.
python3 "$DEST_DIR/scripts/filter-sandbox-denies.py" "$CLAUDE_DIR/settings.json"

# Convenience symlink: lets users and docs reference the default profile
# at the same path as other profiles under profiles/.
ln -s "$CLAUDE_DIR" "$DEST_DIR/profiles/default"

# Permissive profile installs as a real directory under profiles/permissive.
# {{PROFILE_DIR}} for this profile resolves to $DEST_DIR/profiles/permissive.
PERMISSIVE_DEST="$DEST_DIR/profiles/permissive"
mkdir -p "$PERMISSIVE_DEST"
src_perm="$REPO_DIR/profiles/permissive"
for src in "$src_perm"/*; do
    fname="$(basename "$src")"
    if [[ -d "$src" ]]; then
        cp -r "$src" "$PERMISSIVE_DEST/"
    elif [[ "$fname" == *.template.* ]]; then
        dest_name="${fname/.template./.}"
        sed -e "s|{{PROFILE_DIR}}|$PERMISSIVE_DEST|g" -e "s|{{HOME}}|$HOME|g" \
            "$src" > "$PERMISSIVE_DEST/$dest_name"
        cp "$src" "$PERMISSIVE_DEST/$fname"
    else
        cp "$src" "$PERMISSIVE_DEST/$fname"
    fi
done
# settings.json was produced by the template-copy loop above; this call
# populates its sandbox.filesystem.denyRead and denyWrite arrays.
python3 "$DEST_DIR/scripts/filter-sandbox-denies.py" "$PERMISSIVE_DEST/settings.json"

# Record the active profile. Skipped if file already exists so a re-run
# of the installer (after manual cleanup) does not reset a user's choice.
if [[ ! -f "$DEST_DIR/active-profile" ]]; then
    printf 'default\n' > "$DEST_DIR/active-profile"
fi

# -----------------------------------------------------------------------------
DEST_DISPLAY="$(display_path "$DEST_DIR")"
CLAUDE_DISPLAY="$(display_path "$CLAUDE_DIR")"

cat <<MSG

Installed:
  $DEST_DISPLAY/
  $CLAUDE_DISPLAY/

Profiles:
  default   — $CLAUDE_DISPLAY/  (active; strict deny list)
  permissive — $DEST_DISPLAY/profiles/permissive/  (lighter floor for vigil-dev / vigil-yolo)

Switch profiles with:
  vigil set-default permissive
  vigil set-default default

If not already sourcing from your shell rc, add:
  [ -f $DEST_DISPLAY/vigil-aliases.sh ] && source $DEST_DISPLAY/vigil-aliases.sh

To verify the install at any time:
  $DEST_DISPLAY/doctor.sh

Rebrand note: the wrapped-invocation entry point is now 'vigil' (was 'claude').
The 'claude' command now unshadows to the real Claude Code binary. Session logs
land in ~/vigil-logs/ (was ~/claude-logs/); env vars are VIGIL_SESSION_ID and
VIGIL_LOG_DIR (were CLAUDE_*).
MSG

# Nudge returning users to migrate their old session logs; the installer
# does not move them automatically to avoid touching data it did not write.
if [[ -d "$HOME/claude-logs" && ! -e "$HOME/vigil-logs" ]]; then
    printf '\nLegacy ~/claude-logs/ detected. Move it to ~/vigil-logs/ to keep transcript history:\n'
    printf '  mv ~/claude-logs ~/vigil-logs\n'
fi

# Legacy install root is no longer read by Vigil — anything the operator
# customized there (policy edits, user-added scripts) is silently ignored
# until moved. Flag it so stale state isn't mistaken for active config.
if [[ -d "$HOME/.config/claude-config" ]]; then
    printf '\nLegacy ~/.config/claude-config/ detected. Vigil no longer reads from that path;\n'
    printf 'any edits or user-added files there are being ignored. Move anything worth keeping\n'
    printf 'into ~/.config/vigil/ and remove the old directory.\n'
fi
