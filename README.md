# Claude Configuration

Personal Claude Code configuration, designed to also be deployed to other machines.

## Who this is for

**Sweet spot.** A mid-to-senior developer comfortable in a Linux/WSL2/macOS terminal, security-aware enough to want a baseline for autonomous agents but uninterested in designing one from scratch. The split between profile (identity, hooks, sandbox) and policy (posture: `strict` / `dev` / `yolo`) should click quickly — it mirrors AWS profiles, browser profiles, and IAM policies.

**Above the sweet spot.** Senior developers with their own opinionated Claude config. Welcome to fork, steal ideas, or politely ignore.

**Outside current scope.** Users without terminal proficiency; native Windows users without WSL (installer is bash-only); anyone unfamiliar with `~/.claude/settings.json` — whether they reach Claude through the desktop app, an IDE extension, or the CLI is irrelevant, but the tool's value depends on knowing *what configuration is* and being willing to manage it.

For the longer framing — including common misconceptions, the self-use vs. friend-deploy split, and a practical "is this for me?" test — see [`AUDIENCE.md`](AUDIENCE.md).

## Installation

Clone this repo anywhere, then run the installer:

```
git clone <this-repo> ~/code/claude-config
cd ~/code/claude-config
./install.sh
```

The installer copies into two locations:

- `~/.claude/` — the default profile (real directory; shared with Claude Code's runtime state).
- `~/.config/claude-config/` — the shell alias, the policy files, and a convenience symlink to the default profile.

The installer **refuses to run if any destination already exists**, including a prior `~/.claude`, any existing alias or policy file, or a prior `profiles/default`. There is no `--force` flag. Re-installation requires manual cleanup first — this is intentional, because `~/.claude` may contain Claude Code runtime state (credentials, sessions, history) that the installer will not preserve for you.

Add to your `~/.bashrc` (or equivalent) so the `claude`, `claude-dev`, `claude-strict`, `claude-yolo`, and `claude-log` wrapper functions are defined and sessions are recorded under `~/claude-logs/`:

```
[ -f ~/.config/claude-config/claude-aliases.sh ] && source ~/.config/claude-config/claude-aliases.sh
```

## Updating

Repo edits do not change session behavior until the installer runs. Because the installer refuses to overwrite existing files, an update involves moving runtime state out of the way first:

```
cd ~/code/claude-config
git pull            # or make local edits

# Preserve Claude Code runtime state, then remove the old install.
mkdir -p /tmp/claude-state
mv ~/.claude/{.credentials.json,history.jsonl,backups,cache,file-history,ide,projects,session-env,sessions,shell-snapshots} /tmp/claude-state/ 2>/dev/null || true
rm -rf ~/.claude ~/.config/claude-config

./install.sh

# Restore runtime state.
mv /tmp/claude-state/* ~/.claude/ 2>/dev/null || true
rmdir /tmp/claude-state
```

The clumsiness is deliberate. A friendlier workflow belongs in a future `update.sh` that knows which files are "ours" versus Claude Code's; designing that safely is tracked as a Stage 1 gap.

## Uninstalling

```
cd ~/code/claude-config
./uninstall.sh        # interactive; pass -y to skip the prompt
```

The script removes only files placed by `install.sh` and leaves Claude Code runtime state in `~/.claude/` (credentials, sessions, history, projects, etc.) intact. User-added files under `~/.claude/agents/` and `~/.claude/hooks/` are also preserved — only entries that originated from this repo are removed.

## Profiles and policies

- The **default profile** is safe by construction — plan mode, a hard deny list, hooks, and sandbox rules. It lives at `~/.claude/` and applies to any Claude Code session.
- **Policies** are permission overlays selected per session via `--settings`. Shell wrappers in `claude-aliases.sh` save the typing:

  | Wrapper | Equivalent | Notes |
  |---|---|---|
  | `claude` | bare `claude` | default profile baseline; plan mode; session logging via `script(1)` |
  | `claude-dev` | `claude --settings .../policies/dev.json` | cd to git root, uninterrupted dev work, safety gates on risky ops |
  | `claude-strict` | `claude --settings .../policies/strict.json` | same as the default profile baseline, made explicit |
  | `claude-yolo` | `claude --settings .../policies/yolo.json` | bypasses confirmations; retains `rm` and `sudo` denies |

- `claude-log` opens a session transcript in `$PAGER`. With no arguments it shows the most recent session; `claude-log -1` shows the previous one (`-2` the one before that, etc.); `claude-log 20260413` (or `2026-04-13`) opens the most recent transcript matching that date prefix.

## Further reading

- [`DESIGN.md`](DESIGN.md) — design choices and rationale.
- [`THREAT_MODEL.md`](THREAT_MODEL.md) — what this tool protects against, what it does not.
- [`COMPATIBILITY.md`](COMPATIBILITY.md) — per-platform support status.
- [`AUDIENCE.md`](AUDIENCE.md) — who the tool is and is not for.
- [`LIFECYCLE.md`](LIFECYCLE.md) — project stage framework.
