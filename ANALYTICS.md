# Observability layer: pyszz, ccusage, and Vigil session logs

Reference for Vigil's observability stack — what each input file contains, what the
algorithmic layer does with them, and where future LLM-enrichment and presentation tiers
fit. For why this reader benefits from the observability layer, see `AUDIENCE.md`.

## Layered architecture

The observability layer has four tiers:

1. **Raw logs.** `tools-<session>.jsonl` per-tool-call records; session transcripts;
   sidecar `.json` metadata; ccusage JSONL. Append-only.
2. **Algorithmic joins and aggregations.** Deterministic code: cost arithmetic from
   `message.usage`, SHA matching against `commits_during_session`, per-tool latency from
   PreToolUse / PostToolUse pairs, retry-pattern detection, blame walks via pyszz. None
   of these need an LLM.
3. **LLM enrichment.** A thin semantic layer over aggregated rows — per-session
   summaries, per-(inducing, fix) explanations, outlier commentary, cross-session pattern
   detection. Cached by stable IDs (session UUID, SHA pair) so each enrichment runs once.
   **Architectural rule: the LLM never sees raw `tools-<session>.jsonl`.** It operates on
   rows the deterministic layer has already produced.
4. **Presentation.** A static HTML report (planned). A future GUI and a unified `vigil`
   CLI sit at the same tier above the lower layers; sequencing rationale is in the
   Presentation section below.

## Raw logs

Three input streams; everything else is derived.

### ccusage JSONL

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

with `message.model` at the top level of the assistant entry. Summing across all
assistant lines per model and applying Anthropic pricing yields exact per-session cost —
bypassing ccusage's project-level aggregation, which does not break out individual main
sessions. The join script reads JSONL directly; ccusage is only needed as a pricing
reference or for project-level spot-checks.

Additional fields present on every JSONL entry: `timestamp` (ISO-8601 with milliseconds),
`sessionId` (UUID matching the filename), `gitBranch`, `slug` (human-readable session
description derived from the first message).

### Session log files

Session logs are written to `~/vigil-logs/` by `vigil-aliases.sh`. Each session produces
two files:

- `session-<timestamp>-<repo>-<branch>.txt` — ANSI-stripped transcript, prefixed with a
  `# vigil-policy: <name>` header line.
- `session-<timestamp>-<repo>-<branch>.json` — sidecar metadata (see below).

The raw `script(1)` `.log` capture is discarded after successful stripping; on strip
failure the `.log` is kept and no `.txt` is produced (the sidecar `.json` is still
written). The join script must handle this `.log`-present / `.txt`-absent state. Sessions
started outside a git repository, or in a detached HEAD state, fall back to the
timestamp-only filename format (`session-<timestamp>.{txt,json}`). Branch names are
sanitized to `[a-zA-Z0-9._-]` — slashes become hyphens (e.g. `feat/foo` → `feat-foo`).

Retention is 180 days and 2G total, enforced at session start by `vigil-hook prune-logs` (which delegates to `scripts/prune-logs.py`).

### Sidecar metadata

The `.json` sidecar is written after each session and contains:

```json
{
  "schema_version": 1,
  "cwd": "/home/grault/code/claude-config",
  "git_branch": "main",
  "git_head": "<sha-at-session-start>",
  "active_policy": "strict",
  "started_at": "2026-04-26T05:55:51",
  "ended_at": "2026-04-26T06:43:17",
  "ended_at_git_head": "<sha-at-session-end>",
  "commits_during_session": ["<sha-newest-first>", "..."],
  "harness_session_id": "<uuid>",
  "ccusage_jsonl": "/home/grault/.claude/projects/-home-grault-code-claude-config/<uuid>.jsonl"
}
```

#### Stable contract

The sidecar schema is a load-bearing external contract. Field names, types, and
semantics above are stable; consumers (including the `vigil_sessions` SQLite
materialization shipped in v1.5 and downstream reporting) rely on them.

- **`schema_version` is the contract version.** Currently `1`. Integer.
  Consumers should assert on the major-version compatibility set they
  support; unknown versions warrant skipping or warning, not silently
  continuing. Pinned proactively (rather than waiting for a breaking
  change) so additive evolution is observable to downstream consumers
  from day one.
- **Additive changes are allowed without bumping `schema_version`.** New
  nullable fields may be added; consumers must tolerate unknown keys.
- **Renames, type changes, and field removals are breaking** and require
  a `schema_version` bump.
- **Null and empty fields are part of the contract.** `commits_during_session`
  is `null` for non-git sessions; `harness_session_id` may be `null` for
  zero-tool-call sessions; `ccusage_jsonl` is an empty string when no JSONL
  could be resolved, or may point at a path that no longer exists. Consumers
  must handle each case explicitly.

`git_head` and `git_branch` are captured before the session starts, reflecting the repo
state Claude operated against. `started_at` is local time with no timezone offset,
derived from the same `VIGIL_SESSION_ID` string as the filename, so the two always match.
`ended_at` is captured immediately after `script(1)` exits, in the same local-time
format; the difference `ended_at − started_at` is session wall-clock duration.
Cross-machine or DST-boundary timestamp comparisons require awareness of the recording
machine's timezone. `ended_at_git_head` is HEAD at session end; `commits_during_session`
is the SHAs reachable from end-HEAD but not start-HEAD (newest-first), an empty list when
HEAD didn't move, and `null` for non-git sessions or when the start- or end-HEAD failed
to resolve. Together they let the SZZ join attribute an inducing commit to its session
by exact SHA lookup. `harness_session_id` is the Claude Code session UUID, recovered at
session end from the `.bridge-<vigil_session_id>` marker file under `~/vigil-logs/`
(written by the SessionStart hook once the harness assigns the UUID); it doubles
as the filename of the per-tool-call log (`~/vigil-logs/tools-<harness_session_id>.jsonl`)
and of the ccusage JSONL under `~/.claude/projects/<slug>/`, which is exactly what
`ccusage_jsonl` points at. The writer falls back to a most-recent-mtime scan over
`~/.claude/projects/` when the bridge marker is absent (e.g., SessionStart didn't fire,
or claude crashed before the hook ran) or when no JSONL with that ID exists yet (e.g.,
session ended before any assistant turn landed). The fallback can alias under concurrent
sessions but is reliable for the typical workload.

