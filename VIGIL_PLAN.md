# Vigil — rebrand and commit-review gate

## Context

Two linked pieces of work:

1. **Rebrand.** The tool is renamed Vigil. References to "Claude" that describe *this tool* (its install dir, its env vars, its shell wrappers, its session logs) are refactored out. References to Claude the model, Claude Code the CLI, and filenames Claude Code reads (`CLAUDE.md`, `~/.claude/`, `.claude/` in projects) stay unchanged — those name something external that Vigil wraps.
2. **Commit-review gate.** A long-discussed `BACKLOG.md` item (previously "git pre-push hook tooling + claude-init-repo helper") is replaced with a more defensible shape: a sandbox `denyWrite` extension that blocks persistent git-config tampering, a standalone review CLI, and an opt-in per-repo pre-push gate installed via a helper. The design discussion, including alternatives ruled out, is in the session leading to this plan; the summary of rejected paths is in `BACKLOG.md` under "Considered and not pursued."

Tracks 1 and 2 touch overlapping files. Track 1 ships first so that track 2's new code lands with the new naming and doesn't incur a rename pass later.

## Naming rules

| Stays "Claude" | Reason |
|---|---|
| `CLAUDE.md` | filename Claude Code reads |
| `~/.claude/` | Claude Code's runtime directory |
| `.claude/` inside consuming projects | same |
| the `claude` command, when unshadowed | name of the upstream Claude Code binary; after the rename, `claude` falls through to the real CLI with no Vigil wrapping |
| prose mentions of Claude, Claude Code, the Claude model | external referents |

| Becomes "Vigil" (or loses `claude-` prefix) | From |
|---|---|
| install dir `~/.config/vigil/` | `~/.config/claude-config/` |
| convenience symlink `~/.config/vigil/profiles/default` | same under new root |
| shell function `vigil` (wrapped-invocation entry point) | `claude` shell function — renamed so `claude` unshadows to the real binary, and the verb matches the tool's name |
| aliases `vigil-dev`, `vigil-strict`, `vigil-yolo` | `claude-dev`, `claude-strict`, `claude-yolo` |
| aliases `vigil-log`, `vigil-log-prune` | `claude-log`, `claude-log-prune` |
| env vars `VIGIL_SESSION_ID`, `VIGIL_LOG_DIR` | `CLAUDE_SESSION_ID`, `CLAUDE_LOG_DIR` |
| log dir `~/vigil-logs/` | `~/claude-logs/` |
| aliases file `vigil-aliases.sh` | `claude-aliases.sh` |
| hook trailer `Vigil-Session:` | `Claude-Session:` (never shipped; plan-only) |
| prose mentions of "this tool" / "claude-config" | Vigil |

The repo directory on disk (`claude-config/`) is the operator's choice; in-tree content is what this plan covers.

## Track 1: Rebrand

One logical unit per commit. Each commit leaves tests green and installer working.

1. **`refactor(config)`: rename install root to `~/.config/vigil/`.** Update `install.sh`, `update.sh`, the hook-path placeholder substitution, the `{{PROFILE_DIR}}` expansion logic, and any documentation references that name the install path. Verify `install.sh` on a fresh `$HOME` produces the new layout and old layout is moved to `.bak-<ts>`.
2. **`refactor(aliases)`: rename shell wrappers and log dir.** In `claude-aliases.sh`: rename the `claude()` shell function to `vigil()` (so `claude` unshadows to the real Claude Code binary and the wrapped-invocation verb matches the tool); rename `claude-dev`/`claude-strict`/`claude-yolo`/`claude-log`/`claude-log-prune` to their `vigil-` forms; rename `CLAUDE_SESSION_ID`/`CLAUDE_LOG_DIR` env vars to `VIGIL_*`; change log dir default from `~/claude-logs/` to `~/vigil-logs/`. Update hooks (`prune-logs.sh`, any others referencing the env vars or log path) to match. Install-side migration: detect existing `~/claude-logs/` and print a one-line "move it to `~/vigil-logs/` to keep history" note; do not auto-move. Call out the `claude` → `vigil` rename prominently in the installer output and the `README.md` changelog so returning users see it.
3. **`refactor(aliases)`: rename `claude-aliases.sh` → `vigil-aliases.sh`.** Use `git mv`. Update `install.sh` and any sourcing instructions in `README.md` / `CLAUDE.md`.
4. **`docs(config)`: prose sweep.** Search every `.md` for `claude-config`, `~/.config/claude-config`, `claude-aliases`, `claude-logs`, and the renamed aliases; replace with Vigil equivalents. Preserve "Claude", "Claude Code", and `CLAUDE.md` (the filename) references. Re-read each edited doc for coherence — some sentences will need rephrasing, not just substitution.
5. **`refactor(profiles)`: update agent definitions.** `profiles/default/agents/architect.md` and `code-reviewer.md` (plus their `.claude/agents/` copies) reference "this tool" / "the config" — update to Vigil terminology. Keep any references to Claude Code the CLI.
6. **`test(config)`: update tests.** Tests referencing old paths, env var names, or alias names get updated in lockstep. Add one regression test that asserts `install.sh` creates `~/.config/vigil/` and not `~/.config/claude-config/`.

