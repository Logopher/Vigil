# Vigil

**Paranoid-by-default configuration for Claude Code.** Layered deny-lists, OS-level sandboxing, session audit hooks, and an install discipline that refuses to clobber existing state.

## What Vigil does

Vigil has two layers. The **default profile** (`~/.claude/settings.json`) — deny list, hooks, sandbox rules — constrains every Claude Code session regardless of launch context: the VS Code extension, the Claude Code desktop app, and the CLI all pick it up. The **posture layer** — policy overlays, session logging, and interactive convenience functions like `vigil-dev` — is implemented as bash and only activates when Claude Code is launched from an interactive shell. IDE and desktop-app launches receive the profile baseline; they do not receive the posture layer.

- Ships a strict-by-construction profile for Claude Code: plan mode, a hard deny list covering destructive, network, runtime-launch, and credential-path operations, and logging hooks for every tool call.
- Provides three permission policies — `strict`, `dev`, `yolo` — selected per session as `--settings` overlays. Profile is identity; policy is posture.
- Records every session under `~/vigil-logs/` via `script(1)`, retrievable by date or offset through the `vigil-log` wrapper.
- Applies OS-level sandboxing where available; see [`COMPATIBILITY.md`](COMPATIBILITY.md) for per-platform status.
- Refuses to overwrite an existing installation. There is no `--force` flag. Re-installation requires manual cleanup first, because the destination may contain Claude Code runtime state the installer cannot reconstruct for you.

## Who Vigil is for

**Sweet spot.** A mid-to-senior developer comfortable in a Linux / WSL2 / macOS terminal, security-aware enough to want a baseline for autonomous agents but uninterested in designing one from scratch. The split between profile (identity, hooks, sandbox) and policy (posture: `strict` / `dev` / `yolo`) should click quickly — it mirrors AWS profiles, browser profiles, and IAM policies.

**Above the sweet spot.** Senior developers with their own opinionated Claude Code config. Welcome to fork, steal ideas, or politely ignore.

