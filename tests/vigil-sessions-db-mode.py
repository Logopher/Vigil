#!/usr/bin/env python3
"""Integration tests for scripts/vigil-sessions.py --db mode.

Drives vigil-sessions.py as a subprocess against a fixture log directory
containing sidecars + ccusage JSONL files, then queries the resulting SQLite
to verify rows materialized correctly, the upsert is idempotent across
re-runs, the mtime checkpoint skips unchanged sidecars, and a malformed
sidecar in the input does not block the rest.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parent.parent
SCRIPT = REPO_DIR / 'scripts' / 'vigil-sessions.py'


failed = 0


def section(title: str) -> None:
    print(f'\n-- {title} --')


def check(name: str, cond: bool, detail: str = '') -> None:
    global failed
    if cond:
        if os.environ.get('VIGIL_TESTS_VERBOSE') == '1':
            print(f'  PASS  {name}')
    else:
        print(f'  FAIL  {name} {detail}', file=sys.stderr)
        failed += 1


def write_ccusage(path: Path, model: str, slug: str) -> None:
    """Minimal valid ccusage JSONL: one user line carrying slug, one assistant
    line carrying model + usage counts."""
    lines = [
        {"type": "user", "slug": slug, "timestamp": "2026-04-26T05:55:51Z"},
        {
            "type": "assistant",
            "slug": slug,
            "message": {
                "model": model,
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 50,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 30,
                },
            },
        },
    ]
    path.write_text(''.join(json.dumps(line) + '\n' for line in lines), encoding='utf-8')


def write_sidecar(path: Path, sidecar: dict) -> None:
    path.write_text(json.dumps(sidecar), encoding='utf-8')


def run_script(log_dir: Path, db_path: Path, runs_log: Path) -> subprocess.CompletedProcess:
    """Invoke vigil-sessions.py --db against a fixture log dir.

    --max-age-days 0 disables age filtering so fixed-date fixtures aren't
    rejected as too old. --include-no-cost is intentionally NOT passed: every
    fixture sidecar here carries a valid ccusage_jsonl path, so the default
    tier-1 filter is the right one to exercise.
    """
    return subprocess.run(
        [
            sys.executable, str(SCRIPT),
            '--log-dir', str(log_dir),
            '--db', str(db_path),
            '--runs-log', str(runs_log),
            '--max-age-days', '0',
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def make_sidecar(harness_id: str, cwd: str, jsonl_path: Path) -> dict:
    return {
        "schema_version": 1,
        "cwd": cwd,
        "git_branch": "main",
        "git_head": "abc123",
        "active_policy": "strict",
        "started_at": "2026-04-26T05:55:51",
        "ended_at": "2026-04-26T06:43:17",
        "ended_at_git_head": "def456",
        "commits_during_session": ["def456", "abc123"],
        "harness_session_id": harness_id,
        "ccusage_jsonl": str(jsonl_path),
    }


with tempfile.TemporaryDirectory() as td:
    td_path = Path(td)
    log_dir = td_path / 'vigil-logs'
    log_dir.mkdir()
    db_path = td_path / 'sessions.db'
    runs_log = td_path / 'runs.jsonl'

    jsonl_a = td_path / 'ccusage-a.jsonl'
    write_ccusage(jsonl_a, model='claude-sonnet-4-6', slug='session a')
    sidecar_a = log_dir / 'session-20260426-055551-myrepo-main.json'
    write_sidecar(sidecar_a, make_sidecar('uuid-a', '/home/x/code/myrepo', jsonl_a))

    section('First run upserts the fixture row')
    proc = run_script(log_dir, db_path, runs_log)
    check('script exited 0', proc.returncode == 0,
          f'stderr: {proc.stderr}')

    conn = sqlite3.connect(str(db_path))
    rows = conn.execute(
        "SELECT harness_session_id, cwd, repo_name, git_branch, "
        "active_policy, slug, models_used, input_tokens, total_tokens "
        "FROM vigil_sessions"
    ).fetchall()
    check('exactly one row materialized', len(rows) == 1, f'(got {len(rows)})')
    if rows:
        r = rows[0]
        check('harness_session_id stored', r[0] == 'uuid-a', f'(got {r[0]!r})')
        check('cwd stored', r[1] == '/home/x/code/myrepo', f'(got {r[1]!r})')
        check('repo_name derived from cwd', r[2] == 'myrepo', f'(got {r[2]!r})')
        check('git_branch stored', r[3] == 'main', f'(got {r[3]!r})')
        check('active_policy stored', r[4] == 'strict', f'(got {r[4]!r})')
        check('slug captured from ccusage', r[5] == 'session a', f'(got {r[5]!r})')
        check('model stored as comma list', r[6] == 'claude-sonnet-4-6',
              f'(got {r[6]!r})')
        check('input_tokens summed', r[7] == 100, f'(got {r[7]})')
        # total_tokens generated column: 100 + 50 + 20 + 30 = 200
        check('total_tokens generated correctly', r[8] == 200, f'(got {r[8]})')
    conn.close()

    section('Second run with unchanged mtime is a no-op')
    proc = run_script(log_dir, db_path, runs_log)
    check('script exited 0', proc.returncode == 0,
          f'stderr: {proc.stderr}')
    check('stderr reports mtime-unchanged', '1 mtime-unchanged' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    check('stderr reports 0 db upserts', 'db upserts: 0' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    conn = sqlite3.connect(str(db_path))
    count = conn.execute("SELECT COUNT(*) FROM vigil_sessions").fetchone()[0]
    check('row count still 1 after no-op re-run', count == 1, f'(got {count})')
    conn.close()

    section('Re-running after touching the sidecar re-upserts (idempotent PK)')
    # Bump mtime to a known future value and change slug to verify the
    # replace took effect. An explicit future timestamp avoids the same-tick
    # collision that os.utime(path, None) can hit on coarse-resolution
    # filesystems.
    write_ccusage(jsonl_a, model='claude-sonnet-4-6', slug='session a renamed')
    future = sidecar_a.stat().st_mtime + 5
    os.utime(sidecar_a, (future, future))
    proc = run_script(log_dir, db_path, runs_log)
    check('script exited 0', proc.returncode == 0,
          f'stderr: {proc.stderr}')
    check('mtime-unchanged not reported (sidecar was re-read)',
          'mtime-unchanged' not in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    conn = sqlite3.connect(str(db_path))
    count = conn.execute("SELECT COUNT(*) FROM vigil_sessions").fetchone()[0]
    check('still exactly one row (replaced, not duplicated)', count == 1,
          f'(got {count})')
    slug = conn.execute(
        "SELECT slug FROM vigil_sessions WHERE harness_session_id='uuid-a'"
    ).fetchone()[0]
    check('slug updated to new value', slug == 'session a renamed',
          f'(got {slug!r})')
    conn.close()

    section('Malformed sidecar does not block the rest')
    bad = log_dir / 'session-20260426-070000-myrepo-main.json'
    bad.write_text('{not valid json', encoding='utf-8')

    jsonl_b = td_path / 'ccusage-b.jsonl'
    write_ccusage(jsonl_b, model='claude-opus-4-7', slug='session b')
    good = log_dir / 'session-20260426-080000-myrepo-main.json'
    write_sidecar(good, make_sidecar('uuid-b', '/home/x/code/myrepo', jsonl_b))

    proc = run_script(log_dir, db_path, runs_log)
    check('script exited 0 despite malformed sidecar',
          proc.returncode == 0, f'stderr: {proc.stderr}')
    check('warning emitted for malformed sidecar',
          'skipping' in proc.stderr and bad.name in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    conn = sqlite3.connect(str(db_path))
    ids = {r[0] for r in conn.execute(
        "SELECT harness_session_id FROM vigil_sessions"
    ).fetchall()}
    check('good sidecar still ingested', ids == {'uuid-a', 'uuid-b'},
          f'(got {ids})')
    conn.close()

    section('Null harness_session_id is processed for output but not upserted')
    jsonl_c = td_path / 'ccusage-c.jsonl'
    write_ccusage(jsonl_c, model='claude-opus-4-7', slug='session c')
    zerotool = log_dir / 'session-20260426-090000-myrepo-main.json'
    sidecar_c = make_sidecar('uuid-c', '/home/x/code/myrepo', jsonl_c)
    sidecar_c['harness_session_id'] = None
    write_sidecar(zerotool, sidecar_c)
    proc = run_script(log_dir, db_path, runs_log)
    check('script exited 0', proc.returncode == 0,
          f'stderr: {proc.stderr}')
    # Negative arm: session is not in SQLite (no PK).
    conn = sqlite3.connect(str(db_path))
    has_null = conn.execute(
        "SELECT 1 FROM vigil_sessions WHERE harness_session_id IS NULL "
        "OR harness_session_id = 'None'"
    ).fetchone()
    check('null-harness-id session not upserted', has_null is None,
          f'(got {has_null})')
    conn.close()
    # Positive arm: session IS in JSON stdout output — the existing CLI
    # contract is unchanged for the zero-tool-call case.
    try:
        output_records = json.loads(proc.stdout)
    except json.JSONDecodeError:
        output_records = []
        check('stdout is valid JSON', False, f'(stdout: {proc.stdout!r})')
    output_session_ids = {r.get('session_id') for r in output_records}
    check('zero-tool session appears in stdout output',
          '20260426-090000-myrepo-main' in output_session_ids,
          f'(got {output_session_ids})')


    section('schema_version: legacy sidecar accepted with warning, ingested')
    legacy_log = td_path / 'legacy-logs'
    legacy_log.mkdir()
    legacy_db = td_path / 'legacy.db'
    legacy_runs = td_path / 'legacy-runs.jsonl'
    jsonl_l = td_path / 'ccusage-legacy.jsonl'
    write_ccusage(jsonl_l, model='claude-sonnet-4-6', slug='legacy session')
    legacy_sidecar = legacy_log / 'session-20260426-100000-myrepo-main.json'
    legacy_dict = make_sidecar('uuid-legacy', '/home/x/code/myrepo', jsonl_l)
    del legacy_dict['schema_version']  # legacy sidecar from before the pin
    write_sidecar(legacy_sidecar, legacy_dict)

    proc = run_script(legacy_log, legacy_db, legacy_runs)
    check('script exited 0 (legacy is accepted)', proc.returncode == 0,
          f'stderr: {proc.stderr}')
    check('first-occurrence warning printed', 'legacy sidecar' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    check('summary counts legacy sidecar exactly once',
          'schema_version legacy (no field, accepted): 1' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    conn = sqlite3.connect(str(legacy_db))
    legacy_count = conn.execute(
        "SELECT COUNT(*) FROM vigil_sessions WHERE harness_session_id='uuid-legacy'"
    ).fetchone()[0]
    check('legacy sidecar still upserted', legacy_count == 1,
          f'(got {legacy_count})')
    conn.close()

    section('schema_version: unsupported version skipped with error')
    mismatch_log = td_path / 'mismatch-logs'
    mismatch_log.mkdir()
    mismatch_db = td_path / 'mismatch.db'
    mismatch_runs = td_path / 'mismatch-runs.jsonl'
    jsonl_m = td_path / 'ccusage-mismatch.jsonl'
    write_ccusage(jsonl_m, model='claude-sonnet-4-6', slug='mismatch session')
    mismatch_sidecar = mismatch_log / 'session-20260426-110000-myrepo-main.json'
    mismatch_dict = make_sidecar('uuid-mismatch', '/home/x/code/myrepo', jsonl_m)
    mismatch_dict['schema_version'] = 99  # future version this ingest doesn't know
    write_sidecar(mismatch_sidecar, mismatch_dict)

    proc = run_script(mismatch_log, mismatch_db, mismatch_runs)
    check('script exited 0 (skip-not-fail on unsupported version)',
          proc.returncode == 0, f'stderr: {proc.stderr}')
    check('error printed per file', 'schema_version=99' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    check('summary counts mismatch exactly once',
          'schema_version mismatch (skipped): 1' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    conn = sqlite3.connect(str(mismatch_db))
    mismatch_count = conn.execute(
        "SELECT COUNT(*) FROM vigil_sessions WHERE harness_session_id='uuid-mismatch'"
    ).fetchone()[0]
    check('unsupported-version sidecar not upserted', mismatch_count == 0,
          f'(got {mismatch_count})')
    conn.close()


sys.exit(1 if failed else 0)