After each commit: run the existing test tiers; confirm a fresh install on a throwaway `$HOME` boots into a working session.

## Track 2: Commit-review gate

Five phases. Phase A is a prerequisite for B–D's security claims.

### Phase A — extend `MASTER_DENY_WRITE`

File: `scripts/filter-sandbox-denies.py`.

- Add `~/.gitconfig` to the master tuple (belt-and-suspenders against Claude Code's built-in `.gitconfig` protection, which covers in-process tools but not subprocess writes per `THREAT_MODEL.md:61`).
- Extend the master-list format to accept per-repo placeholders (e.g., `{{CWD}}/.git/config` and `{{CWD}}/.git/hooks/`) so the sandbox denies cover the active working directory's git metadata. `evaluate()` must learn to handle the placeholder: either resolve at session start (requires the filter to run per session, not just per install) or emit absolute paths into `settings.json` at session start via a new hook.
- Tests: a Bash-tool attempt to `echo … >> .git/config` from within a session must fail. A Bash-tool attempt to `git config --local core.hooksPath /tmp/evil` must fail.
- Update `THREAT_MODEL.md`: add a sentence noting persistent git-config tampering from Bash-tool subprocesses is now blocked at the sandbox layer.

Commit: `feat(config): block persistent git-config and hooks writes at sandbox layer`.

### Phase B — `vigil-review` CLI

Files: `scripts/vigil-review.py` (implementation) and `bin/vigil-review` or an alias entry (user-facing name).

- Default invocation with no args: shows `@{u}..HEAD` for the current repo.
- Per commit: hash, subject, author, date, `--stat` summary, optional full diff on keypress.
- If a `Vigil-Session:` trailer is present, look up `~/vigil-logs/session-<id>.txt` and show its path; print "transcript not on this host" if absent rather than erroring.
- **Paranoid rendering** before any output reaches the terminal: strip ANSI escapes including C1 controls, drop Unicode RTL/BIDI marks, normalize overlong lines, refuse to pass untrusted content through a pager with escape interpretation. Unit-test the sanitizer against an adversarial commit-message corpus committed alongside.
- Modes: interactive (default), `--prompt` (renders then asks y/N, used by the hook), `--from-hook` (adds host/capability self-check and aborts loudly on mismatch with a specific diagnostic message).
- No security claim in isolation. Documented as a viewer.

Commit: `feat(config): add vigil-review CLI for pre-push commit inspection`.

### Phase C — stamp hook

File: `scripts/hooks/prepare-commit-msg` (template; not auto-installed).

- If `$VIGIL_SESSION_ID` is set, append `Vigil-Session: <id>` as a trailer (using `git interpret-trailers --if-exists addIfDifferent` semantics to avoid duplicates on `commit --amend`).
- If unset, no-op. Script is safe to install into repos where the operator sometimes commits outside Vigil sessions.

Commit: `feat(config): add prepare-commit-msg trailer stamp hook`.

### Phase D — pre-push gate and `vigil-install-review`

Files: `scripts/vigil-install-review` (installer), `scripts/hooks/pre-push` (template).

- `vigil-install-review <repo>` is a user-invoked command, **not** something the Vigil-sandboxed agent can run. Policies must deny `Bash(vigil-install-review:*)` in strict/dev/yolo.
- Installer steps:
  1. Platform check: Linux + bubblewrap present. Abort with explanatory message elsewhere ("push gate requires Linux + bubblewrap; CLI remains available via `vigil-review`").
  2. Verify `MASTER_DENY_WRITE` covers `.git/config` and `.git/hooks/` for this repo's resolved path. Abort if the filter hasn't been updated / session hasn't re-run the filter.
  3. **Hook-collision probe.** Git's `core.hooksPath` replaces rather than augments hook resolution; installing Vigil over an existing hook setup would silently displace it. Probe for competing configuration and abort on any hit, with a message naming what was found and how to proceed manually. Check, at minimum:
     - `core.hooksPath` already set in `.git/config` to anything other than `.git/review-gate`.
     - Executable files in `.git/hooks/` that aren't git's default `.sample` templates (operator-authored or lefthook-generated shims).
     - `.husky/` directory in the working tree (husky default location).
     - `.pre-commit-config.yaml` in the working tree (pre-commit framework).
     - `lefthook.yml`, `lefthook.yaml`, `lefthook.toml` in the working tree.
     Chaining Vigil's review with a prior hook is deferred; v1 refuses to auto-install on collision. Operators who want coexistence resolve it manually (remove the other tool, or skip Vigil's gate on that repo, or wait for a future `--chain` mode).
  4. Create `.git/review-gate/` in the target repo (name deliberately avoids `.git/claude-*` to sidestep the "non-claude subfolders" exception in the built-in `.git/` protection).
  5. Copy `prepare-commit-msg` and `pre-push` templates into `.git/review-gate/`. Mark executable. Write a `.git/review-gate/.manifest` recording SHA-256 of each script for the hook's tamper self-check.
  6. `git -C <repo> config --local core.hooksPath .git/review-gate`.
  7. Print disclaimer: per-host enforcement; re-run on each host that should enforce; `--no-verify` bypasses; review rendering trusts the operator's terminal emulator; gate does not substitute for server-side branch protection.
