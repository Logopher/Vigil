#!/usr/bin/env python3
"""PreToolUse gate that blocks cross-project memory writes.

The default profile allows Write/Edit/MultiEdit to ~/.claude/projects/*/memory/**,
which would let Claude modify another project's memory — cross-project poisoning
that is harder to notice than same-project writes (the target may be rarely visited).
This hook compares the target memory path's project slug against the calling
session's slug (derived from the `cwd` field in the hook's stdin JSON) and denies
mismatches.

Slug derivation: cwd.replace('/', '-'). This matches Claude Code's own formula.
Known limit: paths that differ only by '/' vs '-' (e.g. '/home/u/my-project' and
'/home/u/my/project') produce the same slug. This is inherent to Claude Code's
project slug format and not fixable at this layer; the hook cannot distinguish
between such paths.

Fails open (returns without denying) on parse errors, missing fields, unrecognised
path shapes, or missing cwd — so direct `claude` launches and edge cases are not
accidentally blocked.

Exit codes:
  0  — allow (normal return, or fail-open on error)
  2  — deny (cross-project write detected; harness reads the JSON decision from stdout)
  1  — unexpected exception; harness behavior is unspecified for this case, but
       since this is a PreToolUse hook any non-zero exit may block the tool call —
       all code paths that should fail-open must reach the return in main() rather
       than raising.
"""

import sys
import json
import os

# All tools that write to a file path; each uses `file_path` in tool_input.
_WRITE_TOOLS = {'Write', 'Edit', 'MultiEdit'}


def slugify(cwd: str) -> str:
    return cwd.replace('/', '-')


def main():
    try:
        event_data = json.load(sys.stdin)
    except (ValueError, OSError, UnicodeDecodeError):
        return  # fail open
    if not isinstance(event_data, dict):
        return  # unexpected JSON root; fail open

    if event_data.get('tool_name') not in _WRITE_TOOLS:
        return

    tool_input = event_data.get('tool_input', {})
    file_path = tool_input.get('file_path', '')
    if not file_path:
        return

    file_path = os.path.normpath(os.path.expanduser(file_path))
    home = os.path.expanduser('~')
    memory_base = os.path.join(home, '.claude', 'projects')

    if not file_path.startswith(memory_base + os.sep):
        return  # not a memory path

    # Extract target slug: ~/.claude/projects/<slug>/memory/...
    rel = file_path[len(memory_base) + 1:]
    parts = rel.split(os.sep, 2)
    if len(parts) < 2 or parts[1] != 'memory':
        return  # not inside a /memory/ subdirectory, allow

    target_slug = parts[0]

    # Derive the calling session's slug from the cwd field in hook stdin.
    cwd = os.path.normpath(event_data.get('cwd', '').strip())
    if not cwd or cwd == '.':
        print('validate-memory-write: cwd missing from hook event; allowing write', file=sys.stderr)
        return  # fail open

    expected_slug = slugify(cwd)

    if target_slug == expected_slug:
        return  # same project — allow

    decision = {
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': (
                f'Cross-project memory write blocked: '
                f'target slug {target_slug!r} does not match '
                f'current session slug {expected_slug!r}. '
                f'Memory writes are only allowed within the current project.'
            ),
        }
    }
    print(json.dumps(decision))
    sys.exit(2)


if __name__ == '__main__':
    main()
