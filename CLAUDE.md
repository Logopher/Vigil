# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo holds the user's personal Claude Code configuration. It is consumed via symlinks — it is not built, tested, or deployed. Edits here take effect in other projects the next time `claude` is invoked.

- `global-settings.json` → symlinked to `~/.claude/settings.json`
- `project-settings.json` → symlinked to `<project>/.claude/settings.json` (e.g. `~/code/TCard/.claude/settings.json`)
- `claude.sh` → sourced from `~/.bashrc`; wraps the `claude` CLI with `script(1)` to record each session under `~/claude-logs/session-<timestamp>.log`

Because of the symlinks, changing a file here is a live change to Claude's behavior — there is no install step. Be deliberate.

## Architecture

Two layers of settings, merged by the Claude Code harness:

1. **Global** (`global-settings.json`) — sandbox mode, a hard `deny` list of shell patterns (`rm`, `git push/pull/fetch/reset/rebase/merge/clean/restore`, `curl`, `wget`, `node`, `python`, `npx`, `npm publish`), and hooks wiring.
2. **Project** (`project-settings.json`) — permissive `allow` list for reads/edits and common git/npm commands, with `ask` gates on `git commit --amend`, `git stash`, and `WebFetch`.

Hooks registered in the global settings:

- `SessionStart` / `SessionEnd` → `prune-worktrees.sh`
- `PreToolUse` → `log-tool-use.sh` (appends JSON payload to the session log)
- `PostToolUse` → `log-tool-result.sh`

The logging hooks rely on `CLAUDE_SESSION_ID` and `CLAUDE_LOG_DIR` exported by `claude.sh`. If Claude is launched without that wrapper, the hooks will write to an undefined path — keep that in mind when debugging missing logs.

## `prune-worktrees.sh`

Runs at session start and end against `<repo>/.claude/worktrees/`. Its invariants are load-bearing — preserve them when editing:

1. Never removes a worktree directory with uncommitted changes.
2. Never prunes git metadata for a dirty worktree (verified with a post-prune safety check that warns on violation).
3. Only deletes `claude/*` branches that are fully merged into `main` (uses `git branch -d`, not `-D`); unmerged branches are reported, not deleted.

Worktree matching is by basename, not full path, to survive Windows/MSYS2 path-format mismatches (`C:/...` vs `/c/...`).

## Editing conventions

- Permission lists in the JSON files are order-insensitive but duplicates between `allow`/`deny` resolve to `deny` — add to `deny` rather than removing from `allow` when tightening.
- Use the colon matcher form (`Bash(rm:*)`) for deny/allow patterns; the space form (`Bash(rm *)`) is non-standard.
- After editing a settings file, the change is live for the next `claude` invocation in any consuming project — no reload needed here.

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

For non-trivial changes:

1. Invoke `architect` — produce a written plan; do not write code yet.
2. Developer reviews and approves the plan.
3. Implement against the approved plan.
4. Invoke `code-reviewer` — resolve all findings before committing.
5. Commit only after gates pass.

For small isolated fixes (single-file, no interface changes), steps 1–2 may be skipped at the developer's discretion.

The `code-reviewer` for this repo emphasizes shell-script concerns (quoting, `set -e` behavior, MSYS2/WSL path handling), Claude Code settings invariants (allow/deny precedence, dual matcher coverage, hook path resolution), and the load-bearing invariants called out elsewhere in this file.
