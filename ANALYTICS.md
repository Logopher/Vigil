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

### JSONL schema

Each file under `~/.claude/projects/<encoded-path>/<uuid>.jsonl` is a newline-delimited
session record. The `<encoded-path>` directory name is the project's absolute path with
slashes replaced by hyphens (e.g. `/home/grault/code/claude-config` →
`-home-grault-code-claude-config`). Lines with `"type": "assistant"` carry a
`message.usage` object:

```json
{
  "input_tokens": 1,
  "cache_creation_input_tokens": 1080,
  "cache_read_input_tokens": 111016,
  "output_tokens": 101
}
```

with `message.model` at the top level of the assistant entry. Summing across all assistant
lines per model and applying Anthropic pricing yields exact per-session cost — bypassing
ccusage's project-level aggregation, which does not break out individual main sessions.
The join script reads JSONL directly; ccusage is only needed as a pricing reference or
for project-level spot-checks.

Additional fields present on every JSONL entry: `timestamp` (ISO-8601 with milliseconds),
`sessionId` (UUID matching the filename), `gitBranch`, `slug` (human-readable session
description derived from the first message).

### Limits

ccusage shows *what* was spent by project, not by individual main session. Its `lastActivity`
field is date-only. For per-session cost attribution, read the JSONL directly (see above).

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

Session logs are written to `~/vigil-logs/` by `vigil-aliases.sh`. Each session produces
two files:

- `session-<timestamp>-<repo>-<branch>.txt` — ANSI-stripped transcript, prefixed with a
  `# vigil-policy: <name>` header line.
- `session-<timestamp>-<repo>-<branch>.json` — sidecar metadata (see below).

The raw `script(1)` `.log` capture is discarded after successful stripping; on strip
failure the `.log` is kept and no `.txt` is produced (the sidecar `.json` is still written).
The join script must handle this `.log`-present / `.txt`-absent state. Sessions started
outside a git repository, or in a detached HEAD state, fall back to the timestamp-only
filename format (`session-<timestamp>.{txt,json}`). Branch names are sanitized to
`[a-zA-Z0-9._-]` — slashes become hyphens (e.g. `feat/foo` → `feat-foo`).

Retention is 180 days and 2G total, enforced at session start by `hooks/prune-logs.sh`.

### Sidecar metadata

The `.json` sidecar is written after each session and contains:

```json
{
  "cwd": "/home/grault/code/claude-config",
  "git_branch": "main",
  "git_head": "<sha-at-session-start>",
  "active_policy": "strict",
  "started_at": "2026-04-26T05:55:51",
  "ccusage_jsonl": "/home/grault/.claude/projects/-home-grault-code-claude-config/<uuid>.jsonl"
}
```

`git_head` and `git_branch` are captured before the session starts, reflecting the repo
state Claude operated against. `started_at` is local time with no timezone offset, derived from the same
`VIGIL_SESSION_ID` string as the filename, so the two always match. Cross-machine or
DST-boundary timestamp comparisons require awareness of the recording machine's timezone. `ccusage_jsonl` is the most recently modified JSONL under
`~/.claude/projects/` at session end, an approximation accurate for single-session
workloads; concurrent sessions may alias to the wrong file.

### Role in observability

Session logs are the narrative layer that bridges pyszz and ccusage. pyszz identifies
inducing commits by timestamp; the JSONL files measure token spend per session. Session logs
describe what was happening — what was being prompted, what context Claude was operating in,
what decisions were made. Neither pyszz nor ccusage provides this.

- **pyszz bridge**: An inducing commit's author timestamp can be matched against the sidecar
  `started_at` covering that window. The `.txt` companion then provides the session narrative
  for post-mortem analysis.
- **ccusage bridge**: The sidecar's `ccusage_jsonl` path points directly to the session's
  JSONL file. Token counts can be read from that file without going through ccusage's
  project-level aggregation.

### Remaining gap

No exact identifier links `~/vigil-logs/session-*` files to the corresponding
`~/.claude/projects/*.jsonl` entries. The `ccusage_jsonl` approximation closes most of the
gap, but concurrent sessions can alias. The per-tool-call logging hook
(`PreToolUse`/`PostToolUse`, tracked in `BACKLOG.md`) is the eventual fix: it can write a
session ID directly into the log. Until then, the approximation is reliable for the typical
single-session workload.

---

## Integration opportunity

All enabling dependencies are now in place. The join script (`scripts/join-sessions.py`)
connects pyszz's bug attribution to session cost:

1. Run pyszz → inducing commit SHAs with **author** timestamps (preserved by normal
   `git rebase`; may shift under `--reset-author`, `filter-branch`, or `filter-repo`).
2. Read sidecar `.json` files from `~/vigil-logs/` — each has `started_at`, `git_head`,
   `ccusage_jsonl`.
3. For each inducing commit, find the sidecar whose `started_at` is closest without
   exceeding the author timestamp (the session most likely to have produced the commit).
   `git_head` provides a stronger signal when the inducing commit was HEAD at session start.
4. Open the sidecar's `ccusage_jsonl` file; sum `message.usage` token counts from
   `type: "assistant"` lines per model; apply Anthropic pricing to get per-session cost.
5. Output: `{inducing_sha, fix_sha, session_file, session_started_at, session_git_head,
   session_cost_usd}`.

The join script needs a pricing table as an input (or a small bundled default). Prices
change occasionally; a `--pricing` JSON argument is cleaner than hardcoding. The `slug`
field present in each JSONL entry provides a human-readable session label for the output.

Once the per-tool-call hook lands and writes an explicit session ID into each log, the
timestamp join can be replaced with a direct key lookup, and the `ccusage_jsonl`
approximation can be retired.