## Algorithmic layer

The deterministic tier on top of the raw logs. `scripts/run-pyszz.sh` and
`scripts/join-sessions.py` are the current entry points; both are committed and run
end-to-end.

### What pyszz produces

Given a set of bug-fixing commits, pyszz traces backward through blame history to
identify the commits that introduced each bug. B-SZZ (the baseline variant) returns all
candidate inducing commits; RA-SZZ filters out refactoring changes to reduce noise. As
refactoring accumulates, comparing B-SZZ and RA-SZZ outputs is a useful quality check: a
large gap indicates B-SZZ is over-attributing to refactoring commits.

### Integrated pipeline

`scripts/run-pyszz.sh` runs the full pipeline end-to-end: it builds the bugfix-commit
input from `git log --grep="^fix[:(]"`, invokes pyszz, caches its output by HEAD SHA, and
(with `--join`) hands off to `scripts/join-sessions.py`. The join script:

1. Reads pyszz's inducing commit SHAs with **author** timestamps (preserved by normal
   `git rebase`; may shift under `--reset-author`, `filter-branch`, or `filter-repo`).
2. Reads sidecar `.json` files from `~/vigil-logs/` — each carries `started_at`,
   `ended_at`, `git_head`, `ended_at_git_head`, `commits_during_session`,
   `harness_session_id`, `ccusage_jsonl`.
3. For each inducing commit, looks up the sidecar whose `commits_during_session` list
   contains the inducing SHA — exact session→commit attribution. Falls back to the
   sidecar with the latest `started_at` not exceeding the inducing commit's author
   timestamp when no sidecar claims the SHA (legacy sidecars or unknown sessions).
4. Opens the sidecar's `ccusage_jsonl` file; sums `message.usage` token counts from
   `type: "assistant"` lines per model; applies pricing to compute per-session cost.
   Pricing comes from `--pricing <FILE>` (a JSON table) or, with `--live-pricing`, from
   LiteLLM's canonical dataset.
5. Outputs `{inducing_sha, fix_sha, session_file, session_started_at, session_git_head,
   session_cost_usd}`.

The session→commit join is exact for sessions recorded after `commits_during_session`
landed; legacy sidecars use the timestamp fallback.

### Linkage status

The Vigil session sidecar and ccusage JSONL are linked exactly. `vigil-hook
log-tool-use` (the dispatcher invoked at every PreToolUse / PostToolUse) writes the
harness session UUID into every record of `~/vigil-logs/tools-<vigil-session-id>.jsonl`.
That UUID is the filename of the ccusage JSONL under `~/.claude/projects/<slug>/`,
which `vigil-aliases.sh` looks up directly when writing the sidecar.

The previous mtime-scan approximation remains as a fallback for sessions that made zero
tool calls (no tools log → no harness ID to read). Concurrent zero-tool sessions can
still alias under the fallback, but the mainline workload is exact.

### Role of session logs in the join

Session logs are the narrative bridge between pyszz and ccusage. pyszz identifies
inducing commits by SHA; the JSONL files measure token spend per session. Session logs
describe what was happening — what was being prompted, what context Claude was operating
in, what decisions were made. Neither pyszz nor ccusage provides this, so the `.txt`
companion is read for post-mortem analysis once the join points at a specific session.

## LLM enrichment

This tier is forward-looking. Four planned passes — per-session summary at session-end;
per-(inducing, fix) explanation; on-demand outlier explanation; cross-session pattern
detection — are enumerated in `BACKLOG.md` ("LLM enrichment layer with stable-ID
caching"). The architectural constraints (caching by stable IDs; LLM never sees raw
`tools-<session>.jsonl`) are stated in the Layered architecture section above.

## Presentation

`vigil-sessions.py --db` materializes per-session rows into a SQLite store at
`~/vigil-logs/sessions.db` (schema in `scripts/vigil_sessions_db.py`).
`vigil-report.py` reads that store and writes a single-page HTML report to
`~/vigil-reports/YYYY-MM-DD.html` — all data baked in (no server, no external
resources, opens offline), sortable columns via embedded JS. Both shipped in
v1.5. The task-oriented user guide lives at [`ANALYTICS_GUIDE.md`](ANALYTICS_GUIDE.md);
deferred follow-ups (per-tool attribution from `tools-*.jsonl`, inline SVG charts,
anomaly detection, orphan-row cleanup, cross-machine sync) are in
`BACKLOG.md` under "Analytics — Vigil layer improvements".

The static-report-first sequencing is deliberate: a one-shot HTML generator hits ~80% of
the value a GUI would provide at ~20% of the cost. If users start asking "can I drill
into this in real time?", that is the signal a GUI is justified — not before.

## Limits

- **ccusage shows project-level aggregates, not per-session totals.** Its `lastActivity`
  field is date-only. For per-session cost attribution, read the JSONL directly via the
  join script.
- **pyszz needs a corpus.** At fewer than ~10 `fix:` commits the signal is thin. It also
  requires intact local history; squashed or rewritten history breaks attribution.
- **Inducing-commit attribution is probabilistic, not causal.** The commit that last
  touched a line is the best available candidate, not a proven cause.
