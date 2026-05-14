# Vigil session analytics — user guide

How to ingest, query, and read Vigil session data. Companion to
[`ANALYTICS.md`](ANALYTICS.md), which describes the architecture and raw log
formats. This document is task-oriented: what to type, what to expect, what
to do when something looks wrong.

## Overview

Every Vigil session writes a sidecar JSON file to `~/vigil-logs/` recording
where it ran (repo, branch, policy), when (start/end timestamps), and where
to find the corresponding Anthropic ccusage JSONL with the token totals.
v1.5 ships two scripts that turn this on-disk record into a queryable
SQLite store and a single-page HTML report:

- **`vigil-sessions.py`** walks the sidecars, sums the ccusage token buckets,
  computes per-session cost, and writes everything into a `vigil_sessions`
  table. Subsequent runs are incremental — sidecars whose mtime hasn't
  advanced are skipped.
- **`vigil-report.py`** reads the SQLite store and renders a sortable HTML
  table. No server, no external resources, opens in any browser, works
  offline.

Both are intended for local use. There is no remote upload, no telemetry,
no shared store.

## The two-command workflow

```sh
python3 ~/.config/vigil/scripts/vigil-sessions.py --db ~/vigil-logs/sessions.db
python3 ~/.config/vigil/scripts/vigil-report.py  --db ~/vigil-logs/sessions.db
```

The first command can take a few seconds the first time (it has to read
every sidecar plus every referenced ccusage JSONL); subsequent runs return
in well under a second because only changed sidecars are re-read.

The second command writes `~/vigil-reports/YYYY-MM-DD.html`. Re-running on
the same day overwrites that day's file — keep one report per day,
regenerate whenever the data changes. Open the path printed on stderr in
your browser.

**Why two commands and not one?** They have different cost profiles. Ingest
is an O(changed sidecars) write step; report is an O(rows in window) read
step. Keeping them separate means you can cron the ingest, or run the
report against an older db without re-ingesting. The
[`vigil` CLI wrapper](BACKLOG.md) (Stage 2) will absorb both behind a
single `vigil report` that ingests-then-renders for users who want it.

## Filtering the report

The report supports three filter flags:

| Flag | Default | Meaning |
|---|---|---|
| `--days N` | 7 | Include sessions started within the last N days. `0` disables. |
| `--repo NAME` | — | Restrict to a single `repo_name` (basename of session `cwd`). |
| `--limit N` | 200 | Cap row count. Hard ceiling 2000. |

Examples:

```sh
# Last 30 days, all repos:
python3 .../vigil-report.py --db ~/vigil-logs/sessions.db --days 30

# Just one repo, no recency limit:
python3 .../vigil-report.py --db ~/vigil-logs/sessions.db --repo myproject --days 0

# Save to a different path:
python3 .../vigil-report.py --db ~/vigil-logs/sessions.db --out /tmp/report.html
```

The default sort is `total_tokens DESC NULLS LAST, started_at DESC` — the
most expensive recent sessions first; sessions with no measured tokens sort
last so they don't crowd the top.

## Reading the report

Each row is one session. Columns:

- **Started (UTC)** — `started_at` from the sidecar, converted to UTC.
- **Repo** — basename of the session's `cwd`.
- **Branch** — `git_branch` at session start.
- **Policy** — active policy (`strict`, `dev`, `yolo`).
- **Duration** — `ended_at − started_at`, formatted as `1h23m45s`.
- **Total tokens** — sum of the four buckets; computed at query time.
- **Input / Cache creation / Cache read / Output** — the four token
  buckets as reported by ccusage.
- **Model** — the model(s) used in the session. Multi-model sessions
  show a comma-separated list.
- **Cost USD** — total cost summed across models, computed with the
  pricing source the ingest was run with.
- **Slug** — the human-readable session description from ccusage
  (derived from the first user message).

Click any column header to sort; click again to reverse. Sort state is
not persisted across page reloads.

If the bottom of the meta line says **"limit N reached"**, increase
`--limit` or tighten `--repo`/`--days` — you're seeing a truncated view.

## Reading the ingest summary

`vigil-sessions.py` prints a summary line to stderr after every run:

```
vigil-sessions: 142 scanned, 138 mtime-unchanged, 4 normalized, 4 passed tier1, 4 enriched
  db upserts: 4
```

The pipeline reads left-to-right:

- **scanned** — sidecars found by glob in the log directory.
- **mtime-unchanged** — sidecars whose mtime matched the stored value;
  skipped without parsing (`--db` only).
- **normalized** — sidecars successfully parsed and timestamp-validated
  past the mtime gate.
- **passed tier1** — sessions surviving the algorithmic filter
  (incomplete sessions dropped unless `--include-incomplete`; too-old
  sessions dropped unless `--max-age-days 0`; sessions without a
  `ccusage_jsonl` dropped unless `--include-no-cost`).
- **enriched** — sessions for which the ccusage JSONL was readable and
  produced at least one assistant entry. This is the row count in the
  JSON/CSV output.
- **db upserts** — rows written to SQLite (only sessions with a non-null
  `harness_session_id`).

Sub-lines appear when non-zero: `tier1 discards: <reason>=<count>` and
`tier2 discards: <count>`.

A healthy daily run on a working install reports zero or near-zero
`tier1 discards` (you have an old machine if many sessions are dropping
out as `too_old`; `--max-age-days 0` disables).

## Configuring pricing

Cost is computed from token counts via a per-model price table. Two
sources:

