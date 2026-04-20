# VM_DESIGN.md

Design exploration for adding a VM-grade isolation layer beneath Claude Code's bubblewrap sandbox. This document synthesizes a design discussion, not a shipping commitment. The corresponding line item is in `BACKLOG.md` under *Stage 2 — Container- or VM-based isolation mode*, and `THREAT_MODEL.md` carries a one-line placeholder pointing here. For Vigil's current defenses see `DESIGN.md` and `THREAT_MODEL.md`; for platform support see `COMPATIBILITY.md`.

## Why consider a VM layer at all

The bubblewrap sandbox configured through the default profile is light. It is a configuration of Linux namespaces, seccomp, and bind-mounts — the guest shares the host kernel and the trust boundary is the full Linux syscall surface narrowed by a seccomp policy. `THREAT_MODEL.md` is explicit that Vigil does not defend against a sophisticated adversary capable of probing for bwrap or kernel misconfigurations.

A hypervisor-based VM (Hyper-V, KVM, etc.) closes that gap in three ways:

- **Stronger kernel boundary.** A Linux LPE exploited inside the sandbox yields host root under bwrap; the same exploit inside a VM yields only guest root. Escaping further requires a hypervisor bug, which is a dramatically smaller and better-audited surface than the Linux syscall interface.
- **Longer unattended sessions.** If a session can be reverted to a known-good snapshot, the floor for "Claude goes off the rails for an hour" is "lose this session's work," not "rebuild my home directory." Autonomy scales with how cheaply you can undo.
- **Snapshot-based reset of runaway state.** Destructive mistakes inside the VM — clobbered files, corrupted git state, broken dependency graphs — can be rolled back in one operation. No cleanup, no guessing what was touched.

## Hyper-V vs. bubblewrap at a glance

| Axis | Bubblewrap | Hyper-V |
|---|---|---|
| Isolation mechanism | Linux namespaces + seccomp-bpf + capabilities | Hardware virtualization (VT-x / AMD-V) |
| Trust boundary | Full Linux syscall surface (narrowed by seccomp) | Hypervisor interface (VMBus, hypercalls) |
| Kernel escape → | Host root | Guest root only |
| Startup cost | Milliseconds | Seconds |
| Memory overhead | Near-zero | 2–4 GB per guest |
| Filesystem | Host bind-mounts | Separate virtual disk + optional file shares |
| Host tooling reach | Trivial (same FS) | Via share protocols (SMB / virtiofs / 9p) |

The two layers are not alternatives in the usual sense: Claude Code's sandbox is built on bwrap/Seatbelt, so a VM layer would wrap Claude Code externally while bwrap continues to operate inside.

## Threat model reframe: adversarial vs. clumsy Claude

The natural first framing is "what if the agent is compromised" — adversarial Claude exfiltrating credentials, reaching the host, pushing malicious code. Hyper-V's kernel boundary answers most of that.

The real day-to-day threat is different. Clumsy Claude — honest mistakes, runaway loops, misread instructions — does its damage *inside* the VM, to the artifacts that actually matter: the working repo, uncommitted changes, local databases, sibling projects sharing the VM. The Hyper-V wall does not help with any of that, because the damage never approaches the wall.

The honest headline: a VM boundary converts host-blast-radius problems into VM-blast-radius problems. Snapshots convert VM-blast-radius problems into "lose this session's work" problems. Bwrap's in-VM denies are what keep a single session's blast radius smaller than the whole VM.

## Layered defense: VM outside, bwrap inside

Each layer protects something the other does not.

**The VM protects:**

- The Windows (or native Linux) host from the agent, adversarial or clumsy.
- Host-side credentials: SSH keys on the host, cloud-CLI configs on the host, Windows-side SSH agent.
- Cross-VM state: other WSL distros, other VMs, unrelated workspaces.
- Kernel-escape exploits.

**Bwrap inside the VM protects:**

- The working repo from writes outside its directory (sibling repos, VM-internal dotfiles).
- `.git/config` and `.git/hooks/` from tampering that would disable the commit-review gate's tamper self-check.
- In-VM credentials (injected tokens, forwarded agent sockets) from exfiltration.
- Network egress from the agent, if the VM has general internet access.

Neither layer substitutes for the other. The VM's strength is against attacks that *leave* the VM; bwrap's strength is against attacks that *stay inside* and damage what's there.

## What to loosen, what to keep

Running Claude Code inside a VM permits a looser inner sandbox for the things the VM now covers. It does not permit loosening the things the VM cannot see.

**Safe to loosen inside a VM:**

