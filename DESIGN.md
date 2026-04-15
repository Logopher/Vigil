# DESIGN.md

This document explains the design choices behind Vigil: what it is for, how it is structured, and why. For installation see `README.md`; for platform support see `COMPATIBILITY.md`; for the project's lifecycle stage see `LIFECYCLE.md`; for what the tool does and does not defend against see `THREAT_MODEL.md`.

## What this project is

A configuration baseline and deployment mechanism for Claude Code sessions. It ships three things:

1. A default profile that is safe by construction — plan mode, a hard deny list covering destructive shell patterns, session-logging hooks, and baseline agent definitions.
2. A small set of permission policies (`strict`, `dev`, `yolo`) that can be selected per session to change how interruptive Claude's permission gates are.
3. An installer that copies the repo's profiles, policies, hooks, and shell aliases into `~/.config/vigil/` and `~/.claude/`.

## Problem being solved

Claude Code's out-of-box defaults prompt once per tool and then remember the answer within the session — suitable for trust-iteration workflows where the operator reviews after the fact. The harness ships no deny list and no sandbox. This tool adds a second baseline: dangerous command categories always deny, sandbox is on, and every action requires review in plan mode until the operator explicitly opts into a looser posture.

## Design principles

**Safe by default.** The default profile is strict. A user who installs this tool and does nothing else gets plan mode and a deny list covering `rm`, `sudo`, destructive git, network fetchers, and language runtimes. Loosening is an explicit per-session act, never implicit.

**Copy over symlink.** The installer copies repo content into `~/.config/vigil/`. Edits to the source repo — including edits Claude itself makes — do not affect running sessions until the developer re-runs the installer. The copy step is a review checkpoint.

The copy firewall depends on a second rule: Claude never runs `install.sh`. An agent that could modify source and then trigger installation would collapse the review gate. This rule appears in every project's `CLAUDE.md` and is the reason the installer has no automation hook.

**Profile and policy are separate concerns.** A profile is identity: sandbox mode, hooks, baseline deny list, agent roster. A policy is posture: how permissive the session should be for the work at hand. Profiles are rarely switched; policies are selected per session. Keeping them orthogonal means posture can change (dev vs. strict vs. yolo) without reasoning about hooks, and hooks can change without affecting per-session permission behavior.

**Small surface.** No plugins, no extension points, no runtime configuration protocol. The tool is a set of JSON files, shell scripts, and markdown docs. If you need a feature, write it directly.

