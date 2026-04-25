# PERMISSIVE_PROFILE_DESIGN.md

Design for the permissive profile and `vigil set-default <profile>` profile-swap command. These ship together as a single feature. For the current profile/policy model see `DESIGN.md`; for threat posture see `THREAT_MODEL.md`.

## Problem

The default profile is strict by construction. Claude Code's permission-layer semantics — deny beats allow, order-insensitive — mean policies layered on top can only add restrictions. `dev` and `yolo` are meaningful as "add restrictions on top of an already-strict baseline," not as lighter alternatives to it. A developer who wants less friction has no supported path.

## Decision

Keep the strict default profile intact. Add a **permissive profile** with a lighter floor that users opt into via `vigil set-default permissive`. Within the permissive profile, policies have room to express genuinely different postures.

This is an explicit opt-out of strict behavior. Desktop-app and IDE-extension launches use whatever profile is installed at `~/.claude/`; users who have not run `vigil set-default permissive` are unaffected and retain full strict posture.

## Architecture

### The two profiles

**Default profile** (`~/.config/vigil/profiles/default/`) — unchanged. Heavy deny list, plan mode, sandbox, hooks. What `install.sh` activates; what all launch surfaces use until the user explicitly swaps.

**Permissive profile** (`~/.config/vigil/profiles/permissive/`) — lighter floor. Sandbox and hooks identical to default. Deny list contains only the non-negotiable minimum:

