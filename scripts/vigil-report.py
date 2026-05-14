#!/usr/bin/env python3
"""vigil-report.py — Static HTML report over the vigil_sessions SQLite store.

Reads from the SQLite store materialized by vigil-sessions.py --db and
writes a single-page HTML report — no server, no live queries, all data
baked into the file. Columns are sortable in-place by clicking the header;
the embedded JS is ~30 lines and uses no external dependencies.

Usage:
    vigil-report.py --db PATH [--out FILE]
                    [--repo NAME] [--days N] [--limit N]

Default output path is ~/vigil-reports/YYYY-MM-DD.html, created with parent
directories if missing.
"""

import argparse
import datetime
import html
import sqlite3
import string
import sys
from pathlib import Path
from typing import List, Optional, Sequence, Tuple


DEFAULT_LIMIT = 200
LIMIT_MAX = 2000
DEFAULT_DAYS = 7


# (sql_column, label, css_align, data_sort_type)
_COLUMNS: Tuple[Tuple[str, str, str, str], ...] = (
    ("started_at_utc",        "Started (UTC)",   "left",  "text"),
    ("repo_name",             "Repo",            "left",  "text"),
    ("git_branch",            "Branch",          "left",  "text"),
    ("active_policy",         "Policy",          "left",  "text"),
    ("duration_ms",           "Duration",        "right", "number"),
    ("total_tokens",          "Total tokens",    "right", "number"),
    ("input_tokens",          "Input",           "right", "number"),
    ("cache_creation_tokens", "Cache creation",  "right", "number"),
    ("cache_read_tokens",     "Cache read",      "right", "number"),
    ("output_tokens",         "Output",          "right", "number"),
    ("models_used",           "Model",           "left",  "text"),
    ("cost_usd",              "Cost USD",        "right", "number"),
    ("slug",                  "Slug",            "left",  "text"),
)


def _format_duration_ms(ms: Optional[int]) -> str:
    if ms is None:
        return ""
    seconds = ms // 1000
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m{s:02d}s"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def _format_int(n: Optional[int]) -> str:
    return f"{n:,}" if n is not None else ""


def _format_cost(c: Optional[float]) -> str:
    return f"${c:.6f}" if c is not None else ""


def _format_started(ts: Optional[str]) -> str:
    if not ts:
        return ""
    # Parse via fromisoformat so offsets of either sign and any fractional
    # seconds are normalized identically. Display drops the tz and fraction
    # for compactness; the raw ISO value stays in the cell's data-sort attr.
    try:
        dt = datetime.datetime.fromisoformat(ts)
    except ValueError:
        return ts
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def _format_cell(col: str, value) -> str:
    """Apply column-specific human formatting; produce empty string for NULL."""
    if value is None:
        return ""
    if col == "duration_ms":
        return _format_duration_ms(value)
    if col in {
        "total_tokens", "input_tokens", "cache_creation_tokens",
        "cache_read_tokens", "output_tokens",
    }:
        return _format_int(value)
    if col == "cost_usd":
        return _format_cost(value)
    if col == "started_at_utc":
        return _format_started(value)
    return str(value)


def _sort_key(col: str, value) -> str:
    """Value emitted into data-sort= on the cell. JS reads this for ordering.

    Numeric columns produce strings that compare numerically when parsed via
    parseFloat; NULL becomes the empty string, which the JS sort treats as
    -Infinity for numeric columns and as the lowest string for text columns.
    """
    if value is None:
        return ""
    return str(value)


# Self-contained HTML with embedded CSS and JS. No external resources are
# referenced — the report opens correctly offline and from any path.
#
# string.Template (not str.format) so user-controlled sidecar text in
# $table_html can't break out via a stray '{' that .format() would
# interpret as a placeholder.
_HTML_TEMPLATE = string.Template("""\
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$title</title>
<style>
  body { font: 13px/1.45 system-ui, sans-serif; margin: 1.5rem; color: #111; }
  h1 { font-size: 1.2rem; margin: 0 0 0.5rem 0; }
  .meta { color: #666; margin-bottom: 1rem; }
  table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
  th, td { padding: 4px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
  th { background: #f4f4f4; text-align: left; cursor: pointer; user-select: none; position: sticky; top: 0; }
  th[data-sort-type="number"] { text-align: right; }
  td.r { text-align: right; }
  th.sort-asc::after { content: " \\25B2"; color: #888; }
  th.sort-desc::after { content: " \\25BC"; color: #888; }
  tr:hover td { background: #fafafa; }
  .empty { color: #888; font-style: italic; }
</style>
</head>
<body>
<h1>$title</h1>
<div class="meta">$meta</div>
$table_html
<script>
(function () {
  const table = document.querySelector('table');
  if (!table) return;
  const tbody = table.tBodies[0];
  const headers = Array.from(table.tHead.rows[0].cells);
  let sortedCol = -1;
  let sortAsc = true;
  headers.forEach(function (th, idx) {
    th.addEventListener('click', function () {
      if (sortedCol === idx) {
        sortAsc = !sortAsc;
      } else {
        sortedCol = idx;
        sortAsc = th.dataset.sortType !== 'number';
      }
      const type = th.dataset.sortType;
      const rows = Array.from(tbody.rows);
      rows.sort(function (a, b) {
        const av = a.cells[idx].dataset.sort || '';
        const bv = b.cells[idx].dataset.sort || '';
        let cmp;
        if (type === 'number') {
          const an = av === '' ? -Infinity : parseFloat(av);
          const bn = bv === '' ? -Infinity : parseFloat(bv);
          cmp = an - bn;
        } else {
          cmp = av.localeCompare(bv);
        }
        return sortAsc ? cmp : -cmp;
      });
      rows.forEach(function (r) { tbody.appendChild(r); });
      headers.forEach(function (h) { h.classList.remove('sort-asc', 'sort-desc'); });
      th.classList.add(sortAsc ? 'sort-asc' : 'sort-desc');
    });
  });
})();
</script>
</body>
</html>
""")


