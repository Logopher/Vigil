#!/usr/bin/env python3
"""Per-tool-call event logger, invoked as a PreToolUse / PostToolUse hook.

Reads the harness-provided JSON event from stdin and session context from
the marker file at argv[1]. Appends one JSONL record per call to
$log_dir/tools-$session_id.jsonl. All failure paths exit 0 — logging
errors must never block Claude's tool calls.
"""

import sys
import json
import os
from datetime import datetime, timezone


def main():
    if len(sys.argv) < 2:
        return

    session_file = sys.argv[1]
    try:
        with open(session_file) as f:
            marker = json.load(f)
    except (OSError, json.JSONDecodeError):
        return

    log_dir = marker.get('log_dir', '')
    session_id = marker.get('session_id', '')
    if not log_dir or not session_id:
        return

    try:
        event_data = json.load(sys.stdin)
    except (ValueError, OSError):
        return

    hook_event = event_data.get('hook_event_name', '')
    record = {
        'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'event': hook_event,
        'tool': event_data.get('tool_name', ''),
        'tool_use_id': event_data.get('tool_use_id', ''),
    }

    if hook_event == 'PreToolUse':
        record['input'] = event_data.get('tool_input', {})
    elif hook_event == 'PostToolUse':
        record['duration_ms'] = event_data.get('duration_ms')
        if 'error' in event_data:
            record['error'] = event_data['error']
        else:
            record['response'] = event_data.get('tool_response', {})

    try:
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(log_dir, f'tools-{session_id}.jsonl')
        with open(log_path, 'a') as f:
            f.write(json.dumps(record) + '\n')
    except OSError:
        pass


if __name__ == '__main__':
    main()
