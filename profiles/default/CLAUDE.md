# Default profile

Baseline collaboration rules for any project using this profile. Project-specific CLAUDE.md files extend or override these.

## Operational notes

Facts about this environment that are easy to mistake for problems. If you find yourself reaching for one of these, stop — the answer is below, not in the code.

### Sandbox artifacts in `git status`

If `git status` shows untracked entries that are character devices (`crw-rw-rw-`, owner `nobody:nogroup`, major/minor `1,3`), the harness has bind-mounted `/dev/null` over a path it wants to mask — typically user dotfiles, editor state, or some `.claude/` config files. They cannot be committed (git rejects character devices), they do not need a `.gitignore` entry, and they are not repository state. Do not investigate, do not try to clean them up.

### Blocked Bash commands

The Vigil profile denies a fixed set of Bash patterns at the permission layer. Attempting one prompts the user; reflexive retries waste their attention. Before reaching for the Bash tool, check whether the command falls into a denied category:

- **Destructive / privileged**: `rm`, `sudo`, `vigil-install-review` — ask the user.
- **Mutating git**: `push`, `pull`, `fetch`, `reset`, `rebase`, `merge`, `clean`, `restore`, `stash drop`, `stash pop`, `checkout --` — ask the user.
- **Network fetchers**: `curl`, `wget` — use the WebFetch tool instead.
- **Language runtimes**: `node`, `python`, `python3`, `npx` — ask the user to run it.
- **Container / orchestration**: `docker`, `kubectl`, `npm publish` — ask the user.
- **SSH / transfer family**: `ssh`, `scp`, `sftp`, `rsync`, `nc`, `ncat`, `socat`, `telnet`, `ftp` — ask the user.

Authoritative list is in `settings.template.json`. If a command isn't in any category and you're unsure, ask before invoking — don't probe by trying.

### `git -C` breaks the `git commit` / `git tag` carve-out

The sandbox carves out `git commit` and `git tag` (via `excludedCommands` in `settings.template.json`) so they can reach the signing agent outside the sandbox. The matcher is prefix-based on the command line, so `git -C <path> commit …` does not match — it runs inside the sandbox and typically fails (no access to `SSH_AUTH_SOCK` or signing keys). When you need to commit or tag from somewhere other than the current working directory, `cd` into the repo first; do not reach for `-C`.

## Collaboration rules

### Commit discipline

Each commit contains exactly one logical unit of work. Never bundle independent changes. Keep gate-passing fixes — changes made to resolve code-reviewer findings — in their own commit, separate from new feature code; bundling them obscures what the review actually caught.

When a plan has multiple steps, evaluate file overlap before starting:

- Steps that touch the same files must run in series. Commit step N before starting step N+1.
- Steps that touch entirely different files may run in parallel using isolated worktrees, each producing its own commit on its own branch. Only use worktree agents when each task is substantial enough to justify the coordination overhead; for trivial single-file edits, sequential execution in the main context is faster.

Commit as soon as a unit is complete and its gates pass. Do not defer multiple commits to the same working state — when two commits are made from the same state, their changes intertwine in ways that are hard to pick apart later.

Before committing, check that no new TODO, FIXME, or placeholder comments were introduced by the change.

### Commit message format

Angular-style conventional commits.

- Format: `<type>(<scope>): <summary>`
- One scope per commit; split if a change spans multiple scopes.
- Types: `feat`, `fix`, `refactor`, `style`, `docs`, `test`, `chore`.
- Scopes are defined per project in that project's `CLAUDE.md`.

### Decision escalation

Stop and ask before writing code if:

- The plan has an open question.
- The implementation requires choosing between multiple reasonable approaches and the plan does not specify which.
- A runtime error or type mismatch reveals that the plan's assumptions were wrong.
- The spec is ambiguous or silent on a detail that affects the output.

Do not pick an approach and mention it in passing. Describe the options and trade-offs, then wait for a decision.

### Token discipline

- Read files at given paths directly; don't hunt or re-read files already in context.
- Trim command output to what's diagnostically useful — failing lines or stack traces, not full logs.
- Prefer `Edit` over rewriting whole files.
- Skip preamble ("Let me…", "I'll now…") unless asked for reasoning.
- When the user gives a file or line, go straight there instead of exploring.
- For verbose tool work (running a test suite, grepping a large codebase, fetching long docs), delegate to a subagent via the Agent tool so only the summary returns to the main context.
- Before expensive exploratory work (codebase-wide search, multi-file refactor planning, new-feature scoping), surface the approach in plan mode first — cheaper to reject a wrong plan than to abort a wrong execution.

