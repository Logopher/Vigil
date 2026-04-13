# DESIGN.md

This document explains the design choices behind claude-config: what it is for, how it is structured, and why. For installation see `README.md`; for platform support see `COMPATIBILITY.md`; for the project's lifecycle stage see `LIFECYCLE.md`; for what the tool does and does not defend against see `THREAT_MODEL.md`.

## What this project is

A configuration baseline and deployment mechanism for Claude Code sessions. It ships three things:

1. A default profile that is safe by construction — plan mode, a hard deny list covering destructive shell patterns, session-logging hooks, and baseline agent definitions.
2. A small set of permission policies (`strict`, `dev`, `yolo`) that can be selected per session to change how interruptive Claude's permission gates are.
3. An installer that copies the repo's profiles, policies, hooks, and shell aliases into `~/.config/claude-config/` and symlinks `~/.claude` to the default profile.

## Problem being solved

Claude Code's out-of-box defaults prompt once per tool and then remember the answer within the session — suitable for trust-iteration workflows where the operator reviews after the fact. The harness ships no deny list and no sandbox. This tool adds a second baseline: dangerous command categories always deny, sandbox is on, and every action requires review in plan mode until the operator explicitly opts into a looser posture.

## Design principles

**Safe by default.** The default profile is strict. A user who installs this tool and does nothing else gets plan mode and a deny list covering `rm`, `sudo`, destructive git, network fetchers, and language runtimes. Loosening is an explicit per-session act, never implicit.

**Copy over symlink.** The installer copies repo content into `~/.config/claude-config/`. Edits to the source repo — including edits Claude itself makes — do not affect running sessions until the developer re-runs the installer. The copy step is a review checkpoint.

The copy firewall depends on a second rule: Claude never runs `install.sh`. An agent that could modify source and then trigger installation would collapse the review gate. This rule appears in every project's `CLAUDE.md` and is the reason the installer has no automation hook.

**Profile and policy are separate concerns.** A profile is identity: sandbox mode, hooks, baseline deny list, agent roster. A policy is posture: how permissive the session should be for the work at hand. Profiles are rarely switched; policies are selected per session. Keeping them orthogonal means posture can change (dev vs. strict vs. yolo) without reasoning about hooks, and hooks can change without affecting per-session permission behavior.

**Small surface.** No plugins, no extension points, no runtime configuration protocol. The tool is a set of JSON files, shell scripts, and markdown docs. If you need a feature, write it directly.

**Layered defense, honest claims.** Protections come from three layers: permission-string matching (catches deliberate invocations, defeatable via semantic equivalents), OS-level sandboxing (catches subprocess-level reads, writes, and network — not defeatable by allowed shell builtins), and Claude Code's built-in protections. The sandbox is load-bearing for the prompt-injection threat; the permission layer is for operator clarity and casual-damage prevention. `THREAT_MODEL.md` enumerates exactly which adversary models each layer addresses and which are out of scope, so the user can calibrate trust against auditable promises rather than an implicit "safe" label.

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

The secure posture should be the default and the easy path. Elevation — switching to `dev` or `yolo` — is a deliberate per-session choice, the way `sudo` is a deliberate per-command choice. A user who hits a permission block reconsiders whether the action is one they actually wanted; that pause is the feature, not the friction. If elevation is frequent for a given workflow, invoking `claude-dev` (or `claude --settings …`) for that session restores the flow. The inverse — permissive by default, tighten when something goes wrong — means discovering the posture mismatch after damage is already done.

### When to reach for each policy

