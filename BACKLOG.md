# Backlog

Running list of known issues and proposed work, organized by triage disposition. Items here are *not* commitments — they are the current best-known set of "things to consider next" and are expected to churn. When something is acted on, remove it; when something is decided not worth doing, remove it with a note in commit history.

For project stage and what's blocking each transition, see `LIFECYCLE.md`. For verified vs. unverified protection claims, see `THREAT_MODEL.md`.

**Last triaged:** 2026-04-14 (added hook-based session-scope validation for memory writes as a next-session candidate, deferring the cross-project memory-pollution concern behind the higher-priority memory-policy decision).

## Documented gaps — do not action

These are honest limits, not bugs to fix. Listed so a maintainer encountering odd behavior recognizes the symptom and stops.

### Platform support

- **macOS/BSD `script(1)` branching not runtime-tested.** `claude-aliases.sh` adapts its `script(1)` invocation per `uname`, and Tier 6 statically verifies the case patterns cover the supported platforms, but the BSD branch has never run on a Mac/BSD host. The first such run is the test. `COMPATIBILITY.md` flags this honestly.
- **Windows (Git Bash / MSYS2) untested.** `prune-worktrees.sh` includes Windows path handling; the rest is unexercised.

### Test-suite limits

- **Matcher-semantics glob overlap between allow/deny is partially checked.** Tier 3 now catches exact-string conflicts plus dead-rule subsumption (policy allow/ask whose match set sits inside a profile deny), via `check_allow_deny_dead_rules` in `tests/semantics.py`. Two approximations remain documented in source: (a) path glob-on-glob subsumption classifies mutually-matching wildcard pairs as equivalent, so e.g. `Read({{HOME}}/**)` subsuming `Read({{HOME}}/.ssh/*)` is missed; (b) Bash space-form patterns (e.g., `Bash(git checkout -- *)`) are compared by exact token equality, with embedded `*` treated as a literal. Closing either requires a real matcher emulator or full glob-intersection solver — non-trivial.

## Next-session candidates

Each item is substantial enough to deserve its own session. Pick one, plan it, ship it, then return.

- **Active-policy banner at session start.** A second `SessionStart` hook that prints which policy is active, so the operator doesn't have to remember whether they're in `dev` or `yolo`. The hook can't read shell-exported vars (the harness scrubs hook env — see project memory), so the design has to derive the policy from `settings.json` path inspection or a dropped marker file. Plan first.
- **`git pre-push` hook tooling + `claude-init-repo` helper.** A hook that requires interactive confirmation before any push, plus a helper that installs the hook into a target repo. Directly addresses the commit-poisoning gap. Larger than a typical "easy" feature.
- **Hook-based session-scope validation for memory writes.** If any profile allows `Write(~/.claude/projects/*/memory/**)`, cross-project memory poisoning is reachable via the in-process Write tool (sandbox doesn't cover in-process tools; Claude Code's matcher has no `$PROJECT_SLUG` substitution, so the permission layer can't scope a write to the calling session's project). A `PreToolUse` hook that resolves the calling session's project slug and rejects memory-path writes to other slugs closes the gap. Secondary priority — same-project memory writes are the primary persistence surface — but cross-project poisoning is specifically harder to notice, since poison in a rarely-visited project ages silently until discovery. Design should coordinate with the memory-policy decision (deny-by-default in default/strict profile vs. allow in a separate `recall` profile); the hook most naturally lives in whichever profile enables memory writes, not in the default profile's hook set.

## Stage 2 — needs versioning / wider design

These widen appeal to less-technical users without compromising the security model. Each removes a friction point but depends on infrastructure (versioning, the `claude-config` umbrella CLI) that doesn't exist yet.

- **One-line installer.** `curl -fsSL <url> | bash` — the standard for friend-distributed dotfiles tools. Removes "clone the repo, cd into it, run install.sh" to a single paste. Trade-off: encourages running unread shell. Mitigate with a pre-install banner that names what's about to happen and exits-on-N if interactive.
- **`claude-config` CLI wrapper.** Single command for common operations: `claude-config update`, `claude-config doctor`, `claude-config policy dev` (sets default policy via shell function or env var). Centralizes paths users currently have to remember. Pairs naturally with `doctor.sh`.
- **Pre-flight check at install time.** Verify Claude Code is installed, sandbox is supported on the platform, `python3` is available, before the installer makes any changes. Today the installer assumes all this and fails cryptically when wrong. ~20 lines; turns confusing failure into "missing X, run Y to install."
- **Better install.sh error messages.** When bwrap fails, when `python3` is missing, when a path conflict is found — point at `claude-config doctor` (once it exists) and a one-line "run X to diagnose." Avoids stranding users at cryptic Linux errors.
- **A "casual" preset profile.** Not strict, not yolo, not dev — tuned for "personal laptop, not handling production data, wants safety but minimal friction." Could become the default for new installs, with `strict` promoted to "for production / shared / sensitive machines." Lowers the floor for users who aren't ready to think about the strict/dev/yolo trade-off.
- **Auto-update mechanism.** `claude-config update` fetches latest, runs the update flow that `update.sh` automates. Needs versioning first. Removes manual `git pull` cycle.

## Considered and not pursued

- **Bash/zsh/fish completion for `claude --settings`.** Multi-shell completion is a project of its own; not low-hanging despite appearances.
- **Session log rotation / indexing as a structured query layer.** Logs interleave `script(1)` raw bytes with JSON hook output; structured queryability needs a parser. (Simple time-based pruning is in "Next-session candidates" above; structured indexing is a separate, larger effort.)
- **Per-tool deny patterns for "dangerous bash one-liners"** (`rm -rf /`, fork bombs). Pattern-matching theater — bypassed by a one-character change.
- **GUI / IDE integration.** Outside scope; the kind of user who needs a GUI is probably not the target audience even after widening.
- **Wizard-driven policy customization.** Encourages editing without understanding, which is exactly what the security framing tries to prevent. The strict/dev/yolo split is the wizard.
- **Pre-built role profiles** (data scientist, web dev, homelab admin). High maintenance burden, value uncertain, risks creating a sprawl of profiles each tied to a specific stack.
- **Distribution via Brew / APT / package managers.** Real distribution work; premature for current stage.

## Maintenance

When acting on an item, remove it from this file in the same commit (or note its disposition). When considering an item not worth pursuing, remove it with a brief reason in the commit message. The file should shrink as easily as it grows. Re-triage and update the "Last triaged" date when you next return to this file.