- `denyWrite` on host-oriented paths (most of `MASTER_DENY_WRITE` targets host state that no longer exists inside a fresh VM).
- Shell and runtime allow-lists — `bash`, `python`, `node`, `npm`, `docker` are all safe to run freely when the worst case is a disposable VM.
- Ask-gates and `acceptEdits`. Autonomy level is orthogonal to sandbox strictness; with a reset floor, sessions can run hours without prompting.

**Do not loosen, even inside a VM:**

- **`denyWrite` on `.git/config` and `.git/hooks/`.** The commit-review gate's pre-push hook verifies its own integrity against `.git/review-gate/.manifest`. These denies are what prevent the agent from disabling the gate. The VM does not help here: `git push` is the external action the VM permits, so an agent that can disable the gate inside the VM can ship unreviewed code out of the VM.
- **`denyRead` on credential paths inside the VM.** Anything injected into the VM for the session — short-lived git token, forwarded SSH socket, Anthropic API key — is reachable by a compromised agent if denyRead is dropped. Exfiltration is an attack that leaves the VM; the VM does not stop it.
- **`network.allowedDomains: []` (or a narrow allowlist).** Unless VM egress is firewalled at the hypervisor or host level to the same narrow set, the in-VM allowlist is the only thing preventing a POST to an attacker-controlled host.

The rule of thumb: if the attack ends with something leaving the VM — a push, an HTTP request, a credential handed out — bwrap is still the only defense. If the attack ends with damage inside the VM, the VM handles the floor (via revert) and bwrap narrows the ceiling (via write scope).

## Ergonomic unlock comes from snapshot discipline, not from loosening

The tempting story is "add a VM, loosen bwrap, get convenience." It is mostly wrong.

A long-lived VM without reset discipline is just a larger-perimeter bwrap. The agent still operates on the same repo, the same uncommitted work, the same in-VM credentials — and those are where clumsy-Claude damage actually lands. Loosening bwrap in that setting trades real protection for nominal convenience.

The ergonomic gain comes from making the VM *disposable*: snapshot-revert between sessions, or ephemeral per-session clones. The guarantee "this session cannot persist damage beyond itself" is what enables long unattended runs, not a looser syscall filter.

## Workflow shapes

Three viable shapes, in order of isolation strength.

### Snapshot-revert (single VM, serial)

1. Build a golden VM once: minimal Linux distro, Claude Code installed, Vigil installed, dev tooling, no real credentials baked in.
2. `Checkpoint-VM` produces the snapshot.
3. Per session: boot → inject ephemeral credentials → clone (or attach to shared) target repo → run Claude Code → on exit, `Restore-VMCheckpoint` to roll back.

Revert is near-instant. One session at a time. Simplest automation shape.

### Template-clone with linked VHDX (parallel sessions)

1. Same golden VM, exported as a read-only parent VHDX.
2. Per session: create a linked differencing disk referencing the parent (`New-VHD -ParentPath`) → boot new VM → inject credentials → clone repo → run → discard VM and delta disk on exit.

Multiple concurrent sessions, each fully isolated. Per-session disk cost is only the delta (100–500 MB for typical Claude Code workloads), not a full copy of the parent.

### WSL `--export` / `--import` (userland-isolated stepping stone)

`wsl --export <distro> <file.tar>` and `wsl --import <name> <install-dir> <file.tar>` provide snapshot-equivalent operations for a dedicated WSL distro. A clone of the "Claude distro" per session gives userland and filesystem isolation without standing up a real Hyper-V VM.

The caveat: all WSL2 distros share a single kernel inside one utility VM, so this is not a kernel boundary. It is a lighter-weight option for users who want reset discipline without the operational cost of a true VM, acknowledging that kernel-escape protection is not part of the deal.

## Host file sharing: the append-only logs compromise

"Bind-mount" in the Linux container sense has no direct Hyper-V analogue; the Hyper-V equivalent is a host file share, usually SMB (Windows built-in) or, in newer setups, virtiofs or 9p. A folder on the host appears as a directory inside the VM, and reads and writes inside the VM hit the host disk directly.

The core tradeoff is symmetric: **anything that survives revert is also destroyable by clumsy Claude.** These are the same property viewed from two angles — if snapshot revert cannot touch a path, neither can it undo Claude's damage to that path.

Candidates for what to share and why:

- **`~/vigil-logs/`** — the audit trail Vigil exists to produce. Without durable logs, snapshot-revert destroys the record of what happened in the session that needed reviewing. Mitigate the destruction risk via Windows ACLs that grant the VM append-only access: the VM can write new log files but cannot overwrite or delete existing ones.
- **`.git/review-gate/` (per repo)** — the commit-review gate's installed state. Host-sharing this directory lets `vigil-install-review` run once from the host and persist across VM resets, rather than requiring a re-install on every fresh clone inside the VM.
- **The working repo — do not share by default.** Sharing the repo reintroduces the in-VM-destruction problem for exactly the artifact the VM layer is supposed to protect. Prefer `git clone` inside the VM and `git push` to reach the outside world; uncommitted work is deliberately disposable, which is the forcing function for frequent commits.

