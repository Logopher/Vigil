#!/usr/bin/env python3
"""vigil-sessions.py — General-purpose session analytics for Vigil.

Scans ~/vigil-logs/session-*.json sidecars, joins each with its ccusage JSONL
file to compute token counts and cost per session, and emits a flat report.

Usage:
    vigil-sessions.py [--log-dir DIR] [--max-age-days N]
                      [--format json|csv] [--output FILE]
                      [--pricing FILE] [--live-pricing]
                      [--runs-log FILE]
                      [--include-incomplete] [--include-no-cost]

Output (one record per session that passes filtering):
    session_id, source_file, cwd, git_branch, git_head, active_policy,
    started_at, ended_at, duration_seconds, slug,
    input_tokens, cache_creation_tokens, cache_read_tokens, output_tokens,
    models_used, cost_usd, cost_usd_by_model, harvested_at

Filtering (tier 1 — algorithmic):
    Sessions missing ended_at (incomplete) are skipped unless --include-incomplete.
    Sessions older than --max-age-days are skipped (default 90; 0 = no limit).
    Sessions with no ccusage_jsonl pointer are skipped unless --include-no-cost.

Enrichment (tier 2 — file I/O):
    For each candidate, the ccusage JSONL is read. Sessions whose JSONL is
    unreadable or contains no assistant entries are skipped unless --include-no-cost.

Run log:
    Each invocation appends one JSON line to --runs-log recording counts and
    status. The log file is created on first use.
"""

import argparse
import csv
import datetime
import io
import json
import sys
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional

# LiteLLM is the canonical upstream pricing dataset; same URL used by ccusage.
# Keys appear as both "anthropic/claude-<name>" and bare "claude-<name>".
_LITELLM_PRICING_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)

# Bundled offline fallback (USD per million tokens).
# To refresh: fetch _LITELLM_PRICING_URL, filter ^(anthropic/claude-|claude-),
# map *_cost_per_token * 1e6 to the corresponding key here.
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


def _fetch_litellm_pricing() -> Dict[str, Dict[str, float]]:
    """Fetch the LiteLLM pricing dataset; return {} on any failure."""
    try:
        with urllib.request.urlopen(_LITELLM_PRICING_URL, timeout=10) as resp:
            raw = json.load(resp)
        result: Dict[str, Dict[str, float]] = {}
        for key, entry in raw.items():
            if not (key.startswith("anthropic/claude-") or key.startswith("claude-")):
                continue
            if not isinstance(entry, dict):
                continue
            inp = entry.get("input_cost_per_token")
            out = entry.get("output_cost_per_token")
            if inp is None or out is None:
                continue
            result[key] = {
                "input":          float(inp) * 1_000_000,
                "output":         float(out) * 1_000_000,
                "cache_creation": float(entry.get("cache_creation_input_token_cost") or 0) * 1_000_000,
                "cache_read":     float(entry.get("cache_read_input_token_cost") or 0) * 1_000_000,
            }
        return result
    except Exception as exc:
        print(f"warning: could not fetch live pricing ({exc}); "
              "falling back to bundled table", file=sys.stderr)
        return {}


def _lookup_price(
    model: str,
    pricing: Dict[str, Dict[str, float]],
) -> Optional[Dict[str, float]]:
    """Return the pricing entry for model, trying bare key then anthropic/ prefix."""
    result = pricing.get(model)
    return result if result is not None else pricing.get(f"anthropic/{model}")


def _warn_if_nonzero_timezone() -> None:
    """Warn when the system timezone is not UTC (sidecar timestamps are local-naive)."""
    offset = datetime.datetime.now().astimezone().utcoffset()
    if offset and offset.total_seconds() != 0:
        print(
            f"warning: system timezone offset is {offset}; sidecar "
            "started_at is local time — age comparisons may be imprecise "
            "across DST boundaries",
            file=sys.stderr,
        )


def _sidecar_to_utc(ts: str) -> Optional[datetime.datetime]:
    """Parse YYYY-MM-DDTHH:MM:SS (local naive) and return as UTC datetime."""
    try:
        return datetime.datetime.fromisoformat(ts).astimezone(datetime.timezone.utc)
    except (ValueError, TypeError):
        return None


def _session_id_from_path(path: Path) -> str:
    """Derive session_id from sidecar filename stem (strips leading 'session-')."""
    stem = path.stem  # e.g. "session-20260507-094010-bakunawa-main"
    return stem[len("session-"):] if stem.startswith("session-") else stem


def _tier1_verdict(
    sidecar: dict,
    started_utc: Optional[datetime.datetime],
    ended_utc: Optional[datetime.datetime],
    max_age_days: Optional[int],
    include_incomplete: bool,
    include_no_cost: bool,
) -> Optional[str]:
    """Return a discard reason string, or None if the session passes tier 1."""
    if ended_utc is None and not include_incomplete:
        return "incomplete_session"
    if max_age_days is not None and started_utc is not None:
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=max_age_days)
        if started_utc < cutoff:
            return "too_old"
    if not sidecar.get("ccusage_jsonl") and not include_no_cost:
        return "no_cost_data"
    return None


