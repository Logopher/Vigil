# GENERALIZATION.md

Vigil's expected generalization beyond Claude Code: candidate shapes, the load-bearing design distinction, and the discipline that kept each option open until shape #1 was selected by the Dashboard-into-Vigil-v2 consolidation. See "2026-05-13 calibration" below.

This document is design exploration, parallel to `VM_DESIGN.md`. Today's Vigil is Claude-Code-specific; this doc named the shape question and the agent-agnostic / agent-specific distinction. The 2026-05-13 calibration records how the question was answered. The three-shapes survey is retained because the agent-agnostic / agent-specific design discipline still governs how every Vigil abstraction is built — regardless of which shape was selected.

## Why generalization is expected

Claude API token budgets are pushing some work toward local LLMs and away from cloud Claude. Once a Vigil operator runs more than one agent substrate — say, Claude Code for some work and an Ollama-hosted local agent for the rest — Vigil's Claude-Code-specific framing stops fitting cleanly. The pressure is real: it surfaced as an anticipated trajectory during the 2026-05-11 strategic-analysis session (plan archived at `~/.claude/plans/consider-bakunawa-code-bakunawa-vigil-piped-wind.md`).

Generalization is *anticipated*, not committed. No work is in flight today, and no agent beyond Claude Code is supported. The point of writing this down now is to keep future Vigil work compatible with multiple endpoints — agent-agnostic where the pattern is genuinely agent-agnostic, agent-specific where it isn't.

## The load-bearing distinction: agent-agnostic vs agent-specific

Every Vigil component lives on one side of this axis. Generalization design hinges on which side.

**Agent-agnostic — transfers cleanly to any future agent substrate:**

- The commit-review gate, top to bottom. Paranoid sanitizer (ANSI CSI/OSC/DCS/short, C0 + C1 controls, BIDI marks, zero-width characters), SHA-256 manifest self-check on the installed hook, collision detection refusing to overwrite husky / pre-commit / lefthook installations. The sanitizer doesn't care which agent authored the commit. The manifest self-check doesn't care which agent could have tampered.
- Policy / profile vocabulary. The strict / dev / yolo posture concept and the profile / policy separation are conceptual primitives that apply to any agent that takes typed actions.
- Session logging pattern via `script(1)`. The wrapper-and-transcript pattern is shell-level, not agent-level.
- Threat-model framing. The four-adversary model (inattentive operator / buggy agent / prompt-injected agent / malicious agent) generalizes; what changes per agent is which mitigations apply at which layer.
- The `vigil-hook` dispatcher architecture and the validate-memory-write / validate-settings-write hook subcommands. The validation logic is agent-agnostic; what's agent-specific is which paths matter.

**Agent-specific — does not transfer; each new substrate needs its own:**

- Sandbox tuning. Bubblewrap on Linux/WSL2 and Seatbelt on macOS are configured against Claude Code's specific sandbox model and process boundary. A local-LLM agent might run as a subprocess with no sandbox configuration of its own; an OpenCode agent has a different sandbox surface.
- Deny-list contents. The list of `Bash(rm:*)` / `Bash(sudo:*)` / `Read(~/.ssh/**)` patterns is matched against Claude Code's permission-string format. A future agent might use a different action-naming convention.
- Install discipline against `~/.claude/`. The directory layout, runtime state, and `~/.claude/projects/<slug>/memory/` convention are Claude Code's. A different agent has a different home directory layout.
- The `excludedCommands` carve-out for git-signing. Commands matched by `sandbox.excludedCommands` run outside bubblewrap entirely; this is Claude Code's specific way of resolving the SSH-agent-socket problem under sandbox isolation. A different agent might handle agent forwarding differently.

## Three candidate shapes

When generalization activates, Vigil could grow in one of three shapes. The right answer depends on how many agent substrates are in scope and how aligned their abstractions are.

### 1. Single agent-agnostic Vigil