The recommended default is narrow: share `~/vigil-logs/` (append-only) and the per-repo `.git/review-gate/` directory; everything else is in-VM only.

## Credential injection

Nothing sensitive belongs in the golden image. Credentials are injected per-session, short-lived where possible.

- **Git.** Fine-grained or short-lived Personal Access Tokens, scoped to the specific repo and the minimum set of operations the session needs. Injected as an env var or a `.netrc` written at boot and discarded on revert.
- **SSH.** Agent forwarding from the host into the VM (Hyper-V Enhanced Session + OpenSSH forwarding, or explicit `ssh-agent` forwarding over a VM socket). The host keeps the keys; the VM never sees them.
- **Anthropic API key.** Environment variable set at boot from a host-side secret store; scoped to a session-level budget where possible.

The goal: if the VM is compromised, the credentials visible to the attacker are time-bounded and narrowly scoped, and nothing on the host is reachable through them.

## Sizing budgets

### Disk

A dev-capable Linux VM for Claude Code:

- Base minimal distro (Ubuntu Server / Debian): 2–3 GB.
- Dev tooling (`build-essential`, git, curl, Node, Python): +600 MB – 1.5 GB.
- Claude Code + Vigil: +300–500 MB.
- Project dependencies once cloned (`node_modules` etc.): 200 MB – 2 GB per repo.
- **Realistic working size: 5–8 GB** on disk once populated.

Hyper-V's default VHDX is dynamically-sized: the file on disk grows as blocks are allocated, up to a declared cap. A 40 GB VHDX cap on a 5 GB populated VM consumes 5 GB on disk, not 40. Snapshots are differencing disks, storing only changed blocks — typically tens of MB immediately after creation, under 1 GB for a single Claude Code session.

Linked clones reuse a shared read-only parent VHDX. Parallel sessions cost only their deltas: 10 concurrent sessions against a 5 GB parent might total 6–10 GB on disk.

### RAM

RAM is the real constraint, not disk. A Linux dev VM needs 2–4 GB comfortably; Claude Code itself (Node-based) is 200–500 MB. Hyper-V Dynamic Memory can shrink idle VMs, but parallel sessions budget real RAM.

On a 16 GB laptop running Windows + WSL + browser + editor, 2–3 concurrent session-VMs is the pinch point. Snapshot-revert (one VM serial) is the right shape for constrained hardware.

## Vigil-specific gotchas

Load-bearing behaviors that the VM boundary does not automatically preserve:

- **Session transcripts.** `script(1)` captures TTY bytes to `~/vigil-logs/`. If that path is inside the VM's private disk, snapshot-revert destroys the transcript along with the session state — removing the artifact the tool was built to produce. The append-only host share for `~/vigil-logs/` closes this.
- **Commit-review gate installation.** `vigil-install-review` drops per-repo state under `.git/review-gate/` with a SHA-256 manifest. Either the golden image needs a wrapper that runs `vigil-install-review` automatically on `git clone`, or the per-repo `.git/review-gate/` directory is host-shared so the gate installs once and persists across resets.
- **`scripts/filter-sandbox-denies.py` master tuples.** `MASTER_DENY_WRITE` and `MASTER_DENY_READ` remain load-bearing inside the VM. The VM does not replace them — they cover in-VM denies (credential paths, active-repo `.git/config`, `.git/hooks/`) that the hypervisor cannot see. The installer still needs to run inside the VM, which means either baking Vigil into the golden image or running `install.sh` at VM setup time.

## Open questions

- **Host platform scope.** Target Windows Hyper-V first (the WSL2 population Vigil already assumes) or abstract over hypervisors (KVM on native Linux, Hyper-V on Windows, potentially Apple Virtualization Framework on macOS)? Scope decision drives the automation surface.
- **Policy / profile interaction.** Is VM mode a fourth policy alongside `strict` / `dev` / `yolo`, a distinct profile family (e.g., `default-vm`), or an orthogonal runtime knob selected by a different wrapper (`vigil-vm`)? Needs a decision before any code.
- **CI-mirror orthogonality.** `BACKLOG.md`'s CI-mirror Stage 2 item is about per-commit enforcement; this doc is about per-session runtime. They do not overlap and can ship independently.

## Out of scope for this document

- Actual automation of VM bring-up (PowerShell / cloud-init / image building). This doc is design; implementation is a separate task.
- Cloud / remote-agent execution. `BACKLOG.md` carries that as its own Stage 2 item. Overlaps exist (credential injection, ephemeral state) but the operational model is different enough to warrant a separate document when it's time.
