# Security

Vigil is a paranoid-by-default configuration for Claude Code. Its value depends on its security properties being correct, so reports of weakness are welcome and taken seriously.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** for anything you believe shouldn't be disclosed publicly before it's addressed:

1. Go to the repository's [Security tab](https://github.com/Logopher/Vigil/security).
2. Click **Report a vulnerability**.
3. Describe the issue, affected component, and reproduction steps if you have them.

This keeps the report visible only to the maintainer and the reporter until disclosure.

For issues you're comfortable discussing in public — hardening suggestions, documentation gaps, oversold claims — a regular [GitHub issue](https://github.com/Logopher/Vigil/issues) is fine and often preferred.

## What's in scope

Any report that falls under Vigil's claimed protections:

- Sandbox bypasses that let Claude Code invoke denied commands.
- Deny-list gaps that let agent actions reach destructive, network, runtime-launch, or credential paths.
- Install-time or update-time weaknesses that let a malicious or compromised Vigil install persist or escalate.
- Commit-review gate bypasses (tampering with `.git/review-gate/`, disabling the pre-push hook, evading the SHA-256 manifest check).
- Sandbox `denyWrite` evasions for `~/.gitconfig`, `.git/config`, or `.git/hooks/`.

See [`THREAT_MODEL.md`](THREAT_MODEL.md) for the enumerated threat surface and the mitigations Vigil explicitly does *not* make.

## What's out of scope

Reports that aren't actionable for Vigil, even if they're real concerns:

- Prompt-injection attacks against Claude's reasoning (Vigil constrains actions, not thoughts — see THREAT_MODEL.md).
- Compromised Claude Code binaries, compromised Anthropic-side model behavior, or vulnerabilities in tools Vigil delegates to (report those upstream).
- Issues requiring a user to explicitly authorize a risky action at a permission prompt.
- Render-layer attacks against terminal emulators or IDE UIs that Vigil doesn't itself render.

## Response expectations

Vigil is at Stage 1 of [`LIFECYCLE.md`](LIFECYCLE.md) — solo maintainer, best-effort support, no SLA. Expect:

- **Acknowledgement:** within a week for private reports; sooner when possible.
- **Triage and fix:** depends on severity and complexity. Critical issues that undermine Vigil's core claims are prioritized over feature work.
- **Disclosure:** coordinated with the reporter. Once a fix is released, the advisory is published via GitHub's security advisory mechanism.

If a report is out of scope or a duplicate, that determination will be communicated along with the reasoning.

## Stage-level caveats

- There are no signed releases, no SBOM, and no reproducibility guarantees yet. Those are Stage 4 demands (see LIFECYCLE.md) and are not in scope for the current stage.
- CI does not yet run the full test suite on external PRs (PRs are not accepted at Stage 1; see [`CONTRIBUTING.md`](CONTRIBUTING.md)).
- The maintainer is a solo developer with security intuition but not credentialed security expertise. External review is explicitly welcomed.
