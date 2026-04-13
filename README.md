# Claude Configuration

Personal Claude Code configuration, designed to also be deployed to other machines.

## Installation

Clone this repo anywhere, then run the installer:

```
git clone <this-repo> ~/code/claude-config
cd ~/code/claude-config
./install.sh
```

The installer copies the repo into `~/.config/claude-config/` and symlinks `~/.claude` to the default profile. Any existing `~/.config/claude-config/` or `~/.claude` is moved to a `.bak-<timestamp>` path; pass `--force` to overwrite instead.

Add to your `~/.bashrc` (or equivalent) so the session wrapper exports `CLAUDE_SESSION_ID` / `CLAUDE_LOG_DIR` and records each session under `~/claude-logs/`:

```
[ -f ~/.config/claude-config/claude-aliases.sh ] && source ~/.config/claude-config/claude-aliases.sh
```

## Updating

Repo edits do not change session behavior until the installer runs:

```
cd ~/code/claude-config
git pull            # or make local edits
./install.sh
```

## Profiles and policies

- The **default profile** (`profiles/default/`) is plan-mode with a hard deny list — safe by construction. It is symlinked as `~/.claude` by the installer and applies to any session launched without an explicit profile.
- **Policies** (`policies/*.json`) are permission overlays selected per session via `--settings`:

  ```
  claude --settings ~/.config/claude-config/policies/dev.json     # uninterrupted dev work, safety gates on risky ops
  claude --settings ~/.config/claude-config/policies/strict.json  # same as the default profile baseline
  claude --settings ~/.config/claude-config/policies/yolo.json    # bypass confirmations (retains rm and sudo denies)
  ```

- Additional profiles may live alongside `default/` and are selected by setting `CLAUDE_CONFIG_DIR` for the session.