- `Bash(rm:*)`, `Bash(sudo:*)`, `Bash(vigil-install-review:*)`
- All Write/Edit/MultiEdit persistence-path denies (Vigil's own config, shell RCs, `.gitconfig`) — these are "a session must not tamper with its own enforcement surface" rules, not posture choices
- `defaultMode: plan`

No Bash category denies (git mutations, network fetchers, runtimes, etc.) and no credential-path Read denies — those live in the strict policy.

### `vigil` always applies the strict policy

The `vigil` shell wrapper always passes `--settings ~/.config/vigil/policies/strict.json`.

On the **default profile**: the strict policy entries overlap with the profile — deny lists merge, producing the same set. No behavioral change from today.

On the **permissive profile**: the strict policy adds the heavy Bash deny list and credential-path Read denies on top of the permissive floor, reproducing default-profile-equivalent behavior.

This eliminates active-profile detection in the wrapper: `vigil` means "careful session" regardless of which profile is installed.

**`vigil-dev` and `vigil-yolo` are only meaningful on the permissive profile.** On the default profile, the profile's deny list dominates — deny beats allow, so `dev`'s allow entries are dead rules and the session ends up with the same restrictions as `vigil`. A user on the default profile who runs `vigil-dev` gets `acceptEdits` mode but no actual permission relief. On the permissive profile, the floor is low enough that the policies express genuine posture differences.

| | Default profile | Permissive profile |
|---|---|---|
| `vigil` | full deny list (profile is strict) | permissive floor + strict policy → ≈ default behavior |
| `vigil-dev` | full deny list unchanged (dev allows are dead against profile denies) | permissive floor + dev policy → real dev posture |
| `vigil-yolo` | full deny list unchanged (yolo allows are dead against profile denies) | permissive floor + yolo policy → real yolo posture |

### Strict policy with both profiles

`policies/strict.template.json` already mirrors the full default profile deny list. When loaded with the permissive profile the redundant entries (rm, sudo, persistence denies) are harmless. No change to the strict policy is required — it serves both profiles as-is.

### `vigil set-default <profile>` command

A new shell function in `vigil-aliases.sh`. (Can be promoted to a `vigil` CLI subcommand when the Stage 2 `vigil` CLI lands; shell function is the simpler path now.)

**Sequence:**

1. Read `~/.config/vigil/active-profile` to identify the current profile name. Absent file → treat as `default`.
2. Refuse if any Claude Code process is running: `pgrep -x claude` fast-check, then `lsof +D ~/.claude/` belt-and-suspenders.
3. Validate `~/.config/vigil/profiles/<target>/` exists and contains `settings.json`.
4. Diff the files that will be overwritten (`settings.json`, `CLAUDE.md`, `hooks/`, `agents/`) against the current profile bundle. If any differ from the bundle (i.e., the user has locally edited them), print the differing paths and exit. `--force` skips this check.
5. Stage the swap: copy target profile files into `~/.config/vigil/staging/`, then move each file into `~/.claude/` individually. Runtime state (`projects/`, `sessions/`, `history.jsonl`, `plans/`, `todos/`, etc.) is never touched.
6. Write `<target>` to `~/.config/vigil/active-profile`.
7. Print `Switched to profile: <target>`.

**Atomicity**: `mv` of individual files is not atomic across the set, but each individual file move is. A crash mid-swap leaves `~/.claude/` with a mix of old and new files; re-running `vigil set-default <target>` recovers because the staging copy is still valid and the source bundle is always intact.

**Live-edit semantics**: If the user edits `~/.claude/CLAUDE.md` directly while the permissive profile is active, that edit lives in `~/.claude/` — not in the bundle. The diff check at step 4 catches this before the next `vigil set-default` clobbers it, prompting the user to either copy the edit into the bundle or pass `--force`.

### Dependency on `update.sh` manifest

The original backlog framing listed `update.sh` manifest work as a prerequisite. That dependency is relaxed: `vigil set-default` handles its own "don't clobber local edits" concern via the diff check at swap time, without needing a hash manifest. `update.sh` manifest work remains valuable for the `update.sh` code path but does not block this feature.

## Files to create or modify

**New:**
- `profiles/permissive/settings.template.json` — permissive floor deny list; `{{HOME}}` and `{{PROFILE_DIR}}` placeholders as in default profile
- `profiles/permissive/CLAUDE.md` — pointer to the global CLAUDE.md collaboration rules; no new content (same as `profiles/default/CLAUDE.md` structure)
- `profiles/permissive/hooks/` — copies of `prune-worktrees.sh` and `prune-logs.sh`; copy not symlink, per the copy-firewall principle
- `profiles/permissive/agents/` — copies of `architect.md` and `code-reviewer.md`

**Modified:**
- `vigil-aliases.sh` — (a) add `vigil set-default <profile>` function; (b) change `vigil` and `vigil-strict` to pass `--settings ~/.config/vigil/policies/strict.json` unconditionally
- `install.sh` — install the permissive bundle under `~/.config/vigil/profiles/permissive/`; write `~/.config/vigil/active-profile` → `"default"` on fresh install; skip the write if the file already exists (idempotent re-run)
- `tests/semantics.py` — `check_baseline_consistency` asserts `profile.deny == strict.deny`; this still holds for the default profile, but the permissive profile's new invariant is `permissive.deny ⊂ strict.deny ⊂ default.deny`. Add a parameterized check or a second test for the permissive template.

**Not modified:**
- `policies/strict.template.json` — works with both profiles as-is
- `profiles/default/settings.template.json` — unchanged
- `update.sh` — no changes required; manifest work is independent

## Open questions

1. **`vigil-strict` alias fate.** Once `vigil` always applies strict, `vigil-strict` is redundant. Keep as alias (documents intent, preserves muscle memory) or remove (smaller surface). Recommend keeping.

2. **`~/.config/vigil/active-profile` on pre-upgrade installs.** File will be absent on machines that installed before this feature shipped. The wrapper and `vigil set-default` should treat an absent file as `"default"` and not fail.

3. **Hooks and agents as copies vs. references.** The permissive profile needs identical hooks and agents to the default. Copies are correct per the copy-firewall design principle. A future change to `prune-worktrees.sh` must be applied to both profile bundles; a `diff -r profiles/default/hooks profiles/permissive/hooks` in the test suite or a Tier 1 static check would catch drift.

4. **`vigil set-default` scope.** Should `vigil set-default` also update `CLAUDE_CONFIG_DIR` for the current shell (via `export CLAUDE_CONFIG_DIR=...`)? Probably not — `vigil set-default` is a persistent machine-level swap, not a per-session override. A session-scoped variant can be added later if needed.

## What this supersedes

The Stage 2 backlog item "A 'casual' preset profile" is superseded by this design — the permissive profile serves that purpose with a defined floor and an explicit opt-in path. The framing in that item ("could become the default for new installs") is explicitly not the chosen direction: strict remains the default.