def _render_table(rows: Sequence[Sequence]) -> str:
    if not rows:
        return '<p class="empty">No sessions matched the filter.</p>'
    head_cells = []
    for col, label, _align, sort_type in _COLUMNS:
        head_cells.append(
            f'<th data-sort-type="{sort_type}">{html.escape(label)}</th>'
        )
    body_rows = []
    for r in rows:
        cells = []
        for (col, _label, align, _sort_type), value in zip(_COLUMNS, r):
            cls = ' class="r"' if align == "right" else ""
            sort_attr = html.escape(_sort_key(col, value), quote=True)
            text = html.escape(_format_cell(col, value))
            cells.append(f'<td{cls} data-sort="{sort_attr}">{text}</td>')
        body_rows.append("<tr>" + "".join(cells) + "</tr>")
    return (
        "<table>\n<thead>\n<tr>"
        + "".join(head_cells)
        + "</tr>\n</thead>\n<tbody>\n"
        + "\n".join(body_rows)
        + "\n</tbody>\n</table>"
    )


def _build_query(repo: Optional[str], days: int, limit: int) -> Tuple[str, list]:
    where_parts: List[str] = []
    params: list = []
    if repo:
        where_parts.append("repo_name = ?")
        params.append(repo)
    if days > 0:
        cutoff_ms = int((
            datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(days=days)
        ).timestamp() * 1000)
        where_parts.append("started_at_ms >= ?")
        params.append(cutoff_ms)
    where_sql = " WHERE " + " AND ".join(where_parts) if where_parts else ""
    cols = ", ".join(c[0] for c in _COLUMNS)
    # NULL total_tokens sort last so sessions with no token data don't crowd
    # the top of the report.
    sql = (
        f"SELECT {cols} FROM vigil_sessions{where_sql} "
        "ORDER BY total_tokens IS NULL, total_tokens DESC, "
        "started_at_ms DESC LIMIT ?"
    )
    params.append(limit)
    return sql, params


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="vigil-report.py",
        description="Render the vigil_sessions SQLite store as a single-page HTML report.",
    )
    ap.add_argument("--db", required=True,
                    help="path to the vigil_sessions SQLite store "
                         "(written by `vigil-sessions.py --db`)")
    ap.add_argument("--out",
                    help="output HTML path (default: ~/vigil-reports/YYYY-MM-DD.html)")
    ap.add_argument("--repo", help="restrict to a single repo_name")
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS,
                    help=f"include sessions started within last N days "
                         f"(default: {DEFAULT_DAYS}; 0 = no limit)")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT,
                    help=f"max rows in the report "
                         f"(default: {DEFAULT_LIMIT}, hard cap {LIMIT_MAX})")
    args = ap.parse_args(argv)

    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        print(f"error: database not found: {db_path}", file=sys.stderr)
        return 1

    limit = max(1, min(LIMIT_MAX, args.limit))
    days = max(0, args.days)

    sql, params = _build_query(args.repo, days, limit)
    conn = sqlite3.connect(str(db_path))
    try:
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()

    today = datetime.date.today().isoformat()
    out_path = (
        Path(args.out).expanduser() if args.out
        else (Path.home() / "vigil-reports" / f"{today}.html")
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)

    title = f"Vigil sessions — {today}"
    meta_parts = [f"{len(rows)} rows"]
    if args.repo:
        meta_parts.append(f"repo={args.repo}")
    if days:
        meta_parts.append(f"last {days}d")
    if len(rows) == limit:
        meta_parts.append(f"limit {limit} reached")
    meta = " · ".join(html.escape(p) for p in meta_parts)

    table_html = _render_table(rows)
    page = _HTML_TEMPLATE.substitute(
        title=html.escape(title),
        meta=meta,
        table_html=table_html,
    )
    out_path.write_text(page, encoding="utf-8")
    print(f"vigil-report: wrote {len(rows)} rows to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
