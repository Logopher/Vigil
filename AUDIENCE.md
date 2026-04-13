# Audience

Who this tool is for, who it isn't, and how to tell the difference. Mismatches waste both sides' time, so the framing here is deliberately concrete.

## What you actually need

To get *value* from the tool — installing it, picking a policy, running sessions:

- **Comfort in a Linux, WSL2, or macOS terminal.** Not "I've used a terminal," but "I can debug when the terminal says no." You will run `./install.sh`, source a file from your shell rc, and occasionally read an error message.
- **Awareness that an LLM agent can do real damage if unsupervised.** Not paranoia — just the working assumption that "let an autonomous process run shell commands on my machine" is the kind of thing that warrants a deliberate posture. If "why would I block `rm`?" feels like a serious question, the value proposition doesn't land yet.
- **Willingness to re-run `install.sh` after pulling repo changes.** Edits in this repo do not affect live sessions until you reinstall. This friction is deliberate (see `DESIGN.md`), but it requires you to accept the maintenance.

To *modify* the tool — writing your own deny rules, adding a profile, tweaking sandbox config:

- **Comfort reading and editing JSON.** No GUI, no wizard. The schema is small but you need to be willing to look at it.
- **A working mental model of shell hooks and environment variables.** You don't need to write them; you need to not panic when they appear in the config.

## Sweet spot

A developer who has had a moment of *"wait, why did Claude just do that?"* — has thought about agent safety enough to want a baseline, but hasn't wanted to design one from scratch. Mid-to-senior, comfortable in the terminal, security-aware without being a specialist.

The conceptual split between profile (identity, hooks, sandbox) and policy (posture: strict / dev / yolo) clicks quickly for this reader, because they've seen the same split elsewhere — AWS profiles, browser profiles, IAM policies.

## Above the sweet spot

Senior developers who already have their own opinionated Claude config. They won't use the tool as-is; they'll fork it, steal ideas, or politely ignore it. That's a healthy audience, not a failure mode. The docs aim to be readable for a scan rather than handhold-y, so this reader doesn't feel talked down to.

## Outside current scope

Not "below the floor" — these are users for whom the tool currently doesn't fit, sometimes for fixable reasons:

- **Users without terminal proficiency.** No way around this; the tool is text-and-config.
- **Users on native Windows without WSL.** The installer is bash-only. Could change with a PowerShell port or a WSL-required notice; today it's a hard limit.
- **Users who don't know what `~/.claude/settings.json` is.** Whether they reach Claude through the desktop app, an IDE extension, or the CLI is irrelevant — the tool's value depends on understanding *what configuration is* and being willing to manage it. A user who only consumes Claude through a polished UI may never need or notice this tool.

### Common misconceptions about who the tool is *not* for

- **"macOS desktop app users."** Wrong: the desktop app uses the same Claude Code engine and reads the same `settings.json`. Our config applies to it. The relevant question is the bullet above — does the user know what `settings.json` is — not which surface they launch Claude from.
- **"People new to Claude Code."** Wrong: a safe baseline benefits new users *more*, not less. The earlier framing conflated familiarity with competence. The actual prerequisite is "knows what an autonomous agent can do," which doesn't require any specific Claude Code mileage.

## Self-use vs. friend-deploy

The repo serves two related but different audiences:

- **Self-use:** the maintainer running this on their own machines, where friction is acceptable and the install model can be terse.
- **Friend-deploy:** people the maintainer hands the repo to, who need the docs and installer to stand on their own. Friction tolerance is much lower; an unclear error message that the maintainer would shrug off becomes a "why doesn't this work?" message at 11 PM.

Most decisions in the repo lean toward self-use. The `BACKLOG.md` "Friction-removal" section names features that would shift the balance toward friend-deploy without compromising the security model.

## A practical test

A friend should be able to read `DESIGN.md` and explain, in their own words, **why `strict` is the default and when to reach for `dev`**. If they can't, the tool will bite them and they'll bounce. If they can, they'll get real value from it.
