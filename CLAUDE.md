# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo holds Vigil, my personal default-deny Claude Code configuration, also intended for deployment to friends' machines. ./install.sh copies the default profile directly into ~/.claude/ (a real directory) and installs the shell wrappers, policies, and a convenience symlink under ~/.config/vigil/. Edits here only take effect after re-running the installer — the copy is a deliberate firewall between repo state and live session behavior. Forward direction: the Dashboard codebase (~/code/dashboard/) will move into this repo as a long-lived v2 branch (GENERALIZATION.md "2026-05-13 calibration"; BACKLOG.md for the discrete next-session items); current repo contents are unchanged and will become the Claude Code adapter under the v2 umbrella.

Repo layout:

- `profiles/<name>/` — per-profile bundle: `settings.json`, `settings.local.template.json`, `CLAUDE.md`, `agents/`. The default profile is strict-by-construction and ships its `CLAUDE.md` plus `agents/` packaged in `default.zip` for installer extraction.
- `policies/<name>.json` — permission overlays invoked per session via `claude --settings ~/.config/vigil/policies/<name>.json`. Current set: `strict`, `dev`, `yolo`.
- `scripts/` — Python implementations and helpers. `vigil-hook` is the single dispatcher invoked by every Claude Code hook (sudo-installed to `/usr/local/bin/` at install time so a profile-confined attacker cannot replace it); the dispatcher inlines the validate-* and log-tool-use logic. Other load-bearing scripts include `filter-sandbox-denies.py` (deny-list source of truth), `prune-logs.py` (delegated to by `vigil-hook prune-logs`), `run-pyszz.sh`, and `join-sessions.py`. Additional helper scripts (`vigil-install-review`, `vigil-review.py`, `summarize-sessions.py`, `vigil-sessions.py`, `strip-ansi.py`) live alongside.
- `vigil-aliases.sh` — sourced from `~/.bashrc` (from the installed copy at `~/.config/vigil/vigil-aliases.sh`); wraps the `claude` CLI with `script(1)` and exposes `vigil`, `vigil-dev`, `vigil-strict`, `vigil-yolo`, and `vigil-log*` entry points. Each session writes `~/vigil-logs/session-<timestamp>-<repo>-<branch>.txt` (ANSI-stripped transcript with a `# vigil-policy` header) and a companion `.json` sidecar (schema documented in `ANALYTICS.md`). The raw `script(1)` `.log` is discarded after successful stripping.
- `install.sh` — copy-based installer; refuses to run if any Vigil-owned destination already exists. Checks specific files/dirs within `~/.claude/` rather than the directory itself, so Claude Code runtime state there does not block reinstallation.

## Architecture

Two layers of configuration, merged by the Claude Code harness at session start:

1. **Profile** (`~/.claude/settings.json` and `~/.claude/settings.local.json`) — sandbox mode, the baseline `deny` list, and hooks wiring. Default profile is plan-mode with a hard `deny` list covering `rm`, `sudo`, non-read-only `git`, network fetchers (`curl`, `wget`), SSH-family tools (`ssh`, `scp`, `rsync`, etc.), language runtimes (`node`, `python`, `python3`, `npx`), a few risky tools (`npm publish`, `docker`, `kubectl`), and credential paths (`~/.ssh/`, `~/.aws/`, etc.). `~/.claude/` is a real directory shared with Claude Code's runtime state (credentials, sessions, history). A convenience symlink at `~/.config/vigil/profiles/default` points to `~/.claude/`.
2. **Policy** (optional, via `claude --settings .../policies/<name>.json`) — permissions overlay. `strict` matches the profile baseline; `dev` enables `acceptEdits` with an allow list for routine dev commands and ask-gates for risky ones; `yolo` bypasses confirmations except for `rm` and `sudo`. Hooks from the profile persist across policy overrides.

A non-default profile is selected by setting `CLAUDE_CONFIG_DIR` for the session; the default (no env var) reads from `~/.claude`, which is the default profile.

Hooks are dispatched through a single `vigil-hook` Python binary (sudo-installed at `/usr/local/bin/vigil-hook`). Subcommands wired in the default profile:

