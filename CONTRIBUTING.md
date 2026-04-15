# Contributing

**Short version: pull requests are not being accepted at this stage.** Feedback, bug reports, and questions are welcome as issues.

This is a deliberate posture, not an oversight. Vigil is early and opinionated, and taking contributions before the contributor-rights question (CLA vs DCO) is settled would create work that is painful to undo. This policy will be revisited as the project matures; see `LIFECYCLE.md` for the staging model.

## What to do instead

- **Found a bug, a platform mismatch, or a gap in the threat model?** Open an issue.
- **Have an idea for a feature or a policy?** Open an issue describing the use case. Please do not open a PR implementing it — it will be closed unmerged.
- **Want to use Vigil's ideas in your own config?** Fork freely under the MIT license. No attribution required beyond what the license asks.

## If this policy changes

If contributions open up later, this file will be updated with the contributor-rights mechanism (likely DCO), the review process, and the gate workflow. Until then, assume PRs will be closed.

## Standards used internally

These are documented so forks and future contributors know the shape of the project. They are not a contract with outside contributors today.

### Commit message format

Angular-style conventional commits.

- Format: `<type>(<scope>): <summary>`
- One scope per commit; split the change if it spans multiple scopes.
- Types: `feat`, `fix`, `refactor`, `style`, `docs`, `test`, `chore`.
- Scopes: `hooks`, `policies`, `profiles`, `aliases`, `config`.

### Commit discipline

- One logical unit of work per commit. Independent changes are never bundled.
- Gate-passing fixes (changes made to resolve review findings) go in their own commit, separate from new feature code.
- No new `TODO`, `FIXME`, or placeholder comments introduced by a change.

### Review gates

Non-trivial changes go through an `architect` planning pass and a `code-reviewer` pass before commit. See `.claude/agents/` for the agent definitions. Small single-file fixes may skip the architect pass.

### Public surface (semver classification)

`release-please` derives version bumps from conventional-commit types: `feat` bumps patch pre-1.0, `fix` bumps patch, `feat!` or a `BREAKING CHANGE:` footer bumps minor pre-1.0. The classifier (the commit author) needs a bright line for what counts as a breaking change. A commit is breaking when it changes any of the following:

1. **Installed path layout** — contents of `~/.claude/` placed by Vigil, the `~/.config/vigil/` tree, or the `~/vigil-logs/` filename format (`session-YYYYMMDD-HHMMSS.{log,txt}`).
2. **Shell wrapper names and argument shapes** — `vigil`, `vigil-dev`, `vigil-strict`, `vigil-yolo`, `vigil-log`, `vigil-log-prune`, `vigil-install-review`. Adding a wrapper is `feat`; renaming or removing one is breaking.
3. **Policy names** — `strict`, `dev`, `yolo`. Renaming or removing is breaking; tightening allow-lists inside a policy is `feat`; adding a new policy is `feat`.
4. **Default profile deny baseline** — *loosening* the baseline deny list is breaking (users rely on it for safety). Tightening or adding new denies is `feat`; removing a deny is breaking.
5. **Hook contract** — the `{{PROFILE_DIR}}` substitution, the `VIGIL_SESSION_ID` / `VIGIL_LOG_DIR` environment contract, and the `SessionStart` / `PreToolUse` / `PostToolUse` wiring names documented in `CLAUDE.md`.
6. **Installer contracts** — `install.sh`, `update.sh`, and `uninstall.sh` CLI flags; the refuse-to-clobber behavior; which files each script touches.
7. **Commit-review gate** — `vigil-install-review`, the `.git/review-gate/` layout in consuming repos, and the pre-push hook's SHA-256 manifest check.

*Not* public surface (changes here are never breaking): internal script names under `scripts/`, hook-script filenames inside a profile's `hooks/` directory, exact wording of prompts or error messages, log-line formats excluding the filename format above, and any variable name that isn't in the list above.

When unsure, err toward `feat!` rather than `feat`. An over-classified bump is cosmetic; an under-classified one silently breaks friends at Stage 1 and strangers at Stage 2.
