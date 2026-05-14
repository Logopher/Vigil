#!/usr/bin/env python3
"""Integration tests for scripts/vigil-report.py.

Seeds a vigil_sessions SQLite store directly, then drives vigil-report.py
as a subprocess and asserts the rendered HTML reflects the filter flags
(--repo, --days, --limit) and the rows materialized correctly. Also covers
the empty-results case and the database-missing error path.
"""
import datetime
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_DIR / 'scripts'))
import vigil_sessions_db as db_mod  # noqa: E402
import sqlite3  # noqa: E402

SCRIPT = REPO_DIR / 'scripts' / 'vigil-report.py'


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


def make_row(**overrides) -> dict:
    base = {col: None for col in db_mod.COLUMNS}
    base.update({
        'harness_session_id': 'uuid-default',
        'sidecar_path': 'sidecar.json',
        'sidecar_mtime_ns': 1,
        'started_at_utc': '2026-04-26T05:55:51+00:00',
        'started_at_ms': 0,
        'ingested_at_ms': 0,
    })
    base.update(overrides)
    return base


def run_report(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT)] + list(args),
        capture_output=True,
        text=True,
        check=False,
    )


def ms(dt: datetime.datetime) -> int:
    return int(dt.timestamp() * 1000)


with tempfile.TemporaryDirectory() as td:
    td_path = Path(td)
    db_path = td_path / 'sessions.db'
    out_path = td_path / 'report.html'

    now = datetime.datetime.now(datetime.timezone.utc)
    recent = now - datetime.timedelta(days=2)
    older = now - datetime.timedelta(days=30)

    conn = sqlite3.connect(str(db_path))
    db_mod.migrate(conn)
    db_mod.upsert_session(conn, make_row(
        harness_session_id='uuid-recent-r1',
        cwd='/home/x/code/myrepo', repo_name='myrepo',
        git_branch='main', active_policy='strict',
        started_at_utc=recent.isoformat(), started_at_ms=ms(recent),
        ended_at_utc=recent.isoformat(), ended_at_ms=ms(recent),
        duration_ms=300_000,
        slug='recent session in myrepo',
        models_used='claude-sonnet-4-6',
        input_tokens=1000, cache_creation_tokens=200,
        cache_read_tokens=300, output_tokens=400, cost_usd=0.123,
    ))
    db_mod.upsert_session(conn, make_row(
        harness_session_id='uuid-recent-r2',
        cwd='/home/x/code/otherrepo', repo_name='otherrepo',
        git_branch='feat', active_policy='dev',
        started_at_utc=recent.isoformat(), started_at_ms=ms(recent),
        slug='recent session in otherrepo',
        models_used='claude-opus-4-7',
        input_tokens=500, output_tokens=100,
    ))
    db_mod.upsert_session(conn, make_row(
        harness_session_id='uuid-old',
        cwd='/home/x/code/myrepo', repo_name='myrepo',
        git_branch='main',
        started_at_utc=older.isoformat(), started_at_ms=ms(older),
        slug='old session',
    ))
    conn.close()

    section('Renders both recent rows by default (last 7 days), excludes the old one')
    proc = run_report('--db', str(db_path), '--out', str(out_path))
    check('exit 0', proc.returncode == 0, f'stderr: {proc.stderr}')
    check('stderr summary present', 'wrote' in proc.stderr,
          f'(stderr: {proc.stderr!r})')
    html_text = out_path.read_text(encoding='utf-8')
    check('recent r1 slug rendered', 'recent session in myrepo' in html_text)
    check('recent r2 slug rendered', 'recent session in otherrepo' in html_text)
    check('old session excluded by --days default',
          'old session' not in html_text,
          '(old row not filtered)')
    check('cost formatted with 6 decimals', '$0.123000' in html_text,
          f'(html missing formatted cost)')
    check('total_tokens formatted with comma',
          # 1000 + 200 + 300 + 400 = 1,900
          '1,900' in html_text,
          '(comma-formatted total_tokens missing)')

    section('--repo filter restricts to one repo_name')
    proc = run_report('--db', str(db_path), '--out', str(out_path),
                      '--repo', 'myrepo')
    check('exit 0', proc.returncode == 0, f'stderr: {proc.stderr}')
    html_text = out_path.read_text(encoding='utf-8')
    check('myrepo row rendered',
          'recent session in myrepo' in html_text)
    check('otherrepo row excluded',
          'recent session in otherrepo' not in html_text,
          '(--repo did not filter)')

    section('--days 0 disables the recency filter and shows the old row')
    proc = run_report('--db', str(db_path), '--out', str(out_path),
                      '--days', '0')
    check('exit 0', proc.returncode == 0, f'stderr: {proc.stderr}')
    html_text = out_path.read_text(encoding='utf-8')
    check('old session now included', 'old session' in html_text)

    section('--limit clamps to LIMIT_MAX and announces when reached')
    proc = run_report('--db', str(db_path), '--out', str(out_path),
                      '--days', '0', '--limit', '1')
    check('exit 0', proc.returncode == 0, f'stderr: {proc.stderr}')
    html_text = out_path.read_text(encoding='utf-8')
    check('only one row rendered',
          html_text.count('<tr>') == 2,  # header row + 1 body row
          f'(tr count: {html_text.count("<tr>")})')
    check('"limit reached" annotation in meta',
          'limit 1 reached' in html_text)

    section('Empty result set still renders a valid page (no crash)')
    proc = run_report('--db', str(db_path), '--out', str(out_path),
                      '--repo', 'nonexistent')
    check('exit 0', proc.returncode == 0, f'stderr: {proc.stderr}')
    html_text = out_path.read_text(encoding='utf-8')
    check('renders empty-state message',
          'No sessions matched the filter.' in html_text)
    check('no <table> emitted', '<table>' not in html_text)

    section('Missing db file fails cleanly with a stderr message')
    missing = td_path / 'nope.db'
    proc = run_report('--db', str(missing), '--out', str(out_path))
    check('exit 1', proc.returncode == 1, f'(got {proc.returncode})')
    check('stderr names the missing path',
          str(missing) in proc.stderr,
          f'(stderr: {proc.stderr!r})')

    section('User-controlled text with format-placeholder chars does not crash')
    # A slug containing {foo} would crash a str.format()-based renderer.
    # Verify the template renders such content cleanly and that it survives
    # html.escape() into the output.
    conn = sqlite3.connect(str(db_path))
    db_mod.upsert_session(conn, make_row(
        harness_session_id='uuid-fmt',
        cwd='/home/x/code/odd', repo_name='odd',
        git_branch='feat/{branch}',
        started_at_utc=recent.isoformat(), started_at_ms=ms(recent),
        slug='slug with {placeholder} and a $dollar',
    ))
    conn.close()
    proc = run_report('--db', str(db_path), '--out', str(out_path),
                      '--days', '0', '--repo', 'odd')
    check('exit 0 with format-special chars in fields',
          proc.returncode == 0, f'stderr: {proc.stderr}')
    html_text = out_path.read_text(encoding='utf-8')
    check('placeholder-bearing slug rendered safely',
          'slug with {placeholder} and a $dollar' in html_text)
    check('branch with curly braces rendered safely',
          'feat/{branch}' in html_text)

    section('Default --out path is created under $HOME/vigil-reports/')
    # Drive the no-explicit-out path with HOME pointing at a tempdir so we
    # don't write into the real home directory under test.
    fake_home = td_path / 'fakehome'
    fake_home.mkdir()
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), '--db', str(db_path), '--days', '0'],
        env={**os.environ, 'HOME': str(fake_home)},
        capture_output=True,
        text=True,
        check=False,
    )
    check('exit 0', proc.returncode == 0, f'stderr: {proc.stderr}')
    today = datetime.date.today().isoformat()
    default_out = fake_home / 'vigil-reports' / f'{today}.html'
    check('default path created with parents',
          default_out.exists(), f'(missing: {default_out})')


sys.exit(1 if failed else 0)