- `pre-push` hook template:
  - **Self-check classifies its failure modes** so the abort message is useful regardless of who's pushing. Distinguish at least:
    - *Vigil absent on this host* (`vigil-review` not on PATH, no `~/.config/vigil/`): likely a Vigil-less collaborator who received the repo via an unusual transfer, or the operator on a secondary host where they haven't installed Vigil.
    - *Vigil present but broken* (`vigil-review` on PATH but self-check fails: missing sandbox primitive, hash mismatch against `.manifest`, tampered gate dir): likely genuine breakage or tampering — operator should investigate before bypassing.
  - Abort message names three options regardless of which failure mode fired, so the escape is always discoverable:
    1. Install Vigil on this host and re-run `vigil-install-review` (or fix the broken component).
    2. Remove the gate from this clone: `git config --unset core.hooksPath`.
    3. Bypass once: `git push --no-verify`.
  - Exit non-zero on any self-check failure — block the push. Silent-skip would defeat the operator's intent; the loud message plus named escapes handles the non-Vigil-user case gracefully.
  - On success: invoke `vigil-review --from-hook <ref-range>` and exit with its status.
- **No auto-propagation.** `vigil-install-review` touches exactly the target repo's `.git/config` and `.git/review-gate/`; it does not:
  - Write `init.templateDir` (which would seed every future `git init` / `git clone` with the gate).
  - Set `core.hooksPath` in `~/.gitconfig` (which would apply to every repo on this host).
  - Walk any directory tree looking for other repos to install into.
  - Register a `SessionStart` hook that silently installs on first use in a repo.
  Each repo that should enforce the gate gets an explicit per-host, per-repo invocation. Batch / automatic modes are a separate design conversation if ever proposed.
- **Interaction with user-configured `init.templateDir`.** Vigil does not touch this setting, but operators who have it configured for their own reasons (e.g., husky-style tooling) should be aware that Vigil's gate is mutually exclusive with template-seeded hooks — the collision probe in step 3 will detect and refuse. This is mentioned in the installer's help text and in `COMPATIBILITY.md`.

Commit (two commits): `feat(config): add vigil-install-review helper for per-repo push gate` and `feat(policies): deny vigil-install-review in all policies`.

### Phase E — docs

- `THREAT_MODEL.md`: new subsection under **Mitigations by layer** titled "Commit-review gate (opt-in)." Covers:
  - *What it blocks:* commit poisoning visible before push on hosts where the gate is installed and executable.
  - *What it does not:* `--no-verify`, operator fatigue / reflexive approval, render exploits against a terminal that interprets escapes, cross-host mismatch where the gate isn't installed on the other host, composition with other hook managers (husky, pre-commit, lefthook), and — critically — the universal client-side-hook silent-skip failure modes: if the hook file loses its execute bit during transfer, if its shebang points at an interpreter absent on the host, or if line-ending mangling breaks the shebang, git silently skips the hook and the push proceeds with no review. This is a fundamental client-side-hook limitation, not specific to Vigil.
  - *When to use something stronger:* for stakes where silent-bypass is unacceptable, server-side branch protection is the correct enforcement layer; Vigil's gate does not substitute for it.
  - Move the **Out of scope → Commit review** entry to a reference to this new subsection.
- `COMPATIBILITY.md`: Linux/WSL2 verified for the gate; macOS/Windows CLI-only. Note the `init.templateDir` interaction: Vigil does not touch this user-level setting, but operators using it for their own hook tooling will hit the collision probe and should resolve manually.
- `README.md`: one-paragraph mention positioned as an optional per-repo feature, not the headline. Link to the threat-model section for scope. Resist leading with the gate — the baseline layered-defense profile remains what Vigil *is*; the gate is an additional layer available on capable hosts.
- `CLAUDE.md`: add a "Load-bearing paths" note — `.git/review-gate/` must not be modified by the coding agent; `MASTER_DENY_WRITE` placeholders are the enforcement layer.

