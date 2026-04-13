# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo holds the user's personal Claude Code configuration, also intended for deployment to friends' machines. `./install.sh` copies the contents into `~/.config/claude-config/` and symlinks `~/.claude` to the default profile. Edits here only take effect after re-running the installer — the copy is a deliberate firewall between repo state and live session behavior.

Repo layout:

- `profiles/<name>/` — per-profile bundle: `settings.template.json`, `CLAUDE.md`, `hooks/*.sh`. The default profile is strict-by-construction.
- `policies/<name>.json` — permission overlays invoked per session via `claude --settings ~/.config/claude-config/policies/<name>.json`. Current set: `strict`, `dev`, `yolo`.
- `claude-aliases.sh` — sourced from `~/.bashrc` (from the installed copy at `~/.config/claude-config/claude-aliases.sh`); wraps the `claude` CLI with `script(1)` to record each session under `~/claude-logs/session-<timestamp>.log`.
- `install.sh` — copy-based installer; moves any prior install to a `.bak-<timestamp>` path unless `--force`.

## Architecture

Two layers of configuration, merged by the Claude Code harness at session start:

1. **Profile** (`~/.claude/settings.json`, reached through the `~/.claude → profiles/default` symlink) — sandbox mode, the baseline `deny` list, and hooks wiring. Default profile is plan-mode with a hard `deny` list covering `rm`, `sudo`, non-read-only `git`, network fetchers (`curl`, `wget`), language runtimes (`node`, `python`, `python3`, `npx`), and a few risky tools (`npm publish`, `docker`, `kubectl`).
2. **Policy** (optional, via `claude --settings .../policies/<name>.json`) — permissions overlay. `strict` matches the profile baseline; `dev` enables `acceptEdits` with an allow list for routine dev commands and ask-gates for risky ones; `yolo` bypasses confirmations except for `rm` and `sudo`. Hooks from the profile persist across policy overrides.

A non-default profile is selected by setting `CLAUDE_CONFIG_DIR` for the session; the baseline `~/.claude` symlink to the default profile provides a safe default.

Hooks registered in the default profile:

- `SessionStart` / `SessionEnd` → `hooks/prune-worktrees.sh`
- `PreToolUse` → `hooks/log-tool-use.sh` (appends JSON payload to the session log)
- `PostToolUse` → `hooks/log-tool-result.sh`

Hook paths in the template use the `{{PROFILE_DIR}}` placeholder; the installer substitutes the installed profile directory when generating `settings.json`. The logging hooks rely on `CLAUDE_SESSION_ID` and `CLAUDE_LOG_DIR` exported by `claude-aliases.sh` — if Claude is launched without that wrapper sourced, the hooks write to an undefined path.

## `profiles/default/hooks/prune-worktrees.sh`

Runs at session start and end against `<repo>/.claude/worktrees/`. Its invariants are load-bearing — preserve them when editing:

1. Never removes a worktree directory with uncommitted changes.
2. Never prunes git metadata for a dirty worktree (verified with a post-prune safety check that warns on violation).
3. Only deletes `claude/*` branches that are fully merged into `main` (uses `git branch -d`, not `-D`); unmerged branches are reported, not deleted.

Worktree matching is by basename, not full path, to survive Windows/MSYS2 path-format mismatches (`C:/...` vs `/c/...`).

## Editing conventions

- Permission lists in the JSON files are order-insensitive but duplicates between `allow`/`deny` resolve to `deny` — add to `deny` rather than removing from `allow` when tightening.
- Use the colon matcher form (`Bash(rm:*)`) for deny/allow patterns; the space form (`Bash(rm *)`) is non-standard.
- Edits to this repo do not take effect until `./install.sh` copies the changes into `~/.config/claude-config/`. **Do not run `install.sh` yourself — that is the developer's job.** Make the edits, commit them, and leave installation to the developer.

## Collaboration rules

### Commit discipline

Each commit contains exactly one logical unit of work. Never bundle independent changes. Keep gate-passing fixes — changes made to resolve code-reviewer findings — in their own commit, separate from new feature code; bundling them obscures what the review actually caught.

Edits here are live changes to Claude's behavior across every consuming project. Clean isolated commits matter for bisecting misbehavior later.

When a plan has multiple steps, evaluate file overlap before starting:

- Steps that touch the same files must run in series. Commit step N before starting step N+1.
- Steps that touch entirely different files may run in parallel using isolated worktrees, each producing its own commit on its own branch. Only use worktree agents when each task is substantial enough to justify the coordination overhead; for trivial single-file edits, sequential execution in the main context is faster.

Commit as soon as a unit is complete and its gates pass. Do not defer multiple commits to the same working state.

Before committing, check that no new TODO, FIXME, or placeholder comments were introduced by the change.

### Commit message format

Angular-style conventional commits.

- Format: `<type>(<scope>): <summary>`
- One scope per commit; split if spans multiple.
- Types: `feat`, `fix`, `refactor`, `style`, `docs`, `test`, `chore`.
- Scopes: `hooks`, `policies`, `profiles`, `aliases`, `config`.

### Decision escalation

Stop and ask before writing code if the plan has an open question, multiple reasonable approaches exist and the plan is silent, a runtime error reveals the plan's assumptions were wrong, or the spec is ambiguous on a detail that affects output. Do not pick an approach and mention it in passing — describe options and trade-offs, then wait.

### Problem tracking

When you hit something unexpected during implementation, note it in chat alongside the commit summary. At session end, print a consolidated list.

### Session hygiene

Build one unit per session. After finishing a major unit, start a fresh session.

### Never modify CLAUDE.md autonomously

Changes to any CLAUDE.md file require explicit developer instruction.

### Agent-gate workflow

Specialist agents live in `.claude/agents/`. Invoke them explicitly by name.

| Agent | File | When to use |
|---|---|---|
| `architect` | `.claude/agents/architect.md` | Non-trivial changes; preserves load-bearing invariants and installer contracts. |
| `code-reviewer` | `.claude/agents/code-reviewer.md` | Before every commit; emphasizes shell, JSON settings, and installer concerns. |

For non-trivial changes:

1. Invoke `architect` — produce a written plan; do not write code yet.
2. Developer reviews and approves the plan.
3. Implement against the approved plan.
4. Invoke `code-reviewer` — resolve all findings before committing.
5. Commit only after gates pass.

For small isolated fixes (single-file, no interface changes), steps 1–2 may be skipped at the developer's discretion.
