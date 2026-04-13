# Default profile

Baseline collaboration rules for any project using this profile. Project-specific CLAUDE.md files extend or override these.

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

### Problem tracking

When you hit something unexpected during implementation — an assumption you had to make, an ambiguity resolved without input, an edge case or interaction not covered by the plan — note it in chat alongside the commit summary. At session end, print a consolidated list.

### Session hygiene

Build one unit (component, page, module) per session. Do not try to build multiple in a single prompt. After finishing a major unit, start a fresh session — the project's `CLAUDE.md` gives enough context to pick up where you left off.

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