One project that targets multiple agents internally. The substrate-specific tuning becomes a configuration choice (e.g., `vigil --agent claude-code` vs `vigil --agent ollama-local`); the agent-agnostic pieces stay shared across all targets.

- **Strengths:** one project to maintain, one community, one release pipeline. Cross-agent comparisons (cost, telemetry shape) are uniform.
- **Weaknesses:** abstraction tax — each new agent adds branching in shared code paths. Agent-specific tuning becomes harder to audit because it's tangled with the agent-agnostic core. Risk of dissolving the specificity that makes today's Vigil legible.
- **Best fit:** when the agents being targeted share enough structural similarity that the agent-specific surface stays narrow.

### 2. Sibling tools per agent

A family of projects: Vigil for Claude Code, Vigil-Ollama for local LLMs, Vigil-OpenCode for OpenCode, and so on. Shared design conventions and possibly shared library code, but each project is its own deployment surface.

- **Strengths:** preserves per-agent specificity. Each project can take advantage of its agent's specific sandbox model, deny-list grammar, and runtime conventions without compromise. Audit-friendly: a security review of Vigil-Ollama doesn't have to wade through Claude-Code-specific carve-outs.
- **Weaknesses:** fragments maintainer effort across N projects. Cross-agent UX consistency requires explicit coordination. Risk of drift — Vigil-A and Vigil-B start out aligned and slowly diverge as each absorbs its agent's specific needs.
- **Best fit:** when each agent's substrate is structurally different enough that shared internals are more cost than benefit, and the user populations don't overlap much.

### 3. Methodology + concrete forks

Vigil-the-pattern (a design document plus shared agent-agnostic libraries — sanitizer, policy vocabulary, threat-model framing) is the durable artifact. Each concrete deployment is a fork that inherits the design and reuses the libraries but is owned by whoever ships it for whichever agent.

- **Strengths:** ecosystem reach without single-maintainer bottleneck. The methodology spreads to agents the original maintainer never touched. Aligns with the broader substrate-agnostic-platforms methodology framing already in use across the four-project family.
- **Weaknesses:** weaker quality guarantee — forks may be partial, stale, or wrong. "Vigil" as a brand becomes hard to enforce. No single point of accountability for a security-conscious user.
- **Best fit:** when the methodology has matured enough to teach and the maintainer wants reach without the per-agent maintenance burden.

## Discipline that keeps the choice open

Until generalization actually happens, two practices keep all three shapes viable:

1. **Split new Vigil work along the agent-agnostic / agent-specific axis explicitly.** Agent-agnostic abstractions land in shared layers — `scripts/vigil-review.py`, `vigil-hook`, the policy/profile vocabulary, the threat-model doc, the session-logging pattern. Agent-specific tuning stays in concrete profile bundles — the `profiles/default/settings.json` deny list, the bubblewrap configuration, the carve-outs. When adding a new abstraction, name which side it belongs on; if it lives on both, it probably belongs on neither and needs splitting.

2. **Don't ship a generalized Vigil without at least two concrete profile bundles to anchor it.** A single concrete bundle hides which design choices are agent-agnostic vs agent-specific — the design defaults to "whatever Claude Code happens to need." Two bundles force the distinction to be explicit. The threshold for shipping shape #1 (single agent-agnostic Vigil) or shape #2 (sibling tools per agent) is the second substrate actually being in use, not anticipated.

## What activates the decision

The decision should be deferred until the operator is actually running multiple agent substrates. The likely triggers, in roughly decreasing probability:

- Token-budget pressure on Claude pushes a substantial fraction of work to a local LLM (Ollama, llama.cpp, vLLM). The local-LLM agent runs without Vigil's protections today; once it's load-bearing for routine work, the gap matters.
- A specific agent (OpenCode being the closest example; see `BACKLOG.md` and `COMPATIBILITY.md`) becomes worth supporting because friends or stranger users are running it and asking.
- A commercial framing for Vigil emerges (hypothetical, not committed — see `vigil-path.md`'s monetization inventory and `BACKLOG.md`'s Stage 2 entries) that requires multi-agent coverage to be credible.