**Outside current scope.** Users without terminal proficiency; native Windows users without WSL (installer is bash-only); users unwilling to manage their own `~/.claude/settings.json`. The full value of Vigil depends on launching Claude Code through the bash wrappers; users whose Claude Code runs primarily through the VS Code extension or the desktop app receive the profile baseline (see [What Vigil does](#what-vigil-does) above) but not the posture layer.

For the longer version — common misconceptions, self-use vs. friend-deploy split, and a practical "is this for me?" test — see [`AUDIENCE.md`](AUDIENCE.md).

## How this was built

Vigil was designed and implemented through extended collaboration with Claude. I'm a developer with security intuition; I'm not a credentialed security engineer. The threat model, deny-list composition, sandbox configuration, and install discipline reflect my best thinking, iterated across many Claude sessions and cross-checked against ecosystem documentation.

Vigil is open-sourced specifically because I want scrutiny from people with deeper expertise than I have. If you find a weak mitigation, an oversold claim, a deny-list gap, or a sandbox bypass — open an issue. Teardowns are more useful to me than endorsements.

## What Vigil protects against, and what it doesn't

**Protects against:**

- Claude invoking destructive commands (`rm -rf`, `sudo`, non-read-only `git`) without explicit consent.
- Subprocess attacks via deny-listed runtimes (`python`, `node`, `npx`) and network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`).
- Credential exfiltration via read paths (`~/.ssh/`, `~/.aws/`, etc.) — at the sandbox layer on Linux, at the permission layer elsewhere.
- Loss of audit trail: every session is transcribed and retained under a configurable retention policy.
- Silent install drift: the copy-based install discipline forces every change through a reviewable install step rather than live-patching the running config.

**Does not protect against:**

- Prompt injection steering Claude's *reasoning* toward a harmful-but-schema-valid output. The sandbox constrains actions, not thoughts.
- Semantic manipulation via attacker-controlled inputs that Claude reads (file content, tool output, pulled web pages).
- A user who explicitly authorizes a risky action at the permission prompt.
- Compromised Claude Code binaries or Anthropic-side model behavior.
- Render-layer attacks (terminal escape sequences, trust-UI spoofing) in session transcripts.

See [`THREAT_MODEL.md`](THREAT_MODEL.md) for the detailed enumeration per layer and the honest concessions where mitigations are soft.

## Quickstart

Clone anywhere, then run the installer:

```
git clone https://github.com/Logopher/Vigil.git ~/code/vigil
cd ~/code/vigil
./install.sh
```

The installer copies to two locations:

- `~/.claude/` — the default profile. This is a real directory shared with Claude Code's runtime state (credentials, sessions, history); the name is external, not Vigil-specific.
- `~/.config/vigil/` — the shell alias, the policy files, and a convenience symlink to the default profile.

Add to your `~/.bashrc` (or equivalent):

```
[ -f ~/.config/vigil/vigil-aliases.sh ] && source ~/.config/vigil/vigil-aliases.sh
```

This defines the `vigil`, `vigil-dev`, `vigil-strict`, `vigil-yolo`, `vigil-log`, and `vigil-log-prune` wrappers, and ensures sessions are recorded under `~/vigil-logs/`.

Run `./doctor.sh` at any point to check platform support, detect missing dependencies, and verify install integrity.

## Profiles and policies

The **default profile** is safe by construction: plan mode, the hard deny list, hooks, and sandbox rules. It lives at `~/.claude/` and applies to any Claude Code session started under Vigil.

**Policies** are permission overlays selected per session via `--settings`. Shell wrappers save the typing:

| Wrapper | Equivalent | Notes |
|---|---|---|
| `vigil` | bare `claude` | default profile baseline; plan mode; session logging via `script(1)` |
| `vigil-dev` | `claude --settings .../policies/dev.json` | `cd` to git root; uninterrupted dev work; safety gates on risky ops |
| `vigil-strict` | `claude --settings .../policies/strict.json` | same as the default profile baseline, made explicit |
| `vigil-yolo` | `claude --settings .../policies/yolo.json` | bypasses confirmations; retains `rm` and `sudo` denies |

`vigil-log` opens a session transcript in `$PAGER`. With no arguments it shows the most recent session; `vigil-log -1` shows the previous one (`-2` the one before that); `vigil-log 20260413` (or `2026-04-13`) opens the most recent transcript matching that date prefix.

`vigil-log-prune` deletes old session logs from `~/vigil-logs/`. A `SessionStart` hook runs the same pruner automatically with defaults of 90 days and 2 GB total. For manual pruning, pass custom thresholds: `vigil-log-prune --older-than 30d --dry-run`.

## Commit-review gate (opt-in)

An optional per-repo pre-push review, installed by running `vigil-install-review` inside the target repo. Each outgoing commit is rendered with a paranoid sanitizer (stripping ANSI, C1, and BIDI escapes) and the operator confirms y/N before the push proceeds. See [`THREAT_MODEL.md`](THREAT_MODEL.md#commit-review-gate-opt-in) for scope, silent-skip failure modes, and the cases where server-side branch protection is the correct layer instead.

## Updating

Repo edits do not change session behavior until the installer runs. To refresh:

```
cd ~/code/vigil
git pull
./update.sh        # interactive; pass -y to skip the prompt
```

`update.sh` defers to `uninstall.sh` to remove only files placed by this repo, moves any surviving state (Claude Code runtime data and user additions like custom agents, hooks, or policies) into a tempdir, runs `install.sh` into the now-empty destinations, then restores the saved state with `cp -rn` — so for any path that appears in both the saved state and the fresh install, the fresh install wins. On clean exit the tempdir is removed; on failure it is preserved and its path is printed.

**Caveat: local edits to installed files are destroyed on update.** If you hand-edit `~/.config/vigil/vigil-aliases.sh`, a policy file, or any other file that the installer also places, your edit is silently overwritten by the next `update.sh` run. The workaround today is to make the edit in the repo instead and update — the install is the source of truth. This is a known limitation, not the intended long-term behavior; a manifest-based change-detection scheme that preserves divergent local edits is tracked in `BACKLOG.md` under "`update.sh` change-detection via install manifest."

## Uninstalling

```
cd ~/code/vigil
./uninstall.sh     # interactive; pass -y to skip the prompt
```

Removes only files placed by `install.sh`. Claude Code runtime state in `~/.claude/` (credentials, sessions, history, projects) is preserved. User-added files under `~/.claude/agents/` and `~/.claude/hooks/` are also preserved — only entries that originated from Vigil are removed.

## Project posture

**Support.** Best-effort, no SLA. Issues are read and triaged as time allows; responsiveness is not guaranteed. Reports with reproducible steps land faster than open-ended discussion.

**Security.** Private vulnerability reporting is enabled on this repository — use the **Report a vulnerability** button on the [Security tab](https://github.com/Logopher/Vigil/security) for anything you'd rather not disclose publicly. See [`SECURITY.md`](SECURITY.md) for scope, response expectations, and stage-level caveats.

**Contributions.** Pull requests are not being accepted at this stage — please open an issue instead. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the rationale and what to do instead.

**Telemetry.** Vigil does not collect telemetry today, and will never collect telemetry on an opt-out basis. If telemetry is ever added, it will be strictly opt-in, disabled by default, and the exact payload will be documented in this repo before the feature ships. A tool whose entire purpose is constraining what code agents do on your machine cannot defensibly phone home without your consent.

**Stage.** Vigil is at Stage 1 of the lifecycle in [`LIFECYCLE.md`](LIFECYCLE.md) — shareable with trusted friends, pre-stranger. Interfaces may change.

## Further reading

- [`DESIGN.md`](DESIGN.md) — architecture and rationale: the profile/policy split, the copy-based install discipline, the layered deny-list model, the deliberate rejection of plugins and runtime configuration protocols.
- [`THREAT_MODEL.md`](THREAT_MODEL.md) — what Vigil protects against at each layer, what it explicitly does not, and the adversary models that are and aren't in scope.
- [`COMPATIBILITY.md`](COMPATIBILITY.md) — per-platform support status and known gaps (Linux / WSL2 / macOS / native Windows).
- [`AUDIENCE.md`](AUDIENCE.md) — the longer version of "who this is for," including common misconceptions and a self-check.
- [`LIFECYCLE.md`](LIFECYCLE.md) — project stage framework. Vigil is pre-1.0; interfaces may change.
- [Commit-review gate](THREAT_MODEL.md#commit-review-gate-opt-in) — scope and limits of the opt-in pre-push gate.
- [`BACKLOG.md`](BACKLOG.md) — longer tail of ideas and deferred work.

## License

Vigil is released under the [MIT License](LICENSE).
