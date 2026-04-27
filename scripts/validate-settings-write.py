#!/usr/bin/env python3
"""PreToolUse gate that hard-blocks writes to Vigil's core settings files.

Rejects Write/Edit/MultiEdit calls targeting ~/.claude/settings.json and
~/.claude/settings.local.json. Unlike permission-layer deny rules (which
produce a user-dismissible prompt), a hook deny cannot be overridden at
the prompt — and takes effect even when settings.local.json is absent from
the live installation (which is when the permission-layer rules would also
be absent).

Fails open (returns without denying) on parse errors, missing fields, or
unrecognised tool names — so edge cases and direct `claude` launches are
not accidentally blocked.

Exit codes:
  0  — allow (normal return, or fail-open on error)
  2  — deny (harness reads the JSON decision from stdout)
  1  — unexpected exception; since this is a PreToolUse hook any non-zero
       exit may block the tool call — all fail-open paths must return from
       main() rather than raising.
"""

import sys
import json
import os

_WRITE_TOOLS = {'Write', 'Edit', 'MultiEdit'}

_PROTECTED = None


def _protected_paths() -> frozenset:
    global _PROTECTED
    if _PROTECTED is None:
        home = os.path.expanduser('~')
        _PROTECTED = frozenset([
            os.path.join(home, '.claude', 'settings.json'),
            os.path.join(home, '.claude', 'settings.local.json'),
        ])
    return _PROTECTED


def main():
    try:
        event_data = json.load(sys.stdin)
    except (ValueError, OSError, UnicodeDecodeError):
        return
    if not isinstance(event_data, dict):
        return

    if event_data.get('tool_name') not in _WRITE_TOOLS:
        return

    tool_input = event_data.get('tool_input', {})
    file_path = tool_input.get('file_path', '')
    if not file_path:
        return

    file_path = os.path.normpath(os.path.expanduser(file_path))

    if file_path not in _protected_paths():
        return

    decision = {
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': (
                f'Settings write blocked: {file_path} is a Vigil-protected '
                f'configuration file. Modifications require direct shell access '
                f'outside the Claude session.'
            ),
        }
    }
    print(json.dumps(decision))
    sys.exit(2)


if __name__ == '__main__':
    main()