Until one of these triggers fires, the right move is to keep every new Vigil abstraction defensible on both axes — agent-agnostic where genuinely agent-agnostic, agent-specific where genuinely Claude-Code-specific.

## 2026-05-13 calibration: shape resolved toward #1 via Dashboard consolidation

The three-shapes analysis above was written treating the shape question as open. A subsequent architectural commitment — the Dashboard codebase moving into the Vigil repository as a long-lived `v2` branch (`~/code/dashboard/BACKLOG.md:23`; criteria in `~/planning/dashboard-path.md` "v2-merge gate") — effectively resolves the shape question toward shape #1 (single agent-agnostic Vigil). Under v2:

- The Dashboard substrate (Tauri 2 + React 19 + Rust) provides the agent-agnostic runtime: policy engine (Dashboard's `README.md:56` names this "Policy engine (internal name: Vigil)"), LLM proxy, capability enforcement, sanitized render path, observability via `SourceAdapter` ingest.
- **Current Vigil becomes the first concrete agent profile bundle — the Claude Code adapter.** Sandbox tuning, deny-list contents, `~/.claude/` install discipline, and the `excludedCommands` carve-out for git-signing stay packaged as the Claude-Code-specific profile.
- **A local-LLM adapter is the planned second concrete bundle** — required to satisfy both the v2-merge gate (Claude + local LLM side-by-side dogfooded use) and the discipline-rule of "two concrete bundles before shipping a generalized Vigil" stated in the section above.
- The agent-agnostic / agent-specific split (this doc's load-bearing distinction) is preserved across the consolidation rather than dissolved by it.

What this means for the rest of this document: the "three candidate shapes" framing stays as historical context — it records the design space and the reasoning that selected shape #1. The "what activates the decision" triggers above are partly retrospective; the local-LLM-adoption trigger (#1 in that list) was effectively the one that fired.

What still defers: the v2-merge gate itself, the local-LLM adapter implementation, and any decisions about whether further adapters (OpenCode, Codex, Goose) get profile bundles or stay as documentation-only fallbacks. The OpenCode `~/.claude/CLAUDE.md` fallback already in `COMPATIBILITY.md` continues to be the lightest-touch option for adjacent runtimes.

Cross-references for the calibration:
- `~/code/dashboard/BACKLOG.md:23` — v2-branch-into-Vigil-repo commitment.
- `~/planning/dashboard-path.md` "v2-merge gate" — full criteria and dependencies.
- `~/planning/vigil-path.md` 2026-05-12 addendum, "v2 consolidation" subsection — strategic framing.
- `~/.claude/projects/-home-grault/memory/vigil_v2_dashboard_consolidation.md` — durable record (when the cross-project memory hook is unblocked).

## Cross-references

- `THREAT_MODEL.md` — the four-adversary model that generalizes; specifically the third-defense-layer caveat (Claude-specific model-level refusals) that does *not* generalize.
- `COMPATIBILITY.md` — current platform and agent support; OpenCode compatibility footnote is the closest existing acknowledgment of multi-agent scope.
- `BACKLOG.md` — Stage 2 items including the OpenCode permission-layer port and Sigstore manifest signing, both of which would intersect generalization.
- `LIFECYCLE.md` — OSS-project stages; generalization-shape decision is orthogonal to lifecycle stage but realistically activates around Stage 2-3.
- `~/planning/vigil-path.md` — Vigil strategic positioning (the 2026-05-12 addendum captures generalization context).
- `~/.claude/projects/-home-grault/memory/local_llm_adoption_and_vigil_generalization.md` — durable record of the generalization trajectory.

---

*GENERALIZATION.md — Vigil — Rev 2 (2026-05-13)*
