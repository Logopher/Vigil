#!/usr/bin/env python3
"""Unit tests for scripts/vigil_sessions_db.py.

Verifies schema migration is idempotent, upsert replaces by primary key,
mtime lookup roundtrips, the generated total_tokens column preserves NULL
when all bucket columns are NULL, and missing-key upserts fail loudly.
"""
import os
import sqlite3
import sys
import tempfile
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_DIR / 'scripts'))
import vigil_sessions_db as db_mod  # noqa: E402


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
    """Return a complete row dict, applying overrides on top of defaults."""
    base = {col: None for col in db_mod.COLUMNS}
    base.update({
        'harness_session_id': 'uuid-1',
        'sidecar_path': 'fixture-session-x.json',
        'sidecar_mtime_ns': 1_000_000_000,
        'started_at_utc': '2026-04-26T05:55:51+00:00',
        'started_at_ms': 1745647751000,
        'ingested_at_ms': 1745647800000,
    })
    base.update(overrides)
    return base


section('Migration is idempotent and sets user_version=1')
conn = sqlite3.connect(':memory:')
db_mod.migrate(conn)
v = conn.execute('PRAGMA user_version').fetchone()[0]
check('first migrate sets user_version=1', v == 1, f'(got {v})')
db_mod.migrate(conn)
v = conn.execute('PRAGMA user_version').fetchone()[0]
check('second migrate is a no-op (still 1)', v == 1, f'(got {v})')
tables = [r[0] for r in conn.execute(
    "SELECT name FROM sqlite_master WHERE type='table'"
).fetchall()]
check('vigil_sessions table created', 'vigil_sessions' in tables,
      f'(got {tables})')
indexes = {r[0] for r in conn.execute(
    "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"
).fetchall()}
check('started_desc index exists',
      'idx_vigil_sessions_started_desc' in indexes)
check('repo_started index exists',
      'idx_vigil_sessions_repo_started' in indexes)
check('sidecar_path index exists',
      'idx_vigil_sessions_sidecar_path' in indexes)
conn.close()


section('upsert_session inserts and replaces by harness_session_id')
conn = sqlite3.connect(':memory:')
db_mod.migrate(conn)
db_mod.upsert_session(conn, make_row(harness_session_id='uuid-a', input_tokens=10))
db_mod.upsert_session(conn, make_row(harness_session_id='uuid-b', input_tokens=20))
count = conn.execute('SELECT COUNT(*) FROM vigil_sessions').fetchone()[0]
check('two distinct ids → two rows', count == 2, f'(got {count})')
db_mod.upsert_session(conn, make_row(harness_session_id='uuid-a', input_tokens=99))
count = conn.execute('SELECT COUNT(*) FROM vigil_sessions').fetchone()[0]
check('replace same id → still 2 rows', count == 2, f'(got {count})')
val = conn.execute(
    "SELECT input_tokens FROM vigil_sessions WHERE harness_session_id='uuid-a'"
).fetchone()[0]
check('replaced row keeps new value', val == 99, f'(got {val})')
conn.close()


section('Missing column raises KeyError (no silent partial writes)')
# Dropping started_at_ms stands in for any required column; the contract is
# that all keys in COLUMNS must be supplied.
conn = sqlite3.connect(':memory:')
db_mod.migrate(conn)
incomplete = make_row()
del incomplete['started_at_ms']
raised = False
try:
    db_mod.upsert_session(conn, incomplete)
except KeyError:
    raised = True
check('upsert with missing key raises KeyError', raised)
conn.close()


section('Future user_version raises (newer schema than module knows)')
conn = sqlite3.connect(':memory:')
conn.execute('PRAGMA user_version = 99')
conn.commit()
raised = False
try:
    db_mod.migrate(conn)
except RuntimeError:
    raised = True
check('migrate raises when user_version > SCHEMA_VERSION', raised)
conn.close()


section('On-disk re-open: migrate twice across separate connections')
with tempfile.TemporaryDirectory() as td:
    dbpath = Path(td) / 'sessions.db'
    conn = sqlite3.connect(str(dbpath))
    db_mod.migrate(conn)
    db_mod.upsert_session(conn, make_row(harness_session_id='persist-1'))
    conn.close()
    # Re-open against the same file; migrate should be a no-op and the row
    # should still be present.
    conn = sqlite3.connect(str(dbpath))
    db_mod.migrate(conn)
    v = conn.execute('PRAGMA user_version').fetchone()[0]
    check('user_version persisted across reopen', v == 1, f'(got {v})')
    count = conn.execute(
        "SELECT COUNT(*) FROM vigil_sessions WHERE harness_session_id='persist-1'"
    ).fetchone()[0]
    check('row persisted across reopen', count == 1, f'(got {count})')
    conn.close()


section('get_sidecar_mtime_ns roundtrips and returns None for unknown')
conn = sqlite3.connect(':memory:')
db_mod.migrate(conn)
db_mod.upsert_session(conn, make_row(
    harness_session_id='uuid-m',
    sidecar_path='/tmp/m.json',
    sidecar_mtime_ns=42_424_242,
))
got = db_mod.get_sidecar_mtime_ns(conn, '/tmp/m.json')
check('mtime returned for known path', got == 42_424_242, f'(got {got})')
got = db_mod.get_sidecar_mtime_ns(conn, '/tmp/nope.json')
check('None returned for unknown path', got is None, f'(got {got!r})')
conn.close()


section('total_tokens generated column: sums non-NULL, NULL when all NULL')
conn = sqlite3.connect(':memory:')
db_mod.migrate(conn)
db_mod.upsert_session(conn, make_row(
    harness_session_id='uuid-sum',
    input_tokens=1, cache_creation_tokens=2,
    cache_read_tokens=4, output_tokens=8,
))
got = conn.execute(
    "SELECT total_tokens FROM vigil_sessions WHERE harness_session_id='uuid-sum'"
).fetchone()[0]
check('sum of four buckets = 15', got == 15, f'(got {got})')
db_mod.upsert_session(conn, make_row(
    harness_session_id='uuid-null',
    input_tokens=None, cache_creation_tokens=None,
    cache_read_tokens=None, output_tokens=None,
))
got = conn.execute(
    "SELECT total_tokens FROM vigil_sessions WHERE harness_session_id='uuid-null'"
).fetchone()[0]
check('all-NULL buckets → total_tokens NULL', got is None, f'(got {got!r})')
db_mod.upsert_session(conn, make_row(
    harness_session_id='uuid-mixed',
    input_tokens=5, cache_creation_tokens=None,
    cache_read_tokens=None, output_tokens=3,
))
got = conn.execute(
    "SELECT total_tokens FROM vigil_sessions WHERE harness_session_id='uuid-mixed'"
).fetchone()[0]
check('mixed NULL/value → COALESCE sums non-NULL', got == 8, f'(got {got})')
conn.close()


sys.exit(1 if failed else 0)