Commit: `docs(config): document commit-review gate scope and limits`.

## Track 3: Revise `BACKLOG.md`

Single commit, in the same series as the rebrand prose sweep or immediately after:

- Remove the `git pre-push hook tooling + claude-init-repo helper` bullet from **Next-session candidates**.
- Add a bullet pointing at `VIGIL_PLAN.md` for the commit-review gate work.
- Rename `claude-config` in existing bullets to Vigil.
- Add a "Considered and not pursued" entry for the chokepoint/wrapper variant of the gate, with the reasoning that the underlying attack (persistent `core.hooksPath` tampering) is blockable at the `denyWrite` layer without a git wrapper, and the wrapper would have added maintenance + open-source attack surface for no additional coverage.
- Update `Last triaged` with today's date and a one-line note about the Vigil rebrand and gate redesign.

Commit: `docs(config): retriage backlog for Vigil rebrand and review-gate redesign`.

## Verification

Per-track:

- **Track 1:** fresh install on throwaway `$HOME` → `vigil-dev --help` works, session log lands at `~/vigil-logs/session-<ts>.log`, `VIGIL_SESSION_ID` is set inside a session. `type vigil` shows the shell function; `type claude` shows the unshadowed binary (fallthrough, no function/alias) — confirming the rename actually unshadowed the real CLI. No references to `claude-config`, `~/claude-logs`, or old env var names remain (grep the tree; allow the exceptions listed in **Naming rules**).
- **Track 2A:** in a dev session, `bash -c 'echo x >> .git/config'` fails with a sandbox denial. `git config --local core.hooksPath /tmp/x` fails.
- **Track 2B:** `vigil-review` renders a synthetic commit with an ANSI-escape-injection commit message without the escapes reaching the terminal (test against the adversarial corpus).
- **Track 2C/D:** after `vigil-install-review <repo>`, a `git push` of a test commit triggers the review; `--no-verify` bypasses as expected; running the installed hook on a host without `vigil-review` on PATH aborts loudly with all three escape options in the message. Clone the repo to a throwaway location: `core.hooksPath` is not inherited, no expectation mismatch. Rsync the repo (including `.git/`) to a second throwaway location simulating a Vigil-less host: hook runs, self-check classifies the failure as "Vigil absent," aborts loudly with escape options.
- **Track 2D collision probe:** create test repos with (a) existing `.git/hooks/pre-push` script, (b) `.husky/` directory, (c) `.pre-commit-config.yaml`, (d) `core.hooksPath` already set to `.husky`. `vigil-install-review` aborts on each with a specific message naming what was found. After removing the competing configuration, install succeeds.
- **Track 2D tamper detection:** after install, modify `.git/review-gate/pre-push` by hand; next `git push` triggers self-check hash-mismatch abort.

## Critical files

- `install.sh`, `update.sh` (rebrand paths).
- `claude-aliases.sh` → `vigil-aliases.sh` (rebrand env + log dir + alias names).
- `profiles/default/hooks/prune-logs.sh`, `prune-worktrees.sh` (env var references).
- `profiles/default/settings.template.json` (`{{PROFILE_DIR}}` substitution target may need updating if install root changes affect it).
- `scripts/filter-sandbox-denies.py` (placeholder extension; new deny entries).
- `scripts/vigil-review.py`, `scripts/hooks/prepare-commit-msg`, `scripts/hooks/pre-push`, `scripts/vigil-install-review` (new files for the gate).
- `policies/strict.json`, `dev.json`, `yolo.json` (add `Bash(vigil-install-review:*)` deny).
- `THREAT_MODEL.md`, `COMPATIBILITY.md`, `README.md`, `CLAUDE.md`, `BACKLOG.md`, `DESIGN.md`, `LIFECYCLE.md`, `AUDIENCE.md` (rebrand + gate docs).
- `tests/` (update fixture paths, env var names, add gate-specific tests).

## Execution notes

- Commit discipline per this repo's `CLAUDE.md`: one logical unit per commit; Angular conventional-commit format; scopes from the per-project list (`hooks`, `policies`, `profiles`, `aliases`, `config`).
- Invoke `architect` before starting each track's first commit; `code-reviewer` before every commit in track 2. Track 1 commits are mostly mechanical and may skip the architect gate at developer discretion (per `CLAUDE.md`'s "small isolated fixes" clause), but code-reviewer still runs on each.
- Rebrand commits should use `git mv` where files are renamed, so history follows.
- The gate's render-sanitizer and installer's self-check are the highest-risk pieces of code — prioritize adversarial testing over line coverage.