- `SessionStart` / `SessionEnd` → `vigil-hook prune-worktrees`
- `SessionStart` → `vigil-hook prune-logs` (retention for `~/vigil-logs/`; defaults 180d age, 2G cap; delegates to `~/.config/vigil/scripts/prune-logs.py`)
- `SessionStart` → `vigil-hook policy-banner` (prints active policy and session ID to stderr)
- `PreToolUse` / `PostToolUse` → `vigil-hook log-tool-use` (appends JSONL record per call to `~/vigil-logs/tools-<harness_session_id>.jsonl`; each record carries both `harness_session_id` and `vigil_session_id` as content fields)
- `SessionStart` → `vigil-hook session-start` (bridges `~/.config/vigil/sessions/wrapper-<pid>.json` to `<harness_session_id>.json` and drops `~/vigil-logs/.bridge-<vigil_session_id>` for the wrapper's post-exec sidecar lookup)
- `SessionEnd` → `vigil-hook session-end` (removes the bridged `<harness_session_id>.json`)
- `PreToolUse` → `vigil-hook validate-memory-write` (blocks `Write`/`Edit`/`MultiEdit` targeting another project's `memory/` directory)
- `PreToolUse` → `vigil-hook validate-settings-write` (blocks `Write`/`Edit`/`MultiEdit` targeting `~/.claude/settings.json`, `~/.claude/settings.local.json`, and `~/.claude/keybindings.json`)

Hook commands in `settings.json` are bare `vigil-hook <subcommand>` invocations resolved via PATH. The installer no longer substitutes `{{PROFILE_DIR}}` for hook paths. `settings.local.template.json` is currently a stub (empty `permissions.deny` array) — host-local credential and dotfile coverage now lives entirely at the sandbox layer via `MASTER_DENY_*` in `scripts/filter-sandbox-denies.py`.

All hooks read session context from `~/.config/vigil/sessions/<harness_session_id>.json`. The wrapper writes a `wrapper-<pid>.json` variant at launch with a `vigil_session_id`, `log_dir`, `policy`, `launched_at`, `repo`, and `branch`; the SessionStart hook renames it to `<harness_session_id>.json` once the harness has assigned its UUID, joining the wrapper PID via `VIGIL_WRAPPER_PID` read from `/proc/<ppid>/environ` (the harness strips shell-exported env vars before invoking hook subprocesses, but not before invoking claude — see [`COMPATIBILITY.md`](COMPATIBILITY.md) for the Linux-only constraint). Session-level transcripts are captured via `script(1)` from the shell wrappers in `vigil-aliases.sh`.

The sandbox `denyRead` and `denyWrite` lists are *not* defined in `settings.json`. Their authoritative source is the master tuples (`MASTER_DENY_READ`, `MASTER_DENY_WRITE`) at the top of `scripts/filter-sandbox-denies.py`. The installer invokes that script after writing `settings.json`; the script overwrites the two arrays with the master entries that currently pass bubblewrap's mount-target type check. To change the desired deny set, edit the Python source — not the JSON files. The script is safe to re-run standalone (e.g., after installing a new CLI that creates `~/.aws/`) to refresh the lists without a full reinstall.

## Worktree pruning invariants

`vigil-hook prune-worktrees` runs at session start and end against `<repo>/.claude/worktrees/`. Its invariants are load-bearing — preserve them when editing the dispatcher:

1. Never removes a worktree directory with uncommitted changes.
2. Never prunes git metadata for a dirty worktree (verified with a post-prune safety check that warns on violation).
3. Only deletes `claude/*` branches that are fully merged into `main` (uses `git branch -d`, not `-D`); unmerged branches are reported, not deleted.

Worktree matching is by basename, not full path, to survive Windows/MSYS2 path-format mismatches (`C:/...` vs `/c/...`).

## Load-bearing paths

Paths whose contents are part of Vigil's security posture. Do not modify them from the coding agent:

1. `.git/review-gate/` in any repo where `vigil-install-review` has run. The scripts inside and `.git/review-gate/.manifest` are checked by the pre-push hook's SHA-256 tamper self-check; any drift aborts the push.
2. `MASTER_DENY_WRITE` in `scripts/filter-sandbox-denies.py`, specifically the `{{CWD}}/.git/config` and `{{CWD}}/.git/hooks/` entries (resolved per-session against the repo root) plus the literal `~/.gitconfig`. These are the enforcement layer that blocks subprocess tampering with git configuration; removing or narrowing them breaks the commit-review gate's security claim.

## Editing conventions

- Permission lists in the JSON files are order-insensitive but duplicates between `allow`/`deny` resolve to `deny` — add to `deny` rather than removing from `allow` when tightening.
- Use the colon matcher form (`Bash(rm:*)`) for deny/allow patterns; the space form (`Bash(rm *)`) is non-standard.
- Edits to this repo do not take effect until `./install.sh` copies the changes into `~/.config/vigil/`. **Do not run `install.sh` yourself — that is the developer's job.** Make the edits, commit them, and leave installation to the developer.
- GitHub Actions in .github/workflows/ must be pinned by full SHA with a trailing # vX.Y.Z comment (e.g., actions/checkout@<sha> # v4.2.2). Local actions (uses: ./...) are exempt. Enforced by tests/check-action-pins.sh (auto-discovered by tests/run.sh).

## Collaboration rules

Global collaboration rules live in `~/.claude/CLAUDE.md` — apply them as written. Project-specific extensions below.

### Commit discipline — extension

Edits here are live changes to Claude's behavior across every consuming project. Clean isolated commits matter for bisecting misbehavior later.

### Commit scopes

This project's scopes: `hooks`, `policies`, `profiles`, `aliases`, `config`.

### Project agents

| Agent | File | When to use |
|---|---|---|
| `architect` | `.claude/agents/architect.md` | Non-trivial changes; preserves load-bearing invariants and installer contracts. |
| `code-reviewer` | `.claude/agents/code-reviewer.md` | Before every commit; emphasizes shell, JSON settings, and installer concerns. |
