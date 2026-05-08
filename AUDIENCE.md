# Audience

Who this tool is for, who it isn't, and how to tell the difference. Mismatches waste both sides' time, so the framing here is deliberately concrete.

## What you actually need

To get *value* from the tool — installing it, picking a policy, running sessions:

- **Comfort in a Linux, WSL2, or macOS terminal.** Not "I've used a terminal," but "I can debug when the terminal says no." You will run `./install.sh`, source a file from your shell rc, and occasionally read an error message.
- **Awareness that an LLM agent can do real damage if unsupervised.** Not paranoia — just the working assumption that "let an autonomous process run shell commands on my machine" is the kind of thing that warrants a deliberate posture. If "why would I block `rm`?" feels like a serious question, the value proposition doesn't land yet.
- **Willingness to re-run `install.sh` after pulling repo changes.** Edits in this repo do not affect live sessions until you reinstall. This friction is deliberate (see `DESIGN.md`), but it requires you to accept the maintenance.

To *modify* the tool — writing your own deny rules, adding a profile, tweaking sandbox config:

- **Comfort reading and editing JSON.** No GUI, no wizard. The schema is small but you need to be willing to look at it.
- **A working mental model of shell hooks and environment variables.** The hooks themselves are thin bash shims; they delegate to Python scripts in `scripts/`. You don't need to write either, but extending a hook means reading both.
- **Basic Python literacy for hook extensions.** The logging and validation hooks are standalone Python scripts that read JSON from stdin and write JSON to stdout. Reading them is straightforward; modifying them requires comfort with Python's `json` and `os.path` modules.

## Sweet spot

A developer who has had a moment of *"wait, why did Claude just do that?"* — has thought about agent safety enough to want a baseline, but hasn't wanted to design one from scratch. Mid-to-senior, comfortable in the terminal, security-aware without being a specialist.

The conceptual split between profile (identity, hooks, sandbox) and policy (posture: strict / dev / yolo) clicks quickly for this reader, because they've seen the same split elsewhere — AWS profiles, browser profiles, IAM policies.

A second variant of the sweet-spot reader: a developer who wants to *understand* what their AI agent is doing across sessions, not just constrain it. Claude Code emits outputs (commits, tokens spent) but no retrospective on their quality or cost. Vigil's observability layer fills that gap — session transcripts and sidecar JSON record what happened, a per-call tool-use log (`tools-<session>.jsonl`) records every tool invocation with its input and response, and `scripts/join-sessions.py` joins those logs with Claude Code's JSONL usage data for cost attribution. `ANALYTICS.md` documents the full picture for this reader.

The entry point for users who are *not* security-motivated is cost visibility. ccusage answers a question many Claude Code users have — "how much am I spending?" — that Claude Code itself does not. Three signals derive from there:

- **Cache ratio as session-hygiene health.** A degrading prompt-cache read-to-write ratio is an early indicator that sessions are running too long or context isn't being managed, before any obvious failure surfaces.
- **Subagent overhead audit.** Vigil's agent-gate workflow (architect plans, code-reviewer reviews each commit) adds predictable subagent cost; the join script attributes that cost so users can evaluate whether the gate is worth the spend.
- **pyszz as retrospective quality signal.** As the codebase accumulates `fix:` commits, pyszz traces each back to the commit that introduced the bug. Repeat-offender commits — one introducing commit causing multiple downstream fixes — point at structural problems rather than incidental error.

The pyszz signal depends on commit discipline. Its input pipeline keys off Angular-style commits (`fix(scope): …`), which the project's `code-reviewer` gate enforces — users following the agent-gate workflow get pyszz compatibility for free.

## Above the sweet spot

Senior developers who already have their own opinionated Claude config. They won't use the tool as-is; they'll fork it, steal ideas, or politely ignore it. That's a healthy audience, not a failure mode. The docs aim to be readable for a scan rather than handhold-y, so this reader doesn't feel talked down to.

## Outside current scope

Not "below the floor" — these are users for whom the tool currently doesn't fit, sometimes for fixable reasons:

- **Users without terminal proficiency.** No way around this; the tool is text-and-config.
- **Users on native Windows without WSL.** The installer is bash-only. Could change with a PowerShell port or a WSL-required notice; today it's a hard limit.
- **Users who don't know what `~/.claude/settings.json` is.** The tool's value depends on understanding *what configuration is* and being willing to manage it. A user who only consumes Claude through a polished UI may never need or notice this tool.

### Common misconceptions about who the tool is *not* for

- **"macOS desktop app users."** Partially in scope, for reasons that have nothing to do with macOS. The desktop app reads `~/.claude/settings.json`, so the profile baseline (deny list, hooks, sandbox) applies regardless of OS or launch surface. The posture layer — session wrappers, policy selection, session logging — activates only from an interactive terminal, so desktop-app users (on any OS) don't get it. macOS bash users get the same posture layer Linux and WSL2 bash users get; the discriminator is terminal vs. desktop app, not macOS vs. other platforms.
- **"People new to Claude Code."** Wrong: a safe baseline benefits new users *more*, not less. The earlier framing conflated familiarity with competence. The actual prerequisite is "knows what an autonomous agent can do," which doesn't require any specific Claude Code mileage.

## Self-use vs. friend-deploy

The repo serves two related but different audiences:

- **Self-use:** the maintainer running this on their own machines, where friction is acceptable and the install model can be terse.
- **Friend-deploy:** people the maintainer hands the repo to, who need the docs and installer to stand on their own. Friction tolerance is much lower; an unclear error message that the maintainer would shrug off becomes a "why doesn't this work?" message at 11 PM.

Most decisions in the repo lean toward self-use. The `BACKLOG.md` "Friction-removal" section names features that would shift the balance toward friend-deploy without compromising the security model.

## A practical test

A friend should be able to read `DESIGN.md` and explain, in their own words, **why `strict` is the default and when to reach for `dev`**. If they can't, the tool will bite them and they'll bounce. If they can, they'll get real value from it.
