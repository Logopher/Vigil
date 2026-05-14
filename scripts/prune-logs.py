#!/usr/bin/env python3
"""Prune Vigil session logs under ~/vigil-logs by age and total size.

Usage:
    prune-logs.py [--log-dir DIR] [--older-than DURATION]
                  [--max-total-size SIZE] [--dry-run] [--quiet]

Targets files matching session-YYYYMMDD-HHMMSS[-<repo>-<branch>].{log,txt,json}
— the scheme produced by vigil-aliases.sh. Files outside that pattern
are never touched, so pointing --log-dir at the wrong directory is safe.

Defaults: --log-dir ~/vigil-logs, --older-than 180d. --max-total-size
is only applied when explicitly set.

A 10-minute mtime floor protects the currently-running session from
being pruned by its own SessionStart hook.

Also sweeps ~/.config/vigil/sessions/ for files older than 7 days —
covers leaked wrapper-<pid>.json and bridged <harness_session_id>.json
files when SessionEnd or the wrapper EXIT trap did not run (e.g.,
claude crashed mid-session).
"""
import argparse
import re
import sys
import time
from pathlib import Path

SESSION_RE = re.compile(r'^session-(\d{8}-\d{6}[^.]*)\.(log|txt|json)$')
LIVE_FLOOR_SECONDS = 10 * 60

# Session-handoff files live in ~/.config/vigil/sessions/ and are normally
# cleaned by the wrapper's EXIT trap (wrapper-<pid>.json) or the SessionEnd
# hook (<harness_session_id>.json). Stale files beyond this threshold are
# leaked from a crashed wrapper or harness. The regex is anchored to the
# two known shapes — wrapper-<pid>.json and a v4-shaped harness UUID —
# so an operator-placed diagnostic file in that directory is left alone.
SESSIONS_DIR_MAX_AGE_SECONDS = 7 * 86400
SESSIONS_DIR_PATTERN = re.compile(
    r'^(wrapper-\d+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.json$'
)


def parse_duration(s: str) -> float:
    m = re.fullmatch(r'(\d+)([dh]?)', s)
    if not m:
        raise argparse.ArgumentTypeError(f"bad duration: {s!r} (try 90d or 12h)")
    n, unit = int(m.group(1)), m.group(2) or 'd'
    return n * (86400 if unit == 'd' else 3600)


def parse_size(s: str) -> int:
    m = re.fullmatch(r'(\d+)([KMG]?)', s)
    if not m:
        raise argparse.ArgumentTypeError(f"bad size: {s!r} (try 2G or 500M)")
    n, unit = int(m.group(1)), m.group(2)
    mult = {'': 1, 'K': 1024, 'M': 1024**2, 'G': 1024**3}[unit]
    return n * mult


def parse_stamp(stamp: str) -> float:
    # Filenames may carry a suffix after the timestamp (e.g. -repo-branch);
    # slice to the fixed 15-char YYYYMMDD-HHMMSS portion before parsing.
    return time.mktime(time.strptime(stamp[:15], '%Y%m%d-%H%M%S'))


def collect_pairs(log_dir: Path):
    """Return list of (stamp, age_seconds, [(path, size), ...]) sorted oldest-first."""
    now = time.time()
    groups: dict[str, list[tuple[Path, int]]] = {}
    stamps: dict[str, float] = {}
    for entry in log_dir.iterdir():
        if not entry.is_file():
            continue
        m = SESSION_RE.match(entry.name)
        if not m:
            continue
        stamp = m.group(1)
        try:
            st = entry.stat()
        except OSError:
            continue
        try:
            ts = parse_stamp(stamp)
        except ValueError:
            ts = st.st_mtime
        # Live-session floor uses mtime (ts from filename is session-start time).
        if now - st.st_mtime < LIVE_FLOOR_SECONDS:
            continue
        groups.setdefault(stamp, []).append((entry, st.st_size))
        stamps[stamp] = ts
    pairs = [(stamp, now - stamps[stamp], groups[stamp]) for stamp in groups]
    pairs.sort(key=lambda p: stamps[p[0]])  # oldest-first
    return pairs


def fmt_size(n: int) -> str:
    for unit in ('B', 'K', 'M', 'G'):
        if n < 1024 or unit == 'G':
            return f"{n:.1f}{unit}" if unit != 'B' else f"{n}B"
        n /= 1024
    return f"{n:.1f}G"


def delete_pair(files, dry_run: bool) -> int:
    total = 0
    for path, size in files:
        total += size
        if not dry_run:
            try:
                path.unlink()
            except OSError as e:
                print(f"prune-logs: failed to delete {path}: {e}", file=sys.stderr)
    return total


def prune_sessions_dir(sessions_dir: Path, dry_run: bool, quiet: bool) -> None:
    """Remove stale handoff files from ~/.config/vigil/sessions/.

    Only touches files matching SESSIONS_DIR_PATTERN — anything else in
    that directory is left alone. Silent no-op when the directory does
    not exist (fresh install before any vigil session has launched).
    """
    if not sessions_dir.is_dir():
        return
    now = time.time()
    removed = 0
    for entry in sessions_dir.iterdir():
        if not entry.is_file():
            continue
        if not SESSIONS_DIR_PATTERN.match(entry.name):
            continue
        try:
            st = entry.stat()
        except OSError:
            continue
        if now - st.st_mtime < SESSIONS_DIR_MAX_AGE_SECONDS:
            continue
        if dry_run:
            removed += 1
            continue
        try:
            entry.unlink()
            removed += 1
        except OSError as e:
            print(f"prune-logs: failed to delete {entry}: {e}", file=sys.stderr)
    if removed and not quiet:
        verb = "would prune" if dry_run else "pruned"
        print(f"prune-logs: {verb} {removed} stale session handoff file(s) "
              f"from {sessions_dir}")


def main(argv):
    ap = argparse.ArgumentParser(description="Prune Vigil session logs.")
    ap.add_argument('--log-dir', default=str(Path.home() / 'vigil-logs'))
    ap.add_argument('--older-than', type=parse_duration, default=parse_duration('180d'))
    ap.add_argument('--max-total-size', type=parse_size, default=None)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args(argv[1:])

    sessions_dir = Path.home() / '.config' / 'vigil' / 'sessions'
    prune_sessions_dir(sessions_dir, args.dry_run, args.quiet)

    log_dir = Path(args.log_dir).expanduser()
    if not log_dir.is_dir():
        # No logs yet = nothing to do; don't treat as error.
        if not args.quiet:
            print(f"prune-logs: {log_dir} does not exist, nothing to do")
        return 0

    pairs = collect_pairs(log_dir)

    pruned_count = 0
    pruned_bytes = 0
    kept: list = []

    for stamp, age, files in pairs:
        if age > args.older_than:
            pruned_bytes += delete_pair(files, args.dry_run)
            pruned_count += 1
        else:
            kept.append((stamp, files))

    if args.max_total_size is not None:
        total = sum(size for _, files in kept for _, size in files)
        while kept and total > args.max_total_size:
            stamp, files = kept.pop(0)  # oldest-first
            freed = delete_pair(files, args.dry_run)
            pruned_bytes += freed
            pruned_count += 1
            total -= freed

    if not args.quiet:
        verb = "would prune" if args.dry_run else "pruned"
        cap = fmt_size(args.max_total_size) if args.max_total_size is not None else "none"
        age_days = args.older_than / 86400
        print(f"prune-logs: {verb} {pruned_count} session(s) ({fmt_size(pruned_bytes)}); "
              f"age>{age_days:g}d cap={cap}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