def _enrich_session(
    jsonl_path: str,
    pricing: Dict[str, Dict[str, float]],
) -> Optional[dict]:
    """Read ccusage JSONL and return enrichment dict, or None if unreadable/empty.

    Returns dict with keys: slug, input_tokens, cache_creation_tokens,
    cache_read_tokens, output_tokens, models_used, cost_usd, cost_usd_by_model.
    cost_usd / cost_usd_by_model may be None when pricing is missing for a model.
    """
    try:
        text = Path(jsonl_path).read_text(errors="replace", encoding="utf-8")
    except OSError as exc:
        print(f"warning: cannot read {jsonl_path}: {exc}", file=sys.stderr)
        return None

    per_model: Dict[str, Dict[str, int]] = {}
    slug: Optional[str] = None

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
        if slug is None:
            slug = entry.get("slug") or None
        bucket = per_model.setdefault(model, {
            "input": 0, "output": 0, "cache_creation": 0, "cache_read": 0,
        })
        bucket["input"] += usage.get("input_tokens", 0)
        bucket["output"] += usage.get("output_tokens", 0)
        bucket["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
        bucket["cache_read"] += usage.get("cache_read_input_tokens", 0)

    if not per_model:
        return None

    total_input = sum(v["input"] for v in per_model.values())
    total_output = sum(v["output"] for v in per_model.values())
    total_cache_creation = sum(v["cache_creation"] for v in per_model.values())
    total_cache_read = sum(v["cache_read"] for v in per_model.values())
    models_used = ",".join(sorted(per_model.keys()))

    cost_by_model: Dict[str, float] = {}
    unknown_models: List[str] = []
    for model, counts in per_model.items():
        p = _lookup_price(model, pricing)
        if p is None:
            unknown_models.append(model)
            continue
        cost_by_model[model] = round((
            counts["input"] * p["input"]
            + counts["output"] * p["output"]
            + counts["cache_creation"] * p["cache_creation"]
            + counts["cache_read"] * p["cache_read"]
        ) / 1_000_000, 6)

    if unknown_models:
        print(
            f"warning: no pricing for model(s) {', '.join(unknown_models)}; "
            "cost_usd is a partial estimate",
            file=sys.stderr,
        )
    # cost_usd is None only when no models had pricing; otherwise it is the
    # sum of priced models (partial if some were unknown).
    cost_usd = round(sum(cost_by_model.values()), 6) if cost_by_model else None
    cost_usd_by_model = json.dumps(cost_by_model) if cost_by_model else None

    return {
        "slug": slug,
        "input_tokens": total_input,
        "cache_creation_tokens": total_cache_creation,
        "cache_read_tokens": total_cache_read,
        "output_tokens": total_output,
        "models_used": models_used,
        "cost_usd": cost_usd,
        "cost_usd_by_model": cost_usd_by_model,
    }


_OUTPUT_FIELDS = [
    "session_id", "source_file", "cwd", "git_branch", "git_head",
    "active_policy", "started_at", "ended_at", "duration_seconds", "slug",
    "input_tokens", "cache_creation_tokens", "cache_read_tokens", "output_tokens",
    "models_used", "cost_usd", "cost_usd_by_model", "harvested_at",
]


def _append_run_log(
    runs_log: Path,
    run_ts: datetime.datetime,
    sidecars_scanned: int,
    sessions_normalized: int,
    tier1_passed: int,
    tier2_passed: int,
    status: str,
    error: Optional[str],
) -> None:
    runs_log.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "run_timestamp": run_ts.isoformat(),
        "status": status,
        "sidecars_scanned": sidecars_scanned,
        "sessions_normalized": sessions_normalized,
        "tier1_passed": tier1_passed,
        "tier2_passed": tier2_passed,
        "error": error,
    }
    with runs_log.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="vigil-sessions.py",
        description="General-purpose session analytics for Vigil.",
    )
    ap.add_argument("--log-dir", default=str(Path.home() / "vigil-logs"),
                    help="directory containing session-*.json sidecars "
                         "(default: ~/vigil-logs)")
    ap.add_argument("--max-age-days", type=int, default=90,
                    help="exclude sessions older than N days (default: 90; 0 = no limit)")
    ap.add_argument("--format", choices=["json", "csv"], default="json",
                    help="output format (default: json)")
    ap.add_argument("--output",
                    help="write report to this file instead of stdout")
    pricing_group = ap.add_mutually_exclusive_group()
    pricing_group.add_argument("--pricing",
                    help="JSON file with per-model pricing in USD/MTok "
                         "(see bundled _DEFAULT_PRICING for format)")
    pricing_group.add_argument("--live-pricing", action="store_true",
                    help="fetch current pricing from LiteLLM; falls back to bundled table")
    ap.add_argument("--runs-log",
                    default=str(Path.home() / "vigil-logs" / "vigil-sessions-runs.jsonl"),
                    help="append-only run audit log (default: ~/vigil-logs/vigil-sessions-runs.jsonl)")
    ap.add_argument("--include-incomplete", action="store_true",
                    help="include sessions with no ended_at (still running or killed)")
    ap.add_argument("--include-no-cost", action="store_true",
                    help="include sessions with no ccusage_jsonl or unreadable JSONL")
    args = ap.parse_args(argv)

    run_ts = datetime.datetime.now(datetime.timezone.utc)
    max_age = args.max_age_days if args.max_age_days > 0 else None

    _warn_if_nonzero_timezone()

    pricing = _DEFAULT_PRICING
    if args.pricing:
        try:
            pricing = json.loads(Path(args.pricing).read_text(encoding="utf-8"))
        except OSError as exc:
            print(f"error: cannot read pricing file {args.pricing}: {exc}", file=sys.stderr)
            return 1
        except json.JSONDecodeError as exc:
            print(f"error: pricing file is not valid JSON: {exc}", file=sys.stderr)
            return 1
    elif args.live_pricing:
        fetched = _fetch_litellm_pricing()
        if fetched:
            pricing = fetched

    log_dir = Path(args.log_dir).expanduser()
    sidecar_paths = sorted(log_dir.glob("session-*.json"))
    sidecars_scanned = len(sidecar_paths)

    results = []
    sessions_normalized = 0
    tier1_discard: Dict[str, int] = {}
    tier2_discard = 0

    for path in sidecar_paths:
        try:
            sidecar = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"warning: skipping {path.name}: {exc}", file=sys.stderr)
            continue

        started_utc = _sidecar_to_utc(sidecar.get("started_at", ""))
        ended_utc = _sidecar_to_utc(sidecar.get("ended_at", ""))

        if started_utc is None:
            print(f"warning: skipping {path.name}: unparseable started_at", file=sys.stderr)
            continue
        sessions_normalized += 1

        discard = _tier1_verdict(
            sidecar, started_utc, ended_utc, max_age,
            args.include_incomplete, args.include_no_cost,
        )
        if discard:
            tier1_discard[discard] = tier1_discard.get(discard, 0) + 1
            continue

        # Tier 2 enrichment. Sessions with no ccusage_jsonl only reach here
        # when --include-no-cost is set (tier 1 filters the rest); the elif
        # arm would therefore be unreachable. Omit it to keep counts clean.
        enrichment: Optional[dict] = None
        jsonl_path = sidecar.get("ccusage_jsonl")
        if jsonl_path:
            enrichment = _enrich_session(jsonl_path, pricing)
            if enrichment is None and not args.include_no_cost:
                tier2_discard += 1
                continue

        duration = None
        if ended_utc is not None:
            duration = round((ended_utc - started_utc).total_seconds(), 1)

        record: dict = {
            "session_id": _session_id_from_path(path),
            "source_file": str(path),
            "cwd": sidecar.get("cwd"),
            "git_branch": sidecar.get("git_branch"),
            "git_head": sidecar.get("git_head"),
            "active_policy": sidecar.get("active_policy") or None,
            "started_at": started_utc.isoformat(),
            "ended_at": ended_utc.isoformat() if ended_utc else None,
            "duration_seconds": duration,
            "slug": None,
            "input_tokens": None,
            "cache_creation_tokens": None,
            "cache_read_tokens": None,
            "output_tokens": None,
            "models_used": None,
            "cost_usd": None,
            "cost_usd_by_model": None,
            "harvested_at": run_ts.isoformat(),
        }
        if enrichment:
            record.update(enrichment)
        results.append(record)

    tier1_passed = sessions_normalized - sum(tier1_discard.values())
    tier2_passed = len(results)

    # Build output
    error_msg: Optional[str] = None
    try:
        if args.format == "json":
            output_text = json.dumps(results, indent=2)
        else:
            buf = io.StringIO()
            writer = csv.DictWriter(buf, fieldnames=_OUTPUT_FIELDS,
                                    extrasaction="ignore", lineterminator="\n")
            writer.writeheader()
            writer.writerows(results)
            output_text = buf.getvalue()

        if args.format == "json":
            output_text += "\n"
        if args.output:
            Path(args.output).write_text(output_text, encoding="utf-8")
        else:
            sys.stdout.write(output_text)
    except Exception as exc:
        error_msg = repr(exc)
        print(f"error: output failed: {exc}", file=sys.stderr)

    # Summary to stderr
    print(
        f"vigil-sessions: {sidecars_scanned} scanned, "
        f"{sessions_normalized} normalized, "
        f"{tier1_passed} passed tier1, "
        f"{tier2_passed} enriched",
        file=sys.stderr,
    )
    if tier1_discard:
        reasons = ", ".join(f"{k}={v}" for k, v in sorted(tier1_discard.items()))
        print(f"  tier1 discards: {reasons}", file=sys.stderr)
    if tier2_discard:
        print(f"  tier2 discards: {tier2_discard}", file=sys.stderr)

    _append_run_log(
        runs_log=Path(args.runs_log).expanduser(),
        run_ts=run_ts,
        sidecars_scanned=sidecars_scanned,
        sessions_normalized=sessions_normalized,
        tier1_passed=tier1_passed,
        tier2_passed=tier2_passed,
        status="failed" if error_msg else "completed",
        error=error_msg,
    )

    return 1 if error_msg else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
