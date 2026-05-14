# ASVS_AUDIT.md

## Purpose and scope

This audit evaluates Vigil — a hardened Claude Code configuration bundle — against the [OWASP ASVS v4.0.3](https://owasp.org/www-project-application-security-verification-standard/) baseline at Level 1. The audit was performed on 2026-05-14 against repo commit `ea7a1ef`. Scope follows `ASVS_METHODOLOGY.md`: the default profile, the three shipped policies (`strict`, `dev`, `yolo`), the session wrappers and env scrub, the installer, the opt-in commit-review gate, the hook dispatcher, supporting scripts in the session pipeline, and the GitHub Actions workflows.

## Methodology reference

Audit conducted per `ASVS_METHODOLOGY.md` from the companion `asvs-generalized` repository (the methodology is maintained as a project-agnostic artifact; this audit is one instance of its application). All verdicts follow that document's classification scheme (Pass / Partial / N/A / Finding / Documented gap), severity calibration (blocker / warning / nit), and citation discipline. Each Pass cites `file:line` or a specific `THREAT_MODEL.md` section; each Finding cites the exact line(s) with the issue; each Documented gap cites the threat-model section that explicitly accepts the gap.

---

## V1 Architecture, Design and Threat Modeling

ASVS v4.0.3 V1 has no Level 1 controls — the chapter is entirely L2/L3. Per methodology, L2 notes are added where they change a verdict materially. No L2 controls were promoted to verdict status; instead, Vigil's architectural posture is captured through positive observations.

### Findings

None.

### Positive findings

- **V1-P1** | **Defense-in-depth credential protection.** Evidence: `profiles/default/settings.local.template.json:3-57`, `scripts/filter-sandbox-denies.py:59-100`, `THREAT_MODEL.md` "Mitigations by layer". Three independent layers — permission-layer Read/Write/Edit denies, sandbox `denyRead`/`denyWrite`, and the env-scrub allowlist in `vigil-aliases.sh` — each cover a different channel (in-process tools, subprocess access, environment-variable interpolation) for the same credential paths.
- **V1-P2** | **Hook dispatcher installed outside the profile directory.** Evidence: `install.sh:158-164`, `scripts/vigil-hook:1-26`. The `vigil-hook` dispatcher is `sudo install`-ed to `/usr/local/bin/vigil-hook` with root ownership, so a profile-confined attacker cannot replace it. The override path (`VIGIL_HOOK_INSTALL_DIR` plus `VIGIL_UNSAFE_SKIP_SUDO=1`) requires two coordinated env vars to disengage, preventing accidental single-variable bypass.
- **V1-P3** | **Agent-gate workflow enforces pre-commit review.** Evidence: `.claude/agents/architect.md`, `.claude/agents/code-reviewer.md`, `CLAUDE.md` "Agent-gate workflow". Non-trivial changes pass through a planning agent (no code) and a mandatory review agent (commit gate). This is a process-layer defense against unreviewed structural changes.
- **V1-P4** | **Threat model documents adversary classes and verification status.** Evidence: `THREAT_MODEL.md:15-47`, `THREAT_MODEL.md:164-179`. The four-adversary framing (inattentive operator → buggy agent → prompt-injected agent → malicious agent) is paired with a verification-status section listing concrete tests with dates and outcomes. The "honest headline" at line 155 explicitly disclaims protection against a determined adversary.
- **V1-P5** | **Sandbox `excludedCommands` carve-out documented with explicit blast radius.** Evidence: `THREAT_MODEL.md:69-70`, `profiles/default/settings.json:9-15`. The carve-out for `git commit` / `git tag` (so signing reaches the host `ssh-agent`) is paired with a note that hook subprocesses fired by those commands inherit host-level access. The trade-off is named, not hidden.

---

## V4 Access Control

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V4.1.1 | Pass | `scripts/vigil-hook:108-161`, `scripts/vigil-hook:166-204`, `profiles/default/settings.json:11-30` | Access controls live at trusted layers: sandbox (OS-level bubblewrap/Seatbelt), `PreToolUse` hook validators that return exit code 2 (hard deny), and permission deny lists. Client-side submission alone cannot succeed. |
| V4.1.2 | Pass | `scripts/vigil-hook:166-204` | `validate-settings-write` hard-blocks `Write`/`Edit`/`MultiEdit` calls targeting `~/.claude/settings.json`, `~/.claude/settings.local.json`, and `~/.claude/keybindings.json`. The user cannot rewrite the access-control rules through the same agent the rules govern. |
| V4.1.3 | Pass | `profiles/default/settings.json:11-30, 31-64`, `scripts/filter-sandbox-denies.py:59-100` | Least privilege: `defaultMode: plan` requires explicit approval per action, sandbox writes confined to `~/.cache/uv/`, `allowedDomains: []` denies all network, permission deny list blocks `rm`/`sudo`/destructive git/network fetchers/SSH-family/language runtimes. |
| V4.1.5 | Pass | `scripts/vigil-hook:111-114, 169-172` | Hook validators fail open only on parse failure of the harness event itself (an out-of-band condition); validators fail to a `deny` decision for any matched-tool/matched-path tuple. |
| V4.2.1 | Partial | `scripts/vigil-hook:108-161`, `THREAT_MODEL.md:135` | Cross-project memory-write IDOR analog is mitigated by `validate-memory-write` comparing the file path's slug against the session CWD's slug. Same-project memory-write poisoning is *inherent* to the auto-memory feature existing — the threat model accepts this gap explicitly. |
| V4.2.2 | N/A | No HTTP request surface; CSRF does not apply to a local CLI configuration bundle. | — |
| V4.3.1 | N/A | No multi-user administrative interface; Vigil is a single-operator local-machine tool. The strict-default plan mode serves as operator-level review, not MFA. | — |
| V4.3.2 | Pass | `scripts/filter-sandbox-denies.py:59-100`, `profiles/default/settings.json:31-64` | Sensitive paths are masked via sandbox `denyRead`; permission layer denies `ls` and similar exploration tools when not elevated to `dev`/`yolo`. |

### Findings

None at L1.

### Positive findings

- **V4-P1** | **Settings-write protection is hard-enforced at the hook layer, not the permission prompt.** Evidence: `scripts/vigil-hook:166-204`, `profiles/default/settings.json:90-91`. A `PreToolUse` validator returns exit code 2 (hard deny) for any in-process write to the core settings files. The block cannot be overridden by the operator approving a prompt — even under `bypassPermissions`. The integrity of the access-control rules themselves is therefore covered by a separate layer from the rules they enforce.
- **V4-P2** | **Explicit unsafe mode is named, scoped, and ships as a separate policy.** Evidence: `policies/yolo.json`, `THREAT_MODEL.md:162`. The `yolo` policy exists as a clearly-labeled artifact requiring explicit invocation; the threat model names the safe-use envelope ("throwaway work on throwaway data"). The two retained denies (`rm`, `sudo`) prevent catastrophic loss even under `bypassPermissions`.

---

## V5 Validation, Sanitization and Encoding

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V5.1.1 | N/A | No HTTP request handling. | — |
| V5.1.2 | N/A | No mass-assignment surface. | — |
| V5.1.3 | Pass | `scripts/vigil-review.py:172`, `vigil-aliases.sh:85` | Allow-list validation enforced via fixed-width regex on the session ID (`^[0-9]{8}-[0-9]{6}$`) and a character class on the active policy name (`^[a-zA-Z0-9_-]+$`). |
| V5.1.4 | Pass | `scripts/filter-sandbox-denies.py:103-115`, `profiles/default/settings.json` | Sandbox deny lists are evaluated against `Path.is_file()` / `Path.is_dir()` / `is_symlink()` predicates before being written into `settings.json`; the type check fails closed if a target doesn't exist or has the wrong type. |
| V5.1.5 | N/A | No HTTP URL redirect surface. | — |
| V5.2.1 | N/A | No HTML output. | — |
| V5.2.2 | Pass | `scripts/vigil-review.py:55-94` | Untrusted strings (commit messages, diffs in the review gate) are length-bounded and pass through a multi-pass sanitizer before being displayed. |
| V5.2.3 | N/A | No mail surface. | — |
| V5.2.4 | Pass | `scripts/vigil-aliases.sh`, `scripts/vigil-install-review`, `scripts/vigil-review.py`, `scripts/vigil-hook` | No `eval()` or shell-substituted-from-string execution. Subprocess calls use list args throughout; `signing.env` is sourced via the shell `.` builtin, not `eval`. |
| V5.2.5 | Pass | `vigil-aliases.sh:55-61, 85`, `THREAT_MODEL.md` (env-scrub layer), `README.md` (Optional: commit signing) | Policy-name interpolation into the session-marker JSON is validated by regex before substitution. `signing.env` is shell-sourced; the operator-controlled trust assumption is now documented in three places (inline comment, threat model, operator setup instructions), aligning the file's trust boundary with `~/.bashrc`. |
| V5.2.6 | N/A | Sandbox `allowedDomains: []` blocks outbound network entirely; no SSRF initiator exists. | — |
| V5.2.7 | N/A | No SVG processing. | — |
| V5.2.8 | N/A | No Markdown / XSL template engine on user input. | — |
| V5.3.1–V5.3.7 | N/A | No HTML / JS / URL / header / DB output context. | — |
| V5.3.8 | Pass | `scripts/vigil-review.py:128, 202`, `scripts/vigil-install-review:91, 141, 270`, `vigil-aliases.sh:131` | All subprocess invocations use list args with `shell=False`. `script(1)` invocation in the wrapper uses `printf '%q'` for shell-escaping of the inner command. |
| V5.3.9–V5.3.10 | N/A | No file-inclusion or XPath/XML parsing surface. | — |
| V5.5.1 | Pass | `scripts/vigil-install-review:215-268`, `scripts/hooks/pre-push:59-72` | The serialized review-gate state at `.git/review-gate/.manifest` is SHA-256 hashed; the pre-push hook verifies the hash before trusting the contents. |
| V5.5.2 | N/A | No XML parsing surface. | — |
| V5.5.3 | Pass | `scripts/vigil-hook:113, 171`, `scripts/filter-sandbox-denies.py:162` | JSON inputs (hook event payloads, settings parsing) use `json.load()` with explicit `JSONDecodeError` handling. No pickle or `repr()`-based deserialization. |
| V5.5.4 | Pass | `scripts/vigil-hook`, `scripts/filter-sandbox-denies.py` | JSON parsing via `json.load()` throughout; no `eval()`. |

### Findings

None remaining. **V5-F1** (nit) was resolved 2026-05-14 via documentation: the operator-trust assumption for `signing.env` is now named in `vigil-aliases.sh:55-61` (inline comment), `THREAT_MODEL.md` (env-scrub layer), and `README.md` (Optional: commit signing). See *Post-audit updates*.

### Positive findings

- **V5-P1** | **Paranoid terminal sanitizer.** Evidence: `scripts/vigil-review.py:30-94`. The review-gate sanitizer strips ANSI CSI/OSC/DCS/2-byte/short, C0 controls (`\x00-\x08\x0b-\x1f`), C1 controls (`-`), BIDI marks (`‎‏‪-‮⁦-⁩؜᠎`), and zero-width joiners (`​‌‍﻿`). The review output is written directly to stdout (no pager re-interpretation). Each sanitizer is a regex, so the layering is auditable.
- **V5-P2** | **Subprocess discipline.** Evidence: cross-script. Every subprocess call uses list args with `shell=False`. The single `printf '%q'`-quoted use case (`vigil-aliases.sh:131`) wraps an internal command, not user input.
- **V5-P3** | **Session-ID format is restricted enough to defeat glob and path-traversal attacks.** Evidence: `scripts/vigil-review.py:172, 194`. The session ID is parsed as `^[0-9]{8}-[0-9]{6}$`, and the file-glob site uses `glob.escape` as an additional defense layer.

---

## V6 Stored Cryptography

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V6.2.1 | Pass | `scripts/hooks/pre-push:46-78`, `scripts/vigil-install-review:215-268` | The manifest verification path fails closed: missing manifest, missing hashed file, or hash mismatch all abort the push with an explicit error message. No silent-bypass code paths exist. |

### Findings

None.

### Positive findings

- **V6-P1** | **Atomic manifest updates with `.prev` retention.** Evidence: `scripts/vigil-install-review:237-268`. The new manifest is written via `os.replace`; the previous manifest is preserved as `.manifest.prev` for post-incident review. This is a small but well-considered detail — losing the manifest to a partial write would force re-install rather than silent failure.
- **V6-P2** | **Scope of integrity protection is bounded and explicit.** Evidence: `scripts/hooks/pre-push:54-58` (comment). The pre-push hook does not self-hash (correctly; self-hashing is theatre); the manifest covers the other gate files plus `vigil-review.py`, whose integrity is load-bearing for the gate's value. The rationale is recorded inline so a future maintainer doesn't "fix" it.

---

## V7 Error Handling and Logging

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V7.1.1 | Pass | `profiles/default/settings.local.template.json:3-57`, `scripts/filter-sandbox-denies.py:59-100`, `vigil-aliases.sh:31-49` | Credential paths (`~/.ssh/`, `~/.aws/`, `~/.kube/`, `~/.docker/`, `~/.config/gh/`, `~/.netrc`) are denied at the permission layer, masked by the sandbox at the subprocess layer, and credential env vars are scrubbed before Claude inherits them. Credentials specifically cannot reach the session transcript because the agent cannot read them. |
| V7.1.2 | Pass | (same as V7.1.1) | The "sensitive data" set defined by the threat model — credentials, agent-forwarding sockets, command-history paths — is covered by the credential-path deny list. Project-internal data appearing in transcripts is by design and is documented as a residual risk (see `THREAT_MODEL.md:128-136`). |
| V7.4.1 | N/A | No user-facing application error UI; hook errors emit to stderr only. | — |

### Findings

None.

### Positive findings

- **V7-P1** | **Env-scrub allowlist is precise and operator-extensible.** Evidence: `vigil-aliases.sh:31-49, 79-83`. The wrapper unsets all env vars not on a curated allowlist (`PATH`, `HOME`, locale, SSH agent socket, GPG, XDG, editor, display, `CLAUDE_CONFIG_DIR`, plus `LC_*` and `GIT_*` by prefix). Credential-shaped vars (`AWS_*`, `GITHUB_*`, `ANTHROPIC_API_KEY`, `NPM_TOKEN`, `*_SECRET`, `*_PASSWORD`) are scrubbed. The allowlist is extensible from the operator's `~/.bashrc` without modifying Vigil itself.
- **V7-P2** | **Sensible retention defaults with a live-session floor.** Evidence: `scripts/prune-logs.py`. Defaults of 180 days age and 2 GB cap are well-balanced for post-incident review; the 10-minute floor for in-progress sessions prevents `SessionStart` from pruning logs of a currently-running peer session.

---

## V10 Malicious Code

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V10.3.1 | Documented gap | `THREAT_MODEL.md:11, 108, 116` | The installer trusts the operator's `git clone` of Vigil over HTTPS; there is no signature verification of the cloned source. The threat model lists cryptographic-manifest signing via Sigstore/cosign under "Not currently covered" (line 108) and "compromised Claude Code binary, supply chain" under out-of-scope (line 116). |
| V10.3.2 | Pass | `scripts/vigil-install-review:215-268`, `scripts/hooks/pre-push:46-78`, `install.sh:158-164` | Hook integrity protected by SHA-256 manifest; `vigil-hook` installed via sudo for tamper-resistance against profile-confined attackers. Install-time refusal-if-exists in `install.sh` prevents silent overwrite of an existing install. |
| V10.3.3 | N/A | No DNS or domain management surface. | — |

### Findings

None remaining. **V10-F1** (warning) was resolved 2026-05-14: `.github/workflows/ci.yml` now pins `actions/checkout` to `11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2) and `actions/setup-python` to `0b93645e9fea7318ecaed2b359559ac225c90a2b` (v5.3.0), matching the SHA-plus-trailing-comment pattern from `release-please.yml:16`. See *Post-audit updates*.

### Positive findings

- **V10-P1** | **Manifest scope is justified inline.** Evidence: `scripts/hooks/pre-push:54-58` (comment). The reason `pre-push` does not self-hash, and the reason `vigil-review.py` is in the manifest, are recorded next to the code. This protects the design rationale from being lost in cleanup.
- **V10-P2** | **`vigil-hook` sudo-install is a strong tamper barrier.** Evidence: `install.sh:158-164`. Profile-level write access (which a prompt-injected agent might achieve within its sandboxed scope) is insufficient to replace the dispatcher.
- **V10-P3** | **Collision probe in `vigil-install-review` refuses rather than chains.** Evidence: `scripts/vigil-install-review:137-192`. Pre-existing hook managers (husky, pre-commit, lefthook, overcommit) are detected at install time and the installer aborts with a named-error message rather than silently overwriting or trying to compose.
- **V10-P4** | **ShellCheck and Bandit in CI.** Evidence: `.github/workflows/ci.yml:26-55`. ShellCheck runs against every production shell script; Bandit and Ruff run against the Python scripts. Common shell-injection and Python-anti-pattern classes are caught at every commit.

---

## V12 Files and Resources

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V12.1.1 | N/A | No file-upload surface. | — |
| V12.3.1 | Pass | `install.sh:104-210`, `scripts/filter-sandbox-denies.py:118-135` | Paths used at install time are macro-expanded (`{{HOME}}`, `{{CWD}}`) to absolute paths and validated for type before being written into the sandbox config. No user-supplied filename is passed verbatim to filesystem APIs. |
| V12.3.2 | Pass | `scripts/filter-sandbox-denies.py:103-115` | Filename metadata in deny-list entries is validated by `Path.is_file()` / `Path.is_dir()` / `is_symlink()` predicates; entries that don't pass the type check are dropped from the generated config. |
| V12.3.3 | Pass | `scripts/filter-sandbox-denies.py:59-100` | No RFI/SSRF surface (sandbox `allowedDomains: []` denies all outbound). Credential and metadata paths are explicitly denied. |
| V12.3.4 | N/A | No file-download surface. | — |
| V12.3.5 | Pass | All subprocess calls use list args, never shell-string concatenation. | (See V5.3.8.) |
| V12.4.1 | N/A | No upload or web-root concept. | — |
| V12.4.2 | N/A | No upload surface; no antivirus integration needed. | — |
| V12.5.1 | N/A | No web server. | — |
| V12.5.2 | N/A | No web server. | — |
| V12.6.1 | Pass | `profiles/default/settings.json:20-21` | `allowedDomains: []` enforces a deny-all SSRF posture at the sandbox layer. |

### Findings

None.

### Positive findings

- **V12-P1** | **Sandbox deny-list evaluation fails closed on path-type mismatch.** Evidence: `scripts/filter-sandbox-denies.py:103-115`. Entries that don't pass type validation (e.g., a path is a symlink when the rule expected a regular file) are dropped from the generated `settings.json` rather than written through. The fail-closed behavior prevents silently-misconfigured deny rules.
- **V12-P2** | **`{{CWD}}` anchors git-metadata protection to install-time repo root.** Evidence: `scripts/filter-sandbox-denies.py:78-79`, `THREAT_MODEL.md:65`. The protection is documented as session-start-bound (mid-session `cd` is not retroactively covered), and the documentation lives next to the implementation.

---

## V14 Configuration

| Control | Verdict | Evidence | Rationale |
|---|---|---|---|
| V14.2.1 | Pass | `.github/dependabot.yml` | Dependabot is configured for GitHub Actions on a weekly schedule. |
| V14.2.2 | Pass | `profiles/default/settings.json`, `policies/{strict,dev,yolo}.template.json` | Shipped configuration is minimal: default profile, one permissive profile (unused at L1 scope), three policies, no debug toggles. |
| V14.2.3 | Pass | `.github/workflows/ci.yml:18, 29, 46-47`, `.github/workflows/release-please.yml:16` | The SRI analog for GitHub Actions is full-SHA pinning. All third-party action references in both workflows now use `<sha> # vX.Y.Z` form. (See *Post-audit updates*; previously cross-referenced V10-F1, now resolved.) |
| V14.3.2 | N/A | No production debug surface; Vigil is a configuration bundle, not a runtime. The `failIfUnavailable: true` / `enableWeakerNestedSandbox: false` settings reflect secure-by-default posture rather than debug-mode toggles. | — |
| V14.3.3 | N/A | No HTTP response surface. | — |
| V14.4.1–V14.4.7 | N/A | No HTTP server / no HTTP responses. | — |
| V14.5.1 | N/A | No HTTP server. | — |
| V14.5.2 | N/A | No authentication surface. | — |
| V14.5.3 | N/A | No CORS surface. | — |

### Findings

None remaining at L1. The SHA-pinning gap (V14.2.3) was resolved 2026-05-14 alongside V10-F1; see *Post-audit updates*.

### Positive findings

- **V14-P1** | **Secure-by-default sandbox configuration across all profiles.** Evidence: `profiles/default/settings.json:6-25`. `failIfUnavailable: true` prevents silent fallback to unsandboxed; `autoAllowBashIfSandboxed: true` avoids a separate Bash allowlist; `allowedDomains: []` is consistently strict across `default`, `dev`, and `yolo`.
- **V14-P2** | **Installer refuses to clobber an existing install.** Evidence: `install.sh:70-114`. There is no `--force` flag; the installer checks specific Vigil-owned destinations and aborts if any already exist. The pattern is explicit no-force discipline rather than soft-defaulting.

---

## Non-applicable chapters

| Chapter | Rationale for N/A |
|---|---|
| **V2 Authentication** | Vigil has no authentication surface; it is a local-only configuration bundle running under the operator's shell. |
| **V3 Session Management** | No application sessions beyond the `script(1)` transcript, which is an audit artifact and not a session token. |
| **V8 Data Protection** | No application data at rest; session transcripts are operator artifacts whose logging properties are covered under V7. |
| **V9 Communication** | Sandbox denies all outbound network (`allowedDomains: []`) by default; no application-initiated communication to protect. |
| **V11 Business Logic** | No business logic; Vigil is a permissions and sandbox configuration. |
| **V13 API and Web Service** | No API surface. |

---

## Findings summary

No open findings as of the most recent post-audit update (2026-05-14). Resolved findings are retained for reference in *Post-audit updates*.

| ID | Severity | Chapter | Title | Status |
|---|---|---|---|---|
| V5-F1 | nit | V5 | `signing.env` sourced without content validation | Resolved 2026-05-14 (documentation) |
| V10-F1 | warning | V10 / V14 | GitHub-owned actions in `ci.yml` pinned by major version, not full SHA | Resolved 2026-05-14 (SHA pinning) |

---

## Residual gaps vs. threat model

| Control | Gap | Threat-model section accepting it |
|---|---|---|
| V4.2.1 | Same-project auto-memory poisoning is inherent to the feature existing; the cross-project case is mitigated by `validate-memory-write` but the same-project case is not closeable without disabling auto-memory. | `THREAT_MODEL.md:135` ("inherent to the feature existing and cannot be closed without disabling auto-memory") |
| V10.3.1 | Installer source trust is delegated to the operator's choice to `git clone` from a trusted GitHub URL; no signature verification of the cloned source. | `THREAT_MODEL.md:108` ("Cryptographic manifest signing via Sigstore / cosign … plausible future work"); `THREAT_MODEL.md:116` ("compromised Claude Code binary … out of scope entirely") |

No audit finding requires the threat model to be amended at this revision.

---

## Footer

- **Audit date:** 2026-05-14
- **Vigil commit reviewed:** `ea7a1ef` ("docs(config): convert path-join recheck backlog entry to revert plan")
- **ASVS level targeted:** L1 (v4.0.3)
- **Methodology version:** `ASVS_METHODOLOGY.md` as of commit `ea7a1ef`
- **Next re-audit:** when `THREAT_MODEL.md`, `profiles/default/settings.json`, `scripts/filter-sandbox-denies.py`, `scripts/vigil-review.py`, `scripts/vigil-install-review`, `scripts/hooks/pre-push`, or `.github/workflows/` change materially. A full re-audit is warranted for a major-version release; for point fixes, revisit only the affected chapter(s) and update the relevant rows in place with a dated note here.

---

## Post-audit updates

### 2026-05-14 — V5-F1 resolved (documentation)

The operator-trust assumption for `~/.config/vigil/signing.env` is now documented in three locations:

- `vigil-aliases.sh:55-61` — inline comment naming the asymmetry: `signing.env` is the one file in `~/.config/vigil/` whose contents are executed rather than read as data.
- `THREAT_MODEL.md` (env-scrub layer) — paragraph framing `signing.env` as operator-controlled and shell-sourced, with the trust boundary aligned to `~/.bashrc` and OS-compromise out of scope.
- `README.md` (Optional: commit signing) — operator-facing setup instructions for the file with the trust caveat at the point of action.

Per the audit's severity calibration, the original finding was a nit (no exploit path under the existing threat model — the `~/.config/vigil/` directory is operator-controlled). The doc note formalizes the assumption rather than introducing a new defense.

### 2026-05-14 — V10-F1 resolved (SHA pinning)

`.github/workflows/ci.yml` now pins both third-party GitHub Actions to full SHA with a trailing version comment:

- `actions/checkout` → `11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2), three references at lines 18, 29, 46.
- `actions/setup-python` → `0b93645e9fea7318ecaed2b359559ac225c90a2b` (v5.3.0), one reference at line 47.

Pattern matches `release-please.yml:16`. Dependabot recognizes the trailing-comment convention and will bump SHA + version on subsequent releases. V14.2.3 (the SRI analog) and V10.3.2 are now consistently passing across both workflows.

### 2026-05-14 — citation drift note

The post-audit fixes above shifted line numbers in two files: `vigil-aliases.sh` gained 3 lines after original line 54 (the trust-note comment expansion), and `THREAT_MODEL.md` gained 2 lines in the env-scrub layer section (the new `signing.env` paragraph). Per-chapter table citations in this audit are pinned to commit `ea7a1ef` (pre-fix). Readers verifying against HEAD should add 3 to `vigil-aliases.sh` line numbers above 54 and 2 to `THREAT_MODEL.md` line numbers below the env-scrub section's `~/.bashrc` example. The next full re-audit will sweep citations to match HEAD.