```sh
# Bundled offline pricing (default):
python3 .../vigil-sessions.py --db ~/vigil-logs/sessions.db

# Fresh pricing from LiteLLM's canonical dataset (same source ccusage uses):
python3 .../vigil-sessions.py --db ~/vigil-logs/sessions.db --live-pricing

# Custom pricing file (JSON; same shape as the bundled _DEFAULT_PRICING dict):
python3 .../vigil-sessions.py --db ~/vigil-logs/sessions.db --pricing prices.json
```

If a session used a model the pricing source doesn't know about, the
script prints a warning and stores partial cost (sum of models that
were priced). That row will appear in the report with a smaller-than-true
`Cost USD`.

The bundled table is refreshed manually. If you see warnings about
unknown models on a fresh ingest, run with `--live-pricing` to pull the
current table from LiteLLM.

## Where data lives

| Path | What |
|---|---|
| `~/vigil-logs/session-*.json` | Source sidecars, one per session. Append-only. |
| `~/vigil-logs/tools-*.jsonl` | Per-tool-call log. Not consumed by v1.5 ingest; reserved for future per-tool attribution (see BACKLOG). |
| `~/vigil-logs/sessions.db` | SQLite store written by `--db`. Schema in `scripts/vigil_sessions_db.py`. |
| `~/vigil-logs/vigil-sessions-runs.jsonl` | Audit log appended once per ingest run (run timestamp, counts, status). |
| `~/vigil-reports/YYYY-MM-DD.html` | Rendered report. One file per day. |

The SQLite store is intentionally placed in `~/vigil-logs/` alongside the
source sidecars. It's not pruned by `prune-logs` (which only matches
`session-*.{txt,json}`), so re-running ingest after a log prune keeps the
report stable — but rows for pruned sidecars stick around (see the
"orphaned rows" BACKLOG item for the planned cleanup).

## Common questions

**My report is empty.** Default filter is 7 days. If you have no sessions
that recent, pass `--days 0` or a larger window.

**A session shows up in stdout JSON but not in the report.** The session
has a null `harness_session_id` (zero tool calls during the session — Vigil
falls back when there's no tools log to read the UUID from). The SQLite
table's primary key can't represent it. The session is still in the
JSON/CSV output for compatibility, but won't make it into the report.

**Re-running ingest is slow even after the first run.** Check the
summary line. If `mtime-unchanged` is near 0 when you expect it to be
near the total, either (a) something is touching the sidecars between
runs (rare), or (b) the log directory was relocated and the path-keyed
mtime lookup misses every row (see BACKLOG: "Migrate mtime lookup from
sidecar_path to harness_session_id"). In case (b) the next ingest will
re-upsert and the run after that is fast again.

**Cost USD is empty or surprisingly low.** Either no pricing is
available for the model the session used (run with `--live-pricing`),
or the session ran a model name the pricing source doesn't recognize
(check the warning printed to stderr at ingest time).

**Some sidecars warn about JSONL files not existing.** The ccusage JSONL
was pruned (Claude Code's own retention) after the Vigil sidecar was
written. The sidecar points at a path that no longer exists. Run with
`--include-no-cost` to keep those sessions visible with null token data,
or accept that they're filtered out.

**The session timestamps are in local time even though it says "UTC".** The
sidecar stores `started_at` as **local time without a tz suffix** (that's
the historical contract — sessions don't know what timezone the report
viewer is in). The ingest reads them as local time and converts to UTC on
the way into SQLite. If your system timezone is not UTC, `vigil-sessions.py`
prints a warning on every run. Cross-machine sync needs timezone
normalization first — tracked in BACKLOG.

**The script asks me to run `python3 ~/.config/vigil/scripts/...` every
time. Is there a shorter form?** Not yet. The `vigil` CLI wrapper in
the Stage 2 BACKLOG will absorb both invocations behind `vigil sessions
ingest` and `vigil report`. Until then, an alias in your `.bashrc` is
the workaround:

```sh
alias vigil-ingest='python3 ~/.config/vigil/scripts/vigil-sessions.py --db ~/vigil-logs/sessions.db'
alias vigil-report='python3 ~/.config/vigil/scripts/vigil-report.py  --db ~/vigil-logs/sessions.db'
```

## Limitations and what's next

v1.5 deliberately ships the per-session aggregation surface only. Five
named follow-ups are tracked in [`BACKLOG.md`](BACKLOG.md) under
"Analytics — Vigil layer improvements":

- **Tools-JSONL ingest** — per-tool token attribution within a session.
- **Charts in `vigil-report`** — inline SVG trendlines and distributions.
- **Anomaly / spike detection** — surface high-spend sessions and retry
  storms without requiring a manual threshold.
- **Periodic cleanup of orphaned rows** — drop SQLite rows whose sidecar
  has been pruned from disk.
- **Cross-machine sync of sidecars** — timezone normalization and
  `harness_session_id` collision handling.

Three fragilities are also tracked in BACKLOG: path-keyed mtime lookup
(silently breaks on log-dir relocation), summary accounting (doesn't
account for stat-race losses), and mtime-tick collision on
coarse-resolution filesystems. None affect correctness in normal use.

## Related

- [`ANALYTICS.md`](ANALYTICS.md) — observability architecture, sidecar
  schema (with the "Stable contract" subsection), the algorithmic vs
  enrichment vs presentation tier model.
- [`README.md`](README.md) — top-level overview; the "Session analytics
  (v1.5)" section is the quickstart pointer to this guide.
- [`BACKLOG.md`](BACKLOG.md) — deferred analytics work, including the
  `vigil` CLI wrapper that will eventually subsume the
  `python3 .../script.py` invocation form.
