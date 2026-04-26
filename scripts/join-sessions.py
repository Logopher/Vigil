#!/usr/bin/env python3
"""join-sessions.py — Join pyszz bug attribution with Vigil session cost data.

Connects each pyszz-identified bug-inducing commit to the Vigil session that
most likely produced it, and computes the cost of that session from its JSONL.

Usage:
    join-sessions.py --pyszz FILE [--log-dir DIR] [--repo DIR]
                     [--pricing FILE] [--output FILE]

pyszz input: B-SZZ JSON array — each record has fix_commit_hash (string) and
inducing_commit_hash (list of strings). Produced by `python pyszz.py b_szz`.

Output: JSON array, one object per (fix, inducing) pair:
    {
        "inducing_sha":       "<sha>",
        "fix_sha":            "<sha>",
        "inducing_author_ts": "<ISO-8601 UTC> or null",
        "session_file":       "<path to .json sidecar> or null",
        "session_started_at": "<YYYY-MM-DDTHH:MM:SS> or null",
        "session_git_head":   "<sha> or null",
        "session_cost_usd":   <float> or null,
        "cost_basis":         "jsonl" | "unknown"
    }

Session matching: the sidecar with the latest started_at not exceeding the
inducing commit's author timestamp is selected. Author timestamps are stable
across normal git rebase; they may shift under --reset-author or filter-repo.

Cost computation: token counts are summed from type:assistant entries in the
session JSONL, excluding sidechain entries (isSidechain == true). Sessions
that used models absent from the pricing table will have understated costs.

Limitations:
    - started_at in sidecars is local time with no timezone offset; session
      matching is precise only when the join script runs on the same machine
      and in the same timezone as the recording sessions. A warning is printed
      when the system timezone offset is non-zero.
    - ccusage_jsonl in the sidecar is an approximation (most recently modified
      JSONL at session end); concurrent sessions may alias to the wrong file.
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Bundled default pricing table (USD per million tokens).
# Model IDs verified against real Claude Code JSONL message.model values.
# Update at https://www.anthropic.com/pricing when prices change.
_DEFAULT_PRICING: Dict[str, Dict[str, float]] = {
    "claude-opus-4-7": {
        "input": 15.0, "output": 75.0,
        "cache_creation": 18.75, "cache_read": 1.50,
    },
    "claude-opus-4-6": {
        "input": 15.0, "output": 75.0,
        "cache_creation": 18.75, "cache_read": 1.50,
    },
    "claude-sonnet-4-6": {
        "input": 3.0, "output": 15.0,
        "cache_creation": 3.75, "cache_read": 0.30,
    },
    "claude-haiku-4-5-20251001": {
        "input": 0.80, "output": 4.0,
        "cache_creation": 1.00, "cache_read": 0.08,
    },
}

# Module-level cache for git author timestamp lookups. Single-run script;
# unbounded growth is not a concern.
_author_ts_cache: Dict[str, Optional[datetime.datetime]] = {}


def _warn_if_nonzero_timezone() -> None:
    """Warn when the system timezone is not UTC.

    Sidecar started_at values are local time with no offset. If the system
    timezone is non-UTC, they are converted using the current offset, which
    may differ from the offset active when the session was recorded (e.g.
    across a DST boundary or on a different machine).
    """
    offset = datetime.datetime.now().astimezone().utcoffset()
    if offset and offset.total_seconds() != 0:
        print(
            f"warning: system timezone offset is {offset}; sidecar "
            "started_at is local time — session matching may be imprecise "
            "across DST boundaries or if sessions were recorded in a "
            "different timezone",
            file=sys.stderr,
        )


def _git_author_ts(sha: str, repo: str) -> Optional[datetime.datetime]:
    """Return author timestamp for sha as a timezone-aware UTC datetime."""
    if sha not in _author_ts_cache:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%aI", sha],
            cwd=repo, capture_output=True, text=True,
        )
        ts = None
        if result.returncode == 0 and result.stdout.strip():
            try:
                ts = datetime.datetime.fromisoformat(
                    result.stdout.strip()
                ).astimezone(datetime.timezone.utc)
            except ValueError:
                pass
        _author_ts_cache[sha] = ts
    return _author_ts_cache[sha]


def _sidecar_to_utc(started_at: str) -> Optional[datetime.datetime]:
    """Parse YYYY-MM-DDTHH:MM:SS (local, no tz) and return as UTC datetime.

    .astimezone() on a naive datetime treats it as local time and converts
    to UTC using the current system timezone.
    """
    try:
        return datetime.datetime.fromisoformat(started_at).astimezone(
            datetime.timezone.utc
        )
    except ValueError:
        return None


def _load_sidecars(log_dir: Path) -> List[dict]:
    """Load session sidecar JSON files, sorted oldest-first by started_at.

    Sidecars with unparseable timestamps are sorted to epoch (the beginning
    of the list) and are skipped by _closest_before.
    """
    sidecars = []
    for path in log_dir.glob("session-*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        data["_path"] = str(path)
        data["_utc"] = _sidecar_to_utc(data.get("started_at", ""))
        sidecars.append(data)
    sidecars.sort(key=lambda s: s["_utc"] or datetime.datetime.min.replace(
        tzinfo=datetime.timezone.utc
    ))
    return sidecars


def _closest_before(sidecars: List[dict],
                     target: datetime.datetime) -> Optional[dict]:
    """Return the latest sidecar with started_at <= target, or None.

    Scans the full list rather than breaking early, so the result is correct
    regardless of how unparseable sidecars (sorted to epoch) interleave with
    valid ones.
    """
    best = None
    for s in sidecars:
        if s["_utc"] is None:
            continue
        if s["_utc"] <= target:
            best = s
    return best


def _session_cost(
    jsonl_path: str,
    pricing: Dict[str, Dict[str, float]],
) -> Optional[float]:
    """Compute session cost by summing token usage from a JSONL file.

    Excludes sidechain entries (isSidechain is True) to avoid double-counting
    tokens from /btw and similar interactions replayed in the main context.

    Returns None if the file cannot be read or contains no assistant entries.
    Returns a float (possibly 0.0) if entries were found; cost may be
    understated if the session used models absent from the pricing table.
    """
    try:
        text = Path(jsonl_path).read_text(errors="replace", encoding="utf-8")
    except OSError:
        return None

    totals: Dict[str, Dict[str, int]] = {}
    found_entries = False
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("isSidechain") is True or entry.get("type") != "assistant":
            continue
        model = entry.get("message", {}).get("model", "")
        usage = entry.get("message", {}).get("usage", {})
        if not model or not usage:
            continue
        found_entries = True
        bucket = totals.setdefault(model, {
            "input": 0, "output": 0, "cache_creation": 0, "cache_read": 0,
        })
        bucket["input"] += usage.get("input_tokens", 0)
        bucket["output"] += usage.get("output_tokens", 0)
        bucket["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
        bucket["cache_read"] += usage.get("cache_read_input_tokens", 0)

    if not found_entries:
        return None

    cost = 0.0
    for model, counts in totals.items():
        p = pricing.get(model)
        if p is None:
            continue  # unknown model — omit rather than error
        cost += (
            counts["input"] * p["input"]
            + counts["output"] * p["output"]
            + counts["cache_creation"] * p["cache_creation"]
            + counts["cache_read"] * p["cache_read"]
        ) / 1_000_000
    return cost


def _load_pyszz(path: str) -> List[Tuple[str, str]]:
    """Return (fix_sha, inducing_sha) pairs from pyszz B-SZZ output."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        print(f"error: cannot read pyszz file {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as exc:
        print(f"error: pyszz file is not valid JSON: {exc}", file=sys.stderr)
        sys.exit(1)

    pairs = []
    for record in data:
        fix_sha = record.get("fix_commit_hash", "")
        for inducing_sha in record.get("inducing_commit_hash") or []:
            if fix_sha and inducing_sha:
                pairs.append((fix_sha, inducing_sha))
    return pairs


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="join-sessions.py",
        description="Join pyszz bug attribution with Vigil session cost data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--pyszz", required=True,
                    help="pyszz B-SZZ output JSON (array format)")
    ap.add_argument("--log-dir", default=str(Path.home() / "vigil-logs"),
                    help="directory containing session sidecar *.json files "
                         "(default: ~/vigil-logs)")
    ap.add_argument("--repo", default=None,
                    help="git repo path for author timestamp lookups "
                         "(default: current directory)")
    ap.add_argument("--pricing",
                    help="JSON file with per-model pricing in USD/MTok; "
                         "see bundled _DEFAULT_PRICING for format")
    ap.add_argument("--output",
                    help="write results to this file instead of stdout")
    args = ap.parse_args(argv)

    repo_explicit = args.repo is not None
    repo = args.repo or os.getcwd()

    _warn_if_nonzero_timezone()

    git_check = subprocess.run(
        ["git", "rev-parse", "--git-dir"],
        cwd=repo, capture_output=True,
    )
    if git_check.returncode != 0:
        if repo_explicit:
            print(f"error: {repo!r} is not a git repository", file=sys.stderr)
            return 1
        print(
            "warning: current directory is not a git repository — "
            "all author timestamps will be null",
            file=sys.stderr,
        )

    pricing = _DEFAULT_PRICING
    if args.pricing:
        try:
            pricing = json.loads(Path(args.pricing).read_text(encoding="utf-8"))
        except OSError as exc:
            print(f"error: cannot read pricing file {args.pricing}: {exc}",
                  file=sys.stderr)
            return 1
        except json.JSONDecodeError as exc:
            print(f"error: pricing file is not valid JSON: {exc}", file=sys.stderr)
            return 1

    pairs = _load_pyszz(args.pyszz)
    sidecars = _load_sidecars(Path(args.log_dir).expanduser())

    results = []
    for fix_sha, inducing_sha in pairs:
        author_ts = _git_author_ts(inducing_sha, repo)
        sidecar = _closest_before(sidecars, author_ts) if author_ts else None

        record: dict = {
            "inducing_sha":       inducing_sha,
            "fix_sha":            fix_sha,
            "inducing_author_ts": author_ts.isoformat() if author_ts else None,
            "session_file":       sidecar["_path"] if sidecar else None,
            "session_started_at": sidecar.get("started_at") if sidecar else None,
            "session_git_head":   sidecar.get("git_head") if sidecar else None,
            "session_cost_usd":   None,
            "cost_basis":         "unknown",
        }

        if sidecar and sidecar.get("ccusage_jsonl"):
            cost = _session_cost(sidecar["ccusage_jsonl"], pricing)
            if cost is not None:
                record["session_cost_usd"] = round(cost, 6)
                record["cost_basis"] = "jsonl"

        results.append(record)

    output_text = json.dumps(results, indent=2)
    if args.output:
        Path(args.output).write_text(output_text, encoding="utf-8")
    else:
        sys.stdout.write(output_text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