**Layered defense, honest claims.** Protections come from three layers: permission-string matching (catches deliberate invocations, defeatable via semantic equivalents), OS-level sandboxing (Claude Code's [sandbox runtime](https://code.claude.com/docs/en/sandboxing), configured via the `sandbox` block in `settings.json`; catches subprocess-level reads, writes, and network — not defeatable by allowed shell builtins), and Claude Code's built-in protections. The sandbox is load-bearing for the prompt-injection threat at the *subprocess* level; Claude Code's own in-process tools (Read, Write, Edit) execute outside the sandbox and rely on the permission layer alone. The permission layer is for operator clarity, casual-damage prevention, and protection of the in-process tool channel. `THREAT_MODEL.md` enumerates exactly which adversary models each layer addresses and which are out of scope, so the user can calibrate trust against auditable promises rather than an implicit "safe" label.

## Profile and policy in detail

### Profile

A profile directory contains:

- `settings.template.json` — merged by Claude Code at session start. Sets sandbox mode, the baseline deny list, and the hook wiring. The `{{PROFILE_DIR}}` placeholder is substituted at install time so the generated `settings.json` points at the hooks on this specific machine.
- `CLAUDE.md` — instructions for Claude in every session under this profile. Covers commit discipline, agent-gate workflow, operational notes.
- `hooks/*.sh` — scripts fired at session start/end and around tool use. Currently: worktree cleanup, tool-use logging, tool-result logging.
- `agents/*.md` — specialist agent definitions (`architect`, `code-reviewer`) available in every session.

Only one profile ships today: `default`. The layout supports additional profiles alongside it. Profile selection uses the `CLAUDE_CONFIG_DIR` environment variable, which defaults to `~/.claude` — the installer symlinks `~/.claude` to the default profile, so no env var is needed for the common case.

### Policy

A policy is a JSON fragment consumed via `claude --settings <policy-path>`. It overlays the profile's permissions; it does not touch sandbox or hooks.

Three policies ship:

- **`strict`** — matches the default profile's baseline. Plan mode, deny list as-is. Useful when tooling expects an explicit policy selection rather than relying on the profile default.
- **`dev`** — `acceptEdits` mode with an allow list for routine dev work (read-only git, build and test runners for common languages). Ask-gates history-rewriting operations (`git commit --amend`, `git stash`) and filesystem metadata changes (`chmod`, `chown`, `mv`). Retains the deny baseline. Explicitly protects `.git/` and `.claude/` from writes.
- **`yolo`** — `bypassPermissions` mode with only `rm` and `sudo` in the deny list. For flow; the two bright-line catastrophe guards remain.

### Why strict is default

The secure posture should be the default and the easy path. Elevation — switching to `dev` or `yolo` — is a deliberate per-session choice, the way `sudo` is a deliberate per-command choice. A user who hits a permission block reconsiders whether the action is one they actually wanted; that pause is the feature, not the friction. If elevation is frequent for a given workflow, invoking `vigil-dev` (or `claude --settings …`) for that session restores the flow. The inverse — permissive by default, tighten when something goes wrong — means discovering the posture mismatch after damage is already done.

### When to reach for each policy

- **Routine code writing in a trusted repo:** `vigil-dev`. Runs the `dev` policy with the working directory pinned to the git repository root (see [Session wrappers](#session-wrappers)).
- **Exploratory work in an unfamiliar repo:** default profile (no `--settings`). Plan mode forces deliberate review of every action before it runs.
- **Tight iteration where every prompt is friction:** `yolo`. `rm` and `sudo` still deny; everything else flows.
- **Scripted or automated invocation where determinism matters:** `strict` as an explicit selection. Same behavior as default, but the invocation makes the policy choice visible rather than inherited.

### Policy does not enforce filesystem scope

An important property: policies govern *categories of action* (which bash commands, which tool types, which modes) but not *filesystem scope*. Claude Code's permission system has no `$PROJECT_ROOT` substitution in allow/deny patterns, so a policy file cannot express "restrict edits to the current project."

Scope enforcement comes from two other layers:

- **The sandbox**, configured in the profile. When enabled with `allowUnsandboxedCommands: false`, writes are confined to the session's working directory and `$TMPDIR`. The default profile also configures `sandbox.filesystem.denyRead` for common credential paths and `sandbox.network.allowedDomains: []` to block outbound network — process-level enforcement that cannot be bypassed by spawning a subshell.
- **Claude Code's built-in protections** for `.git`, sensitive `.claude/` files, shell RC files, and `.mcp.json` — always on regardless of policy.

This means `dev` by itself does not scope a session to the project. `dev` plus the default profile's sandbox plus being launched from the project root does. The `vigil-dev` wrapper combines those three ingredients in one command.

The sandbox is also the layer that addresses sophisticated attacks at the subprocess level. Permission-string matching catches `curl attacker.example.com` but not `echo 'base64' | base64 -d | sh`; the sandbox catches both, because the decoded subprocess inherits the sandbox's network and filesystem denies. The sandbox does *not* cover Claude Code's own in-process tools (Read, Write, Edit) — those run inside the host process and are governed only by the permission layer. See `THREAT_MODEL.md` for the full enumeration.

## Installation model

`install.sh` performs these steps:

1. Check every destination for existing content. If any of `~/.claude`, `~/.config/vigil/vigil-aliases.sh`, `~/.config/vigil/policies/<name>.json`, `~/.config/vigil/profiles/default`, or `~/.config/vigil/scripts` already exists, the installer prints the conflicting paths to stderr and exits non-zero. There is no `--force` flag.
2. Copy `vigil-aliases.sh` to `~/.config/vigil/vigil-aliases.sh`.
3. For each policy file, substitute `{{HOME}}` with the user's home directory and write to `~/.config/vigil/policies/<name>.json`. Non-template policy files (`yolo.json`) are copied verbatim.
4. Copy management scripts to `~/.config/vigil/scripts/` and make them executable.
5. Copy the default profile directly into `~/.claude/`. Substitute `{{PROFILE_DIR}}` with `$HOME/.claude` and `{{HOME}}` with the user's home directory when processing `settings.template.json`.
6. Ensure hook scripts are executable.
7. Run `scripts/filter-sandbox-denies.py` against the generated `~/.claude/settings.json` to drop any `sandbox.filesystem.denyRead` entry that is a symlink, missing, or the wrong type. Bubblewrap fails closed if any denyRead entry cannot be mounted over; this filter prevents a confusing "every Bash subprocess fails" failure mode.
8. Create a convenience symlink at `~/.config/vigil/profiles/default` pointing to `~/.claude`, so the multi-profile layout convention holds for docs and any future additional profiles.
9. Print a reminder to source `vigil-aliases.sh` from the user's shell rc.

The installer is deliberately simple: check, copy, substitute, filter, symlink. No dependency installation, no service registration, no shell-rc editing. Every path it touches is owned by the user; no `sudo` is required.

The session wrappers in `vigil-aliases.sh` re-run `filter-sandbox-denies.py` on every launch, so a system change between sessions (a credential path becoming a symlink, a directory replaced by a file, or a path disappearing) cannot silently degrade the sandbox into "fails closed for every subprocess." The filter is silent on success and tolerant of missing dependencies (`python3` absent or the script not yet installed).

### Why refuse rather than overwrite

The default profile shares a directory (`~/.claude`) with Claude Code's own runtime state — credentials (`.credentials.json`), session history (`history.jsonl`, `sessions/`), file edit history (`file-history/`), cache, and per-project state. Automatic overwrite-on-reinstall would risk clobbering credentials and session history.

The installer declines to distinguish "files we own" from "Claude Code's runtime state" heuristically, because heuristics here have a failure mode where the installer silently deletes something valuable. Refusing to run when conflicts exist forces the operator to inspect the state explicitly and move anything worth keeping before proceeding.

### Why `{{PROFILE_DIR}}` resolves to `~/.claude`

Hook references in `settings.json` (e.g., `command: {{PROFILE_DIR}}/hooks/prune-worktrees.sh`) are substituted to `$HOME/.claude/hooks/prune-worktrees.sh` — the canonical, real path — rather than to the convenience symlink at `~/.config/vigil/profiles/default`. Hook execution never resolves through a symlink, which avoids a class of sandbox-interaction bugs and keeps the runtime path identity-stable if the symlink is later changed or removed.

## Session wrappers

`vigil-aliases.sh` defines four shell functions, all using `script(1)` to log the session. The bare `claude` command is no longer wrapped — it falls through to the upstream Claude Code binary unchanged, preserving a name for invocations that should escape Vigil's session logging and env scrubbing.

- **`vigil`** — standard session under the active profile (default). No policy applied.
- **`vigil-strict`** — session with the `strict` policy explicitly applied. Behaviorally equivalent to the default profile baseline; useful when tooling expects an explicit policy selection rather than relying on the profile default.
- **`vigil-dev`** — session with the `dev` policy and the working directory pinned to the current git repository's root. The `cd` runs in a subshell so the caller's working directory is not disturbed. If the current directory is not inside a git repo, `vigil-dev` falls back to the current directory.
- **`vigil-yolo`** — session with the `yolo` policy applied. Bypasses confirmations; retains `rm` and `sudo` denies.

`vigil-dev` exists because `dev` alone does not scope a session to the project (see [Policy does not enforce filesystem scope](#policy-does-not-enforce-filesystem-scope)). Combining the `dev` policy with a project-root working directory gives the sandbox a scope to enforce, producing a permissive-but-contained session in one command.

## Session logging

### Why this exists

Claude Code does not give the user direct access to their own conversation history as readable files. Sessions can be resumed inside Claude Code, and the terminal has scrollback while a session is open, but there is no documented place to grep your past prompts or pull a transcript out for archival, citation, or sharing without copy-pasting the rendered TUI by hand. This tool exists to close that gap.

The goal is *user-owned, readable conversation history*. Anything else (debugging payloads, structured tool data, integration with external log aggregators) is out of scope.

### How it works

Both session wrappers pipe Claude through `script(1)`, which captures every byte the TUI writes to `~/vigil-logs/session-<timestamp>.log`. The wrapper branches on `uname` for platform-correct `script(1)` flags (BSD and util-linux differ).

The raw `.log` is faithful to the terminal — `cat` it in a real TTY and the session re-renders, escape codes and all — but it is not readable as a transcript. Every cursor move and color change is in the byte stream.

After `script` returns, the wrapper post-processes the `.log` into a parallel `.txt` via `scripts/strip-ansi.py`. The `.txt` is a plain transcript: ANSI sequences, charset selections, terminal-control characters, bare carriage returns, and runs of blank lines are stripped or collapsed. This is what the user reads or greps. Both files are kept; the `.log` for full fidelity, the `.txt` for the actual purpose.

The post-processing runs in the shell wrapper rather than as a Claude Code hook because hooks fire inside the sandbox, which scrubs the env vars the wrapper sets to communicate the log path. The shell wrapper has no such constraint.

## Non-goals

The tool deliberately does not:

- **Manage credentials.** Claude Code authentication, API keys, and OAuth tokens live in Claude Code's own configuration, outside this repo's scope.
- **Target Windows natively.** Windows users run under WSL. Native cmd/PowerShell support is not planned.
- **Provide a config DSL or macro language.** If JSON is too awkward for a use case, the answer is a new policy file, not a template system.
- **Solve team configuration.** Every install is single-user. Team-wide policy distribution is out of scope.
- **Replace Claude Code's own permission system.** The tool composes with the harness's permissions machinery; it does not reimplement it.
