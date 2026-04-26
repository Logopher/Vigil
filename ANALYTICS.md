# Observability Tools: pyszz, ccusage, and Session Logs

## Framing

These three tools address the same gap: Claude Code produces outputs (commits, tokens spent)
but provides no retrospective on the quality or cost of those outputs. pyszz attributes bugs
to the commits that introduced them; ccusage surfaces the cost of sessions; session logs
record the narrative of what happened inside each session. Together they form the beginning
of an observability layer for LLM-assisted development — answering not just "what did Claude
build?" but "what did it cost, and where did it go wrong?"

---

## ccusage

### What it measures

Per-session token spend and cost, broken down by model and project. Derived from Claude
Code's local JSONL logs — no API call required for the data, only for current pricing.

### Reference data

- **Total spend to date: $1,470.** TCard accounts for 53% ($787.50), claude-config 21%
  ($309.59), Verdant 17% ($253). Subagent overhead is ~$118 (8%) — meaningful, and
  attributable to the agent-gate workflow.
- **Cache health is good.** 38:1 read-to-write ratio means prompt caching is working.
  A future drop in this ratio is an early signal that session hygiene has degraded
  (sessions running too long, context not being managed).
- **Subagent cost variance is wide** ($0.03–$15.42 per agent session). The expensive
  outliers are worth correlating against session logs — whether they produced proportionate
  work, or a large context was loaded for a trivial task.
- **Model transition is visible.** The shift from opus-4-6 to opus-4-7 shows up in the
  project entries. This makes cost-per-model comparisons possible over time as the model mix
  evolves.

### For Vigil users generally

- **Cost visibility is the entry point for users who are not security-motivated.** ccusage
  answers a question every Claude Code user has ("how much am I spending?") that Claude Code
  itself does not answer. It is a low-friction install with immediate value.
- **Cache ratio as a Vigil health signal.** If Vigil's session management (prune hooks,
  log retention) affects how users interact with long sessions, the cache ratio will reflect
  that. A healthy ratio validates the session hygiene model; a degraded one flags a problem.
- **Subagent overhead auditing.** Vigil's agent-gate workflow (architect + code-reviewer
  agents per commit) adds predictable subagent cost. ccusage makes that overhead legible,
  which is useful for users evaluating whether the gate is worth the spend.

### Limits

ccusage shows *what* was spent, not *why*. A high-cost session may reflect a large task,
mismanaged context, or the wrong model for the job — distinguishing these requires reading
the session log. ccusage is a triage signal, not a root cause.

---

## pyszz

### What it measures

Given a set of bug-fixing commits, pyszz traces backward through blame history to identify
the commits that introduced each bug. B-SZZ (the baseline variant) returns all candidate
inducing commits; RA-SZZ filters out refactoring changes to reduce noise.

### Reference data

- **15 fix commits analyzed; 11 had inducing commits.** Four returned empty because they
  fixed addition-only bugs — B-SZZ only traces deleted/modified lines.
- **Two repeat offenders.** `f10431ec` (a refactor that moved settings files) and
  `47a168b0` (the initial uninstall.sh) each induced two separate fixes. Repeat inducing
  commits are the highest-signal output: a single commit causing multiple downstream fixes
  indicates a structural problem at introduction time, not incidental errors.
- **The vigil-review commit (`d05dd055`) induced the largest fix.** The code-reviewer
  analysis confirmed this: the original commit made security claims in its docstring that
  its implementation did not fully deliver. pyszz flagged the commit; the reviewer explained
  why.
- **Cross-cutting patterns emerged.** The B-SZZ run, combined with the code-reviewer pass,
  identified four recurring failure modes: schema not verified at refactor time, `set -e`
  trap with `[[ ]] &&` idiom, stale mental model of installed layout, and tests tracking
  implementation rather than threat model.

### For Vigil users generally

- **Retrospective quality signal for AI-assisted codebases.** Vigil's target user is
  building with Claude. pyszz answers "which commits introduced the most bugs?" — a question
  that becomes more valuable as the codebase ages and the fix corpus grows.
- **Angular commit discipline pays off here.** Vigil already enforces Angular-style commits
  via the code-reviewer gate. pyszz's input generation (`git log --grep="^fix[:(]"`) works
  automatically on repos that follow this convention. Users who adopt Vigil get pyszz
  compatibility as a side effect.
- **RA-SZZ becomes relevant as refactoring increases.** B-SZZ over-attributes bugs to
  refactoring commits. As a Vigil-assisted codebase matures and accumulates more structural
  changes, comparing B-SZZ and RA-SZZ outputs becomes a meaningful quality check: a large
  difference between the two indicates significant refactoring activity that B-SZZ is
  misclassifying as bug-introducing.

