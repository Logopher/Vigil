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
