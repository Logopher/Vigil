#!/usr/bin/env python3
"""summarize-sessions.py — Per-session tool-use summary from Vigil tool logs.

Reads tools-<session>.jsonl files written by the `vigil-hook log-tool-use` hook and
outputs a JSON array with one summary row per session, joinable with sidecar
data by session_id prefix.

Usage:
    summarize-sessions.py [--log-dir DIR] [--output FILE] [--csv]

Output fields per session:
    session_id             — session ID string (from filename)
    total_calls            — number of PreToolUse entries
    by_tool                — object mapping tool name to call count
    bash_to_read           — Bash count / Read count, or null if no Reads
    error_calls            — number of PostToolUse entries with an error field
    blind_retries          — count of blind retry sequences (see definition below)
    cumulative_duration_ms — sum of duration_ms values from PostToolUse entries
                             (CPU-style aggregate, not wall-clock session time)

Blind retry definition: a PostToolUse error entry followed by a later PreToolUse
with the same tool type and matching key input (command for Bash, file path for
Read/Write/MultiEdit, file path + old_string for Edit). Text-only turns carry
no PreToolUse entries in this log and are invisible — correctly, since narrating
is not a diagnostic step.

Pending errors are tracked as a set keyed by (tool, key_input). A matching Pre
removes the error from the set; non-matching Pres leave other pending errors
undisturbed. This handles parallel in-flight calls correctly and avoids both
false positives (a parallel Pre consuming an unrelated error) and false negatives
(a second concurrent error overwriting the first in a single-slot design). The
trade-off is that delayed retries (error → unrelated work → same call again) are
also counted; for the "stuck loop" signal this is an acceptable approximation.
"""

import argparse
import csv
import io
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


def _key_input(tool: str, input_obj: dict) -> str:
    """Return the canonical key input string for retry-identity comparisons.

    Bash: command string only (cwd omitted — re-running same command in
    different cwd is still a blind retry for detection purposes).

    Edit: file path + old_string — adapted edits (same file, corrected
    old_string) are not blind retries; only an exact repeat is.

    Write/MultiEdit: file path only — retrying a write to the same target is
    the relevant signal regardless of content change.

    Other tools: full input JSON with sorted keys for stable hashing.
    """
    if tool == "Bash":
        return input_obj.get("command", "")
    if tool == "Read":
        return input_obj.get("file_path", "")
    if tool in ("Write", "MultiEdit"):
        return input_obj.get("file_path", "")
    if tool == "Edit":
        return json.dumps(
            {"file_path": input_obj.get("file_path", ""),
             "old_string": input_obj.get("old_string", "")},
            sort_keys=True,
        )
    return json.dumps(input_obj, sort_keys=True)


def _summarize(session_id: str, path: Path) -> Optional[dict]:
    """Parse one tools-*.jsonl file and return a summary dict, or None."""
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        print(f"warning: {path.name}: encoding error, skipping", file=sys.stderr)
        return None
    except OSError as exc:
        print(f"warning: {path.name}: {exc}, skipping", file=sys.stderr)
        return None

    by_tool: Dict[str, int] = {}
    error_calls = 0
    blind_retries = 0
    cumulative_duration_ms = 0

    # Keyed by tool_use_id so PostToolUse can retrieve its Pre's key_input.
    pre_inputs: Dict[str, str] = {}
    pre_tools: Dict[str, str] = {}

    # Set of (tool, key_input) pairs from PostToolUse errors that have not yet
    # been resolved by a matching PreToolUse. Using a set rather than a single
    # slot correctly handles parallel in-flight calls: concurrent errors both
    # remain pending, and a Pre that matches one does not clear the others.
    pending_errors: Set[Tuple[str, str]] = set()

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            print(f"warning: {path.name}: unparseable line, skipping: {line[:80]}",
                  file=sys.stderr)
            continue

        event = entry.get("event", "")
        tool = entry.get("tool", "")
        tid = entry.get("tool_use_id", "")

        if event == "PreToolUse":
            by_tool[tool] = by_tool.get(tool, 0) + 1
            inp = entry.get("input", {})
            key = _key_input(tool, inp)
            pre_inputs[tid] = key
            pre_tools[tid] = tool

            pair = (tool, key)
            if pair in pending_errors:
                blind_retries += 1
                pending_errors.discard(pair)

        elif event == "PostToolUse":
            dur = entry.get("duration_ms")
            if isinstance(dur, (int, float)):
                cumulative_duration_ms += dur
            if "error" in entry:
                error_calls += 1
                t = pre_tools.get(tid, tool)
                k = pre_inputs.get(tid, "")
                pending_errors.add((t, k))

    bash = by_tool.get("Bash", 0)
    read = by_tool.get("Read", 0)
    bash_to_read = round(bash / read, 3) if read > 0 else None

    return {
        "session_id":             session_id,
        "total_calls":            sum(by_tool.values()),
        "by_tool":                by_tool,
        "bash_to_read":           bash_to_read,
        "error_calls":            error_calls,
        "blind_retries":          blind_retries,
        "cumulative_duration_ms": cumulative_duration_ms,
    }


def _to_csv(rows: List[dict]) -> str:
    """Flatten summary rows to CSV. by_tool is serialized as a JSON string."""
    if not rows:
        return ""
    fields = ["session_id", "total_calls", "by_tool", "bash_to_read",
              "error_calls", "blind_retries", "cumulative_duration_ms"]
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        flat = dict(row)
        flat["by_tool"] = json.dumps(row.get("by_tool", {}))
        # bash_to_read is None when no Read calls occurred; write "null" so
        # downstream readers can distinguish it from an empty/missing field.
        if flat.get("bash_to_read") is None:
            flat["bash_to_read"] = "null"
        writer.writerow(flat)
    return buf.getvalue()


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="summarize-sessions.py",
        description="Per-session tool-use summary from Vigil tool logs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "--log-dir", default=str(Path.home() / "vigil-logs"),
        help="directory containing tools-*.jsonl files (default: ~/vigil-logs)",
    )
    ap.add_argument(
        "--output",
        help="write results to this file instead of stdout",
    )
    ap.add_argument(
        "--csv", action="store_true",
        help="output CSV instead of JSON (by_tool serialized as a JSON string)",
    )
    args = ap.parse_args(argv)

    log_dir = Path(args.log_dir).expanduser()
    if not log_dir.is_dir():
        print(f"error: log directory not found: {log_dir}", file=sys.stderr)
        return 1

    rows = []
    for path in sorted(log_dir.glob("tools-*.jsonl")):
        session_id = path.stem[len("tools-"):]
        row = _summarize(session_id, path)
        if row is not None:
            rows.append(row)

    if args.csv:
        output_text = _to_csv(rows)
    else:
        output_text = json.dumps(rows, indent=2) + "\n"

    if args.output:
        Path(args.output).write_text(output_text, encoding="utf-8")
    else:
        sys.stdout.write(output_text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
