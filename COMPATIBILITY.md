# Compatibility

Platform support for Vigil. "Tested" means the author has verified installation and routine use on that platform. "Adapted" means the code contains platform-specific branches for it but no one has actually run it there yet.

| Platform | Status | Notes |
|---|---|---|
| Linux (WSL2, Ubuntu) | Tested | Primary development target. All tooling works. |
| Linux (native, any distro with bash + git + util-linux `script`) | Adapted, untested | Should behave identically to WSL2. |
| macOS | Adapted, untested | `vigil-aliases.sh` branches on `uname` to use BSD `script(1)` syntax. System `/bin/bash` is 3.2 and sufficient for every bash feature this repo uses. |
| FreeBSD / OpenBSD / NetBSD | Adapted, untested | Same `script(1)` path as macOS. Bash is not installed by default on these systems — user must have bash on `$PATH` (`#!/usr/bin/env bash` depends on it). |
| Windows (Git Bash / MSYS2) | Untested | `prune-worktrees.sh` contains explicit handling for MSYS2 path translation (basename-only matching to survive `C:/…` vs `/c/…` mismatch). Installer and the rest have not been exercised here. Symlink behavior on MSYS2 is historically unreliable. |
| Windows native (PowerShell / cmd.exe) | Not supported | Install script is bash-only. Use WSL2 instead. |

## Launch context

Platform support describes the OS and shell surface this tool targets. Launch context describes how Claude Code itself is invoked within that surface:

| Launch context | Coverage | Notes |
|---|---|---|
| Terminal via Vigil session wrappers (`vigil`, `vigil-dev`, `vigil-strict`, `vigil-yolo`) | Full | Profile, session logging, environment scrub, per-session policy selection. Recommended path on every supported platform. |
| Terminal via bare `claude` | Profile only | `claude` now falls through to the upstream Claude Code binary. Default profile applies; no session logging, no environment scrub, no policy overlay. |
| VS Code Claude Code extension | Profile only | Reads `~/.claude/settings.json` at session start. Does not route through the bash wrappers. |
| Claude Code desktop app | Profile only | Same as the VS Code extension. |

The discriminator between full coverage and profile-only is the bash wrappers, not the OS. Desktop-app users on macOS and Linux receive equivalent (partial) coverage; terminal users on macOS and Linux receive equivalent (full) coverage.

## Commit-review gate

The opt-in pre-push gate installed by `vigil-install-review` is verified on Linux and WSL2 only. macOS and native Windows (Git Bash / MSYS2) receive `vigil-review` as a CLI viewer, but the installer aborts on its platform check — the gate's security model depends on the bubblewrap-backed sandbox enforcement that keeps the agent out of `.git/`, which is Linux-specific. The Python and shell scripts themselves would run on other platforms; the protection they're meant to provide would not. See [`THREAT_MODEL.md`](THREAT_MODEL.md#commit-review-gate-opt-in) for scope and limits.

## Platform-specific code

All platform branches in the codebase:

- `vigil-aliases.sh` — `case "$(uname)" in Darwin|*BSD) … *) …` selects between BSD and util-linux `script(1)` invocation syntax.
- `profiles/default/hooks/prune-worktrees.sh` — worktree matching is by basename rather than full path to survive Windows/MSYS2 path-format mismatches.

## Known portability concerns

- **`script(1)` flag differences.** BSD `script` and util-linux `script` take incompatible arguments. Addressed via `uname` branching.
- **`bash` version.** macOS ships bash 3.2. All bash-specific features used (parameter expansion with `${var/#.../...}`, `[[ ]]`, `shopt -s nullglob`, `case` with `|` alternatives) are supported in 3.2.
- **`find -mindepth` / `-maxdepth` / `-empty`.** GNU extensions adopted by BSD `find` on macOS 10.9+, FreeBSD 8+. Untested on older systems.
- **Symlink creation.** `install.sh` uses `ln -s`. Linux and macOS: reliable. WSL2: reliable within the WSL filesystem. MSYS2/Git Bash on Windows: unreliable depending on user permissions and Windows version.
- **`init.templateDir` interaction with `vigil-install-review`.** Vigil does not touch the user-level `init.templateDir` setting, but operators who have it configured (husky-style tooling, corporate templates) will hit the gate installer's collision probe when their template-seeded hooks land in `.git/hooks/`. Resolution is manual: either remove the competing template or skip Vigil's gate on that repo. The probe's full detection list is at the top of [`scripts/vigil-install-review`](scripts/vigil-install-review) under "Collision targets."

## Reporting issues

Platform issues should be filed with: `uname -a`, `bash --version`, the exact command that failed, and its output.
