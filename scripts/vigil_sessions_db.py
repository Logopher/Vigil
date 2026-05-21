#!/usr/bin/env python3
"""vigil_sessions_db.py — SQLite schema and helpers for the vigil_sessions store.

Defines the schema, applies migrations via PRAGMA user_version, and exposes
upsert + mtime-lookup helpers used by vigil-sessions.py --db mode and any
downstream readers (vigil-report.py).

This module is importable. No side effects on import — migrate(conn) is the
explicit entry point and is idempotent.
"""

import sqlite3
from typing import Optional


# SQLite-side schema version. Drives PRAGMA user_version migrations on the
# materialization DB. Distinct from SUPPORTED_SIDECAR_CONTRACT_VERSIONS
# below — the two version axes (output DB shape vs. input sidecar shape)
# evolve independently. Both constants live here as the central home for
# schema-related versioning constants in this module's ecosystem.
SCHEMA_VERSION = 1

# Sidecar JSON contract versions this module's ingest accepts. Gates which
# sidecar JSON shapes vigil-sessions.py knows how to read. Read by the
# ingest loop, not by anything inside this module — placement here is by
# convention (all schema constants in one place), not by reference.
SUPPORTED_SIDECAR_CONTRACT_VERSIONS = frozenset({1})


# v1 (initial): vigil_sessions table + indexes. total_tokens is computed as a
# VIRTUAL generated column so queries can sort and filter on it without
# duplicating storage. The CASE expression preserves NULL when no usage was
# recorded (rather than coercing to 0), so "no measured tokens" remains
# distinguishable from "zero measured tokens" in reports.
#
# Statements are listed individually rather than passed to executescript() so
# migrate() can run them inside its own atomicity guard. IF NOT EXISTS on each
# makes re-runs after a partial failure safe regardless of which statement
# tripped — the surviving objects are skipped and the rest re-applied.
_SCHEMA_V1_STMTS = (
    """
    CREATE TABLE IF NOT EXISTS vigil_sessions (
        harness_session_id          TEXT PRIMARY KEY,
        sidecar_path                TEXT NOT NULL,
        sidecar_mtime_ns            INTEGER NOT NULL,
        cwd                         TEXT,
        repo_name                   TEXT,
        git_branch                  TEXT,
        git_head                    TEXT,
        ended_at_git_head           TEXT,
        active_policy               TEXT,
        started_at_utc              TEXT NOT NULL,
        ended_at_utc                TEXT,
        started_at_ms               INTEGER NOT NULL,
        ended_at_ms                 INTEGER,
        duration_ms                 INTEGER,
        commits_during_session_json TEXT,
        ccusage_jsonl_path          TEXT,
        slug                        TEXT,
        models_used                 TEXT,
        input_tokens                INTEGER,
        cache_creation_tokens       INTEGER,
        cache_read_tokens           INTEGER,
        output_tokens               INTEGER,
        total_tokens INTEGER GENERATED ALWAYS AS (
            CASE
                WHEN input_tokens IS NULL
                 AND output_tokens IS NULL
                 AND cache_creation_tokens IS NULL
                 AND cache_read_tokens IS NULL
                THEN NULL
                ELSE COALESCE(input_tokens, 0)
                   + COALESCE(output_tokens, 0)
                   + COALESCE(cache_creation_tokens, 0)
                   + COALESCE(cache_read_tokens, 0)
            END
        ) VIRTUAL,
        cost_usd                    REAL,
        cost_usd_by_model           TEXT,
        ingested_at_ms              INTEGER NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_vigil_sessions_started_desc "
    "ON vigil_sessions (started_at_ms DESC)",
    "CREATE INDEX IF NOT EXISTS idx_vigil_sessions_repo_started "
    "ON vigil_sessions (repo_name, started_at_ms DESC)",
    "CREATE INDEX IF NOT EXISTS idx_vigil_sessions_sidecar_path "
    "ON vigil_sessions (sidecar_path)",
)


# Insert order matches the column order in _SCHEMA_V1_STMTS (excluding the
# generated total_tokens column).
COLUMNS = (
    "harness_session_id",
    "sidecar_path",
    "sidecar_mtime_ns",
    "cwd",
    "repo_name",
    "git_branch",
    "git_head",
    "ended_at_git_head",
    "active_policy",
    "started_at_utc",
    "ended_at_utc",
    "started_at_ms",
    "ended_at_ms",
    "duration_ms",
    "commits_during_session_json",
    "ccusage_jsonl_path",
    "slug",
    "models_used",
    "input_tokens",
    "cache_creation_tokens",
    "cache_read_tokens",
    "output_tokens",
    "cost_usd",
    "cost_usd_by_model",
    "ingested_at_ms",
)


def migrate(conn: sqlite3.Connection) -> None:
    """Apply pending migrations on conn so user_version == SCHEMA_VERSION.

    Idempotent: re-running on an up-to-date database is a no-op. Re-running
    after a partial failure is also safe because every DDL statement uses
    IF NOT EXISTS and user_version is set only after all DDL succeeds.

    Raises RuntimeError if the database carries a user_version newer than
    this module knows about — silently operating against an unknown schema
    would mask shape mismatches.
    """
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    if current > SCHEMA_VERSION:
        raise RuntimeError(
            f"database user_version={current} is newer than this module's "
            f"SCHEMA_VERSION={SCHEMA_VERSION}; upgrade vigil_sessions_db.py"
        )
    if current < 1:
        for stmt in _SCHEMA_V1_STMTS:
            conn.execute(stmt)
        conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        conn.commit()


def upsert_session(conn: sqlite3.Connection, row: dict) -> None:
    """Insert-or-replace one session row keyed by harness_session_id.

    row must contain every key in COLUMNS. Missing keys raise KeyError so
    silent partial writes don't happen — the writer is expected to set None
    explicitly for nullable columns.

    INSERT OR REPLACE deletes any existing row with the same PK and inserts
    a new one (rather than updating in place), so rowid is not stable across
    upserts. No client of this module retains rowid references; if one does
    later, switch to INSERT ... ON CONFLICT(harness_session_id) DO UPDATE.
    """
    values = [row[col] for col in COLUMNS]
    placeholders = ", ".join("?" for _ in COLUMNS)
    column_list = ", ".join(COLUMNS)
    conn.execute(
        f"INSERT OR REPLACE INTO vigil_sessions ({column_list}) "
        f"VALUES ({placeholders})",
        values,
    )
    conn.commit()


def get_sidecar_mtime_ns(
    conn: sqlite3.Connection,
    sidecar_path: str,
) -> Optional[int]:
    """Return the stored mtime_ns for a given sidecar path, or None if absent."""
    row = conn.execute(
        "SELECT sidecar_mtime_ns FROM vigil_sessions WHERE sidecar_path = ?",
        (sidecar_path,),
    ).fetchone()
    return row[0] if row else None