### Limits

pyszz requires a corpus of fix commits — at fewer than ~10 `fix:` commits the signal is
thin. It requires a local clone with intact history; squashed or rewritten history breaks
attribution. Inducing commit attribution is probabilistic, not causal: the commit that last
touched a line is the best available candidate, not a proven cause.

---

## Session logs

### What they contain

Session logs are `script(1)` TTY captures written to `~/vigil-logs/` by `vigil-aliases.sh`.
Each session produces two files: `session-<timestamp>.log` (raw capture, full fidelity) and
`session-<timestamp>.txt` (ANSI-stripped companion produced by `scripts/strip-ansi.py`).
The `.txt` file is what `vigil-log` and `vigil-review` read.

### Role in observability

Session logs are the narrative layer that bridges pyszz and ccusage. pyszz identifies
inducing commits by timestamp; ccusage measures token spend by session. Session logs describe
what was happening during a session — what was being prompted, what context Claude was
operating in, what decisions were made. Neither pyszz nor ccusage provides this.

- **pyszz bridge**: An inducing commit's author timestamp can be matched against the session
  log covering that time window. The `.txt` companion then provides the session narrative for
  post-mortem analysis: what was being built, what prompts drove the commit, whether the
  session showed warning signs.
- **ccusage bridge**: A high-spend session identified by ccusage can be correlated to its
  session log to diagnose why the session was expensive — large file reads, long planning
  loops, multi-round subagent orchestration, or an unproductive context.

### Current gap

No explicit identifier links `~/vigil-logs/session-<timestamp>` files to the corresponding
`~/.claude/projects/*.jsonl` session entries. The join currently relies on timestamp
proximity, which is ambiguous when multiple sessions are active near the same time. The
per-tool-call logging hook (`PreToolUse`/`PostToolUse`, tracked in `BACKLOG.md`) is the
eventual fix: it can write a session ID directly into the log. The improvements below reduce
the ambiguity without depending on that hook.

### Log improvement opportunities

`vigil-aliases.sh` runs in the user's full shell environment before `script(1)` starts,
giving it access to context that hooks cannot reach (the harness strips env vars before
invoking hook subprocesses). The following improvements require only alias-wrapper changes:

- **Sidecar metadata file.** Write `session-<timestamp>.json` alongside each log pair,
  recording `cwd`, `git_branch`, `git_head`, `active_policy`, and session start timestamp.
  Gives pyszz exact repo state at session start; gives ccusage a cross-reference to the
  working directory. Eliminates fuzzy timestamp matching for JSONL correlation once
  post-session linkage is added.
- **Richer log filenames.** Append the git branch or repository basename to the session
  filename (e.g., `session-<timestamp>-claude-config-main`). Makes log browsing useful
  without opening files; enables shell-level filtering by project.
- **Policy marker in the log.** The alias wrapper knows which entry point was invoked
  (`vigil`, `vigil-dev`, `vigil-yolo`). Prepending a single line to the `.txt` companion
  before `script(1)` runs makes the log self-describing.
- **Post-session JSONL linkage.** After `script(1)` exits, scan `~/.claude/projects/` for
  the most recently modified JSONL file and record its path in the sidecar JSON. This is an
  approximation — the most recently modified file is almost always the session that just
  ended — but closes the ccusage correlation gap without requiring the per-tool-call hook
  architecture.

---

## Integration opportunity

The most valuable capability none of these tools currently provides is **session-to-commit
attribution**: connecting a bug-inducing commit (from pyszz) back to the Claude session that
produced it (from session logs) and the cost of that session (from ccusage). This answers
"which sessions introduced the most bugs?" and "what was the cost of sessions that required
the most downstream fixes?" — the combined observability question no single tool answers.

The near-term integration target, requiring no modification to either external tool:

1. Run pyszz to produce inducing commit SHAs with author timestamps.
2. Run `ccusage session --json` to produce per-session cost records with timestamps.
3. Write a join script that matches each inducing commit timestamp against the session log
   covering that window (using the sidecar `.json` metadata if present, falling back to
   filename timestamp), then pulls the session's cost from the ccusage output.

The sidecar metadata file (described above) is the enabling dependency: it makes the
timestamp join precise and adds git state, so the output is "commit X was introduced in
session Y, which cost $Z, at git HEAD W." That is the full attribution record.

Once the per-tool-call hook lands and writes an explicit session ID into each log, the
timestamp join can be replaced with a direct key lookup.