- **Routine code writing in a trusted repo:** `claude-dev`. Runs the `dev` policy with the working directory pinned to the git repository root (see [Session wrappers](#session-wrappers)).
- **Exploratory work in an unfamiliar repo:** default profile (no `--settings`). Plan mode forces deliberate review of every action before it runs.
- **Tight iteration where every prompt is friction:** `yolo`. `rm` and `sudo` still deny; everything else flows.
- **Scripted or automated invocation where determinism matters:** `strict` as an explicit selection. Same behavior as default, but the invocation makes the policy choice visible rather than inherited.

### Policy does not enforce filesystem scope

An important property: policies govern *categories of action* (which bash commands, which tool types, which modes) but not *filesystem scope*. Claude Code's permission system has no `$PROJECT_ROOT` substitution in allow/deny patterns, so a policy file cannot express "restrict edits to the current project."

Scope enforcement comes from two other layers:

- **The sandbox**, configured in the profile. When enabled with `allowUnsandboxedCommands: false`, writes are confined to the session's working directory and `$TMPDIR`. The default profile also configures `sandbox.filesystem.denyRead` for common credential paths and `sandbox.network.allowedDomains: []` to block outbound network — process-level enforcement that cannot be bypassed by spawning a subshell.
- **Claude Code's built-in protections** for `.git`, sensitive `.claude/` files, shell RC files, and `.mcp.json` — always on regardless of policy.

This means `dev` by itself does not scope a session to the project. `dev` plus the default profile's sandbox plus being launched from the project root does. The `claude-dev` wrapper combines those three ingredients in one command.

The sandbox is also the layer that addresses sophisticated attacks. Permission-string matching catches `curl attacker.example.com` but not `echo 'base64' | base64 -d | sh`; the sandbox catches both, because the decoded subprocess inherits the sandbox's network and filesystem denies. See `THREAT_MODEL.md` for the full enumeration.

## Installation model

`install.sh` performs a single operation with two branches:

1. Move any existing `~/.config/claude-config/` to `~/.config/claude-config.bak-<timestamp>/` (unless `--force`).
2. Copy `profiles/`, `policies/`, and `claude-aliases.sh` into `~/.config/claude-config/`.
3. For each `settings.template.json`, substitute `{{PROFILE_DIR}}` with the installed profile path and write `settings.json` alongside.
4. Move any existing `~/.claude` aside and symlink `~/.claude` to the default profile.
5. Print a reminder to source `claude-aliases.sh` from the user's shell rc.

The installer is deliberately simple: copy, substitute, symlink. No dependency installation, no service registration, no shell-rc editing. Every path it touches is owned by the user; no `sudo` is required.

## Session wrappers

`claude-aliases.sh` defines two shell functions, both using `script(1)` to log the session:

- **`claude`** — standard session under the active profile (default). No policy applied.
- **`claude-dev`** — session with the `dev` policy and the working directory pinned to the current git repository's root. The `cd` runs in a subshell so the caller's working directory is not disturbed. If the current directory is not inside a git repo, `claude-dev` falls back to the current directory.

`claude-dev` exists because `dev` alone does not scope a session to the project (see [Policy does not enforce filesystem scope](#policy-does-not-enforce-filesystem-scope)). Combining the `dev` policy with a project-root working directory gives the sandbox a scope to enforce, producing a permissive-but-contained session in one command.

## Session logging

Both wrappers pipe the session through `script(1)` to capture the interactive TUI to `~/claude-logs/session-<timestamp>.log`. The wrapper branches on `uname` for platform-correct `script(1)` syntax (BSD and util-linux take different flags).

The logging hooks (`log-tool-use.sh`, `log-tool-result.sh`) append JSON entries to the same log around each tool call. Together they produce a log that captures both the TUI-rendered conversation (via `script`) and the machine-readable tool payload (via hooks).

## Non-goals

The tool deliberately does not:

- **Manage credentials.** Claude Code authentication, API keys, and OAuth tokens live in Claude Code's own configuration, outside this repo's scope.
- **Target Windows natively.** Windows users run under WSL. Native cmd/PowerShell support is not planned.
- **Provide a config DSL or macro language.** If JSON is too awkward for a use case, the answer is a new policy file, not a template system.
- **Solve team configuration.** Every install is single-user. Team-wide policy distribution is out of scope.
- **Replace Claude Code's own permission system.** The tool composes with the harness's permissions machinery; it does not reimplement it.