### Precision over umbrella terms

When listing things to audit, rotate, review, or inventory, enumerate the specific items — account logins, personal access tokens, OAuth integrations, env vars, deploy hooks, DNS, etc. — rather than using a category noun like "credentials", "secrets", or "config". Umbrella terms force the next turn to be a clarifying question; the enumeration is what's being asked for anyway.

### Problem tracking

When you hit something unexpected during implementation — an assumption you had to make, an ambiguity resolved without input, an edge case or interaction not covered by the plan — note it in chat alongside the commit summary. At session end, print a consolidated list.

### Session hygiene

Build one unit (component, page, module) per session. Do not try to build multiple in a single prompt. After finishing a major unit, start a fresh session — the project's `CLAUDE.md` gives enough context to pick up where you left off.

### Project CLAUDE.md hygiene

When a project's CLAUDE.md restates rules already in this global file, prefer thin pointers to full restatement. The project file should contain only project-specific content plus explicit overrides or extensions of the global rules (with the override stated as such). Periodically audit project CLAUDE.md files against this one for drift; drift works in both directions — new global rules not yet reflected as pointers in projects, and project restatements that have silently diverged from global. An audit pass typically cuts 20–30% of a mature project CLAUDE.md without losing any rule.

Target budget: under ~2,000 tokens. CLAUDE.md is re-read on every turn, so every line has a recurring cost. Point to files rather than inlining reference material.

### Never modify CLAUDE.md autonomously

Changes to any CLAUDE.md file require explicit developer instruction.

### Agent-gate workflow

Specialist agents ship with the default profile at `~/.claude/agents/`. Projects may define additional specialist reviewers in their own `.claude/agents/`.

| Agent | File | When to use |
|---|---|---|
| `architect` | `~/.claude/agents/architect.md` | New features, cross-component changes, any decision affecting structure |
| `code-reviewer` | `~/.claude/agents/code-reviewer.md` | After implementation, before every commit |

When project-specific reviewers (accessibility, SEO, security, etc.) exist, invoke them as applicable before committing.

For non-trivial changes:

1. Invoke `architect` — produce a written plan; do not write code yet.
2. Developer reviews and approves the plan.
3. Implement against the approved plan.
4. Invoke `code-reviewer` — resolve all findings before committing.
5. Invoke any project-specific reviewers relevant to the change.
6. Commit only after gates pass.

For small isolated fixes (single-file, no interface changes), steps 1–2 may be skipped at the developer's discretion.

### Standards for new agents

**File structure.** Agent definitions live at `.claude/agents/<name>.md` (or `~/.claude/agents/<name>.md` for profile-level agents). Each file follows a consistent shape:

1. **Title and one-line purpose.**
2. **When to invoke.** Specific triggering situations.
3. **Inputs.** What the agent expects to receive.
4. **Process** (planners) or **Review checklist** (reviewers). Numbered steps or categorized sections.
5. **Output.** What the agent returns. For reviewers, a concrete format with severity levels (blocker / warning / nit).
6. **What not to do.** Explicit boundaries — especially "do not write code" for planners, "do not rewrite the code" for reviewers.

Directive tone. Concise: the agent re-reads this file at every invocation.

**When to create a new agent.** Every project starts with two baselines: `architect` (planning, no code) and `code-reviewer` (mandatory commit gate). Resist adding more until signal appears.

Split a specialist off when:

- The generalist reviewer's checklist branches on file type or domain.
- A class of defect keeps being missed.
- Rules from one domain leak into unrelated files.
- Reference material is large and only applies to a subset of changes.
- Invocation should be conditional on specific file changes (different triggers).

Two signals together cross the threshold. One signal alone is usually premature.

**Before splitting, try folding.** Add the concern as a new numbered section in the existing reviewer. If misses continue across two or more reviews, promote to its own agent. Folding is cheap to unfold; splitting prematurely creates coordination overhead with nothing to show.

**Anti-patterns.**

- Agents that write implementation code or take actions. Agents review, plan, or advise; execution is the main agent's job.
- One agent doing both planning and review.
- Agents created for hypothetical future needs.
- Agents whose checklist overlaps 80% with another agent's.
