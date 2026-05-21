#!/usr/bin/env bash
# Tier-? vigil-hook subcommand tests — currently exercises the two
# security-gate validators. Drives vigil-hook directly with mocked event
# payloads on stdin and asserts exit codes (the same path the harness uses
# in production), avoiding any real file mutation.
#
# vigil-hook is resolved in this order:
#   1. $VIGIL_HOOK if set
#   2. /usr/local/bin/vigil-hook (the live, sudo-installed binary)
#   3. $REPO_DIR/scripts/vigil-hook (the in-repo source — for CI / pre-install)
#
# Tests cover:
#   validate-settings-write — denies Write/Edit/MultiEdit to ~/.claude/settings.json,
#                             ~/.claude/settings.local.json, and
#                             ~/.claude/keybindings.json; allows Bash and writes
#                             to other paths; fails open on empty/garbage stdin.
#   validate-memory-write   — denies cross-project ~/.claude/projects/<other-slug>/
#                             memory/** writes; allows same-slug, non-memory
#                             paths, and non-write tools; fails open on missing
#                             cwd or unparseable input.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${VIGIL_HOOK:-}" ]]; then
    if [[ -x /usr/local/bin/vigil-hook ]]; then
        VIGIL_HOOK=/usr/local/bin/vigil-hook
    else
        VIGIL_HOOK="$REPO_DIR/scripts/vigil-hook"
    fi
fi
if [[ ! -x "$VIGIL_HOOK" ]]; then
    echo "vigil-hook.sh: vigil-hook not found or not executable: $VIGIL_HOOK" >&2
    exit 1
fi

failed=0
pass()    { [[ "${VIGIL_TESTS_VERBOSE:-0}" == "1" ]] && printf '  PASS  %s\n' "$1"; return 0; }
fail()    { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

# run_hook <subcommand> <event-json> -> echoes hook exit code
run_hook() {
    local sub="$1" event="$2" code
    set +e
    printf '%s' "$event" | "$VIGIL_HOOK" "$sub" >/dev/null 2>&1
    code=$?
    set -e
    printf '%d' "$code"
}

expect_exit() {
    local sub="$1" want="$2" label="$3" event="$4" got
    got=$(run_hook "$sub" "$event")
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label (expected exit $want, got $got)"
    fi
}
expect_deny()  { expect_exit "$1" 2 "$2" "$3"; }
expect_allow() { expect_exit "$1" 0 "$2" "$3"; }


# =====================================================================
# validate-settings-write
# =====================================================================
#
# Payloads in this section intentionally omit `session_id`. The deny path
# of cmd_validate_settings_write now loads session context to record the
# denial; with no session_id, _load_session_context returns None and
# _record_denial silently no-ops, so no side-effect writes touch the real
# ~/vigil-logs/. Future additions to this section that supply a resolvable
# session_id must sandbox HOME first (see the DEN_HOME pattern below) to
# avoid leaving bridge-marker files and tools-JSONL writes in the real
# home directory.

section "validate-settings-write — denies"

expect_deny validate-settings-write \
    'Write to ~/.claude/settings.json' \
    "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/settings.json","content":"x"}}' "$HOME")"

expect_deny validate-settings-write \
    'Edit to ~/.claude/settings.json' \
    "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/.claude/settings.json","old_string":"a","new_string":"b"}}' "$HOME")"

expect_deny validate-settings-write \
    'MultiEdit to ~/.claude/settings.json' \
    "$(printf '{"tool_name":"MultiEdit","tool_input":{"file_path":"%s/.claude/settings.json"}}' "$HOME")"

expect_deny validate-settings-write \
    'Write to ~/.claude/settings.local.json' \
    "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/settings.local.json","content":"x"}}' "$HOME")"

expect_deny validate-settings-write \
    'Write to ~/.claude/keybindings.json' \
    "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/keybindings.json","content":"x"}}' "$HOME")"

expect_deny validate-settings-write \
    'Edit to ~/.claude/keybindings.json' \
    "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/.claude/keybindings.json","old_string":"a","new_string":"b"}}' "$HOME")"

expect_deny validate-settings-write \
    'MultiEdit to ~/.claude/keybindings.json' \
    "$(printf '{"tool_name":"MultiEdit","tool_input":{"file_path":"%s/.claude/keybindings.json"}}' "$HOME")"

section "validate-settings-write — allows"

expect_allow validate-settings-write \
    'Write to ~/.claude/CLAUDE.md (different file)' \
    "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/CLAUDE.md","content":"x"}}' "$HOME")"

expect_allow validate-settings-write \
    'Bash with command containing settings.json (not a write tool)' \
    "$(printf '{"tool_name":"Bash","tool_input":{"command":"cat %s/.claude/settings.json"}}' "$HOME")"

expect_allow validate-settings-write \
    'Empty stdin (fail-open)' \
    ''

expect_allow validate-settings-write \
    'Garbage stdin (fail-open)' \
    'not-json{{{'


# =====================================================================
# validate-memory-write
# =====================================================================
#
# Slug derivation: the hook reads the per-session JSON the wrapper writes
# to ~/.config/vigil/sessions/<harness_session_id>.json, takes its `cwd`
# field (the session's launch directory), and computes
# slug = cwd.replace('/', '-'). Cross-project means the target path's
# project-slug component differs from that derived slug. event_data['cwd']
# is intentionally ignored — it drifts when the LLM runs `cd` via Bash.
#
# Sandbox HOME so the per-test session JSON we write does not collide with
# real Vigil state. Restored explicitly below the last expect_* in this
# section so any future tests appended to this file see the real $HOME.

VMW_ORIG_HOME="$HOME"
VMW_HOME=$(mktemp -d)
HOME="$VMW_HOME"
export HOME
mkdir -p "$HOME/.config/vigil/sessions"

# Fixed session id used by tests that need a present session JSON. UUID-like
# shape matches what the harness produces (cosmetic; the hook doesn't parse).
VMW_SID="aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
# Session id that points at a deliberately-absent fixture, for fail-open coverage.
VMW_SID_MISSING="bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"

# Write a per-session JSON the hook will discover via _load_session_context.
# log_dir is empty so the bridge-marker writer short-circuits (it would
# otherwise try to create a directory and drop a marker file).
write_session_json() {
    local sid="$1" cwd="$2"
    printf '{"vigil_session_id":"test","log_dir":"","policy":"strict","launched_at":"2026-01-01T00:00:00Z","repo":"","branch":"","cwd":"%s"}\n' \
        "$cwd" > "$HOME/.config/vigil/sessions/$sid.json"
}

# Common fixture: session launched from /home/grault/code/foo
# → expected slug "-home-grault-code-foo".
write_session_json "$VMW_SID" "/home/grault/code/foo"

section "validate-memory-write — denies"

expect_deny validate-memory-write \
    'Cross-project memory write (slug mismatch)' \
    "$(printf '{"tool_name":"Write","session_id":"%s","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' "$VMW_SID" "$HOME")"

expect_deny validate-memory-write \
    'Cross-project Edit' \
    "$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","old_string":"a","new_string":"b"}}' "$VMW_SID" "$HOME")"

expect_deny validate-memory-write \
    'Cross-project MultiEdit' \
    "$(printf '{"tool_name":"MultiEdit","session_id":"%s","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md"}}' "$VMW_SID" "$HOME")"

section "validate-memory-write — allows"

expect_allow validate-memory-write \
    'Same-project memory write' \
    "$(printf '{"tool_name":"Write","session_id":"%s","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-foo/memory/note.md","content":"x"}}' "$VMW_SID" "$HOME")"

# Regression for the bug this commit fixes: with the launch cwd recorded
# in the session JSON, the hook allows same-project writes even when the
# event payload reports a drifted cwd (e.g., after the LLM runs `cd`).
expect_allow validate-memory-write \
    'Same-project memory write with drifted event cwd (regression)' \
    "$(printf '{"tool_name":"Write","session_id":"%s","cwd":"/home/grault/code/foo/subdir","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-foo/memory/note.md","content":"x"}}' "$VMW_SID" "$HOME")"

expect_allow validate-memory-write \
    'Project subdir that is not /memory/' \
    "$(printf '{"tool_name":"Write","session_id":"%s","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/cache/x.txt","content":"x"}}' "$VMW_SID" "$HOME")"

expect_allow validate-memory-write \
    'File outside ~/.claude/projects/' \
    "$(printf '{"tool_name":"Write","session_id":"%s","tool_input":{"file_path":"%s/code/foo/x.md","content":"x"}}' "$VMW_SID" "$HOME")"

expect_allow validate-memory-write \
    'Bash to memory path (not a write tool)' \
    "$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"cat %s/.claude/projects/-home-grault-code-bar/memory/note.md"}}' "$VMW_SID" "$HOME")"

expect_allow validate-memory-write \
    'Missing session_id (fail-open)' \
    "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' "$HOME")"

expect_allow validate-memory-write \
    'Session JSON missing (fail-open)' \
    "$(printf '{"tool_name":"Write","session_id":"%s","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' "$VMW_SID_MISSING" "$HOME")"

# Session JSON exists but lacks a cwd value → hook prints a diagnostic to
# stderr and fails open. Uses a third sid to avoid clobbering VMW_SID.
write_session_json "cccccccc-cccc-4ccc-cccc-cccccccccccc" ""
expect_allow validate-memory-write \
    'Session JSON present, cwd empty (fail-open)' \
    "$(printf '{"tool_name":"Write","session_id":"cccccccc-cccc-4ccc-cccc-cccccccccccc","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' "$HOME")"

expect_allow validate-memory-write \
    'Empty stdin (fail-open)' \
    ''

expect_allow validate-memory-write \
    'Garbage stdin (fail-open)' \
    'not-json{{{'

# Restore HOME so any tests appended after this section run against real
# state. Tempdir cleanup is best-effort; mktemp -d output is guaranteed
# non-empty so rm -rf has a concrete target.
rm -rf -- "$VMW_HOME"
HOME="$VMW_ORIG_HOME"
export HOME


# =====================================================================
# log-tool-use — schema_version meta record on first write
# =====================================================================
#
# This section deliberately invokes the in-repo vigil-hook source rather
# than the (potentially older) installed binary at /usr/local/bin. The
# meta-record behavior under test was added to scripts/vigil-hook; until
# the developer reinstalls (per CLAUDE.md, install.sh is operator-run),
# the installed binary may not exhibit it. Using the in-repo source
# means this test validates the repo's source-of-truth regardless of
# installation lag. Trade-off: a post-install regression where the
# installed binary diverges from the repo would not be caught by this
# section. To exercise the installed binary against this section,
# explicitly set VIGIL_HOOK=/usr/local/bin/vigil-hook and edit the
# LTU_HOOK assignment below.

LTU_HOOK="$REPO_DIR/scripts/vigil-hook"
if [[ ! -x "$LTU_HOOK" ]]; then
    fail "in-repo vigil-hook not executable: $LTU_HOOK"
fi

# Sandbox HOME for log-tool-use tests; the hook resolves session JSON via
# os.path.expanduser('~/.config/vigil/sessions/<id>.json').
LTU_ORIG_HOME="$HOME"
LTU_HOME=$(mktemp -d)
HOME="$LTU_HOME"
export HOME
mkdir -p "$HOME/.config/vigil/sessions"
LTU_LOG_DIR="$LTU_HOME/vigil-logs"
mkdir -p "$LTU_LOG_DIR"
LTU_SID="dddddddd-dddd-4ddd-dddd-dddddddddddd"

# log_dir is a real directory so the hook writes the tools-JSONL there.
printf '{"vigil_session_id":"test-vsid","log_dir":"%s","policy":"strict","launched_at":"2026-01-01T00:00:00Z","repo":"","branch":"","cwd":"/home/grault/code/foo"}\n' \
    "$LTU_LOG_DIR" > "$HOME/.config/vigil/sessions/$LTU_SID.json"

LTU_LOG="$LTU_LOG_DIR/tools-$LTU_SID.jsonl"

section "log-tool-use — first write emits meta record then event"

printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"tu_1","tool_input":{"file_path":"/etc/hosts"}}' \
    "$LTU_SID" | "$LTU_HOOK" log-tool-use >/dev/null 2>&1

if [[ -f "$LTU_LOG" ]]; then
    pass "tools-jsonl created on first event"
else
    fail "tools-jsonl not created at $LTU_LOG"
fi

# Use python json.loads in the test to avoid quoting fragility across
# bash/grep whitespace variations.
py_err=$(mktemp)
CLEANUP_PY_ERR=("$py_err")
if python3 -c "
import json, sys
with open('$LTU_LOG') as f:
    lines = f.read().splitlines()
if len(lines) < 2:
    sys.exit('expected >=2 lines, got %d' % len(lines))
meta = json.loads(lines[0])
if meta.get('event') != 'meta':
    sys.exit('first line event != meta: %r' % meta)
if meta.get('schema_version') != 1:
    sys.exit('first line schema_version != 1: %r' % meta)
event = json.loads(lines[1])
if event.get('event') != 'PreToolUse':
    sys.exit('second line event != PreToolUse: %r' % event)
" 2>"$py_err"; then
    pass "first line is meta record with schema_version: 1; second is PreToolUse"
else
    fail "meta/event layout incorrect; got: $(cat "$LTU_LOG") | python stderr: $(cat "$py_err")"
fi
rm -f -- "$py_err"

section "log-tool-use — subsequent writes append without duplicate meta"

printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"tu_1","tool_response":{"text":"ok"},"duration_ms":12}' \
    "$LTU_SID" | "$LTU_HOOK" log-tool-use >/dev/null 2>&1

py_err=$(mktemp)
if python3 -c "
import json, sys
with open('$LTU_LOG') as f:
    lines = f.read().splitlines()
metas = [l for l in lines if json.loads(l).get('event') == 'meta']
if len(metas) != 1:
    sys.exit('expected 1 meta record, got %d' % len(metas))
if len(lines) != 3:
    sys.exit('expected 3 total lines (meta + Pre + Post), got %d' % len(lines))
if json.loads(lines[2]).get('event') != 'PostToolUse':
    sys.exit('third line event != PostToolUse: %r' % json.loads(lines[2]))
" 2>"$py_err"; then
    pass "second event appended without duplicate meta record"
else
    fail "subsequent-write layout incorrect; got: $(cat "$LTU_LOG") | python stderr: $(cat "$py_err")"
fi
rm -f -- "$py_err"

# Restore HOME before cleanup so a signal interrupting rm leaves HOME
# pointing at the original directory, not the deleted sandbox.
HOME="$LTU_ORIG_HOME"
export HOME
rm -rf -- "$LTU_HOME"


# =====================================================================
# validators — denial recorded to tools-JSONL
# =====================================================================
#
# Same in-repo-source rationale as the log-tool-use section above:
# denial-recording is a new behavior added to scripts/vigil-hook, so
# this section explicitly invokes $REPO_DIR/scripts/vigil-hook rather
# than $VIGIL_HOOK (which prefers the installed binary). To exercise
# the installed binary, set VIGIL_HOOK=/usr/local/bin/vigil-hook and
# edit DEN_HOOK below.

DEN_HOOK="$REPO_DIR/scripts/vigil-hook"

DEN_ORIG_HOME="$HOME"
DEN_HOME=$(mktemp -d)
HOME="$DEN_HOME"
export HOME
mkdir -p "$HOME/.config/vigil/sessions"
DEN_LOG_DIR="$DEN_HOME/vigil-logs"
mkdir -p "$DEN_LOG_DIR"
DEN_SID="eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee"

printf '{"vigil_session_id":"test-vsid","log_dir":"%s","policy":"strict","launched_at":"2026-01-01T00:00:00Z","repo":"","branch":"","cwd":"/home/grault/code/foo"}\n' \
    "$DEN_LOG_DIR" > "$HOME/.config/vigil/sessions/$DEN_SID.json"

DEN_LOG="$DEN_LOG_DIR/tools-$DEN_SID.jsonl"

section "validate-memory-write — denial appended to tools-JSONL"

# Cross-project memory write (slug mismatch) — should deny and record.
set +e
printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_use_id":"tu_deny_mem","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' \
    "$DEN_SID" "$HOME" | "$DEN_HOOK" validate-memory-write >/dev/null 2>&1
mem_rc=$?
set -e

if [[ "$mem_rc" -eq 2 ]]; then
    pass "validate-memory-write exited 2 (denied)"
else
    fail "validate-memory-write expected exit 2, got $mem_rc"
fi

py_err=$(mktemp)
if python3 -c "
import json, sys
with open('$DEN_LOG') as f:
    lines = f.read().splitlines()
denied = [json.loads(l) for l in lines if json.loads(l).get('event') == 'denied']
if len(denied) != 1:
    sys.exit('expected 1 denied record, got %d (lines=%r)' % (len(denied), lines))
d = denied[0]
required = {'ts', 'vigil_session_id', 'harness_session_id', 'event', 'tool', 'tool_use_id', 'reason', 'target'}
missing = required - set(d.keys())
if missing:
    sys.exit('denied record missing keys: %s (got: %r)' % (sorted(missing), d))
if d['tool'] != 'Write':
    sys.exit('tool != Write: %r' % d)
if d['tool_use_id'] != 'tu_deny_mem':
    sys.exit('tool_use_id wrong: %r' % d)
if d['reason'] != 'validate_memory_write':
    sys.exit('reason wrong: %r' % d)
if not d['target'].endswith('/memory/note.md'):
    sys.exit('target wrong: %r' % d)
" 2>"$py_err"; then
    pass "denied record has full schema (tool, tool_use_id, reason, target, ids, ts)"
else
    fail "denied record malformed; got: $(cat "$DEN_LOG") | python stderr: $(cat "$py_err")"
fi
rm -f -- "$py_err"

section "validate-settings-write — denial appended to tools-JSONL"

set +e
printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_use_id":"tu_deny_set","tool_input":{"file_path":"%s/.claude/settings.json","content":"x"}}' \
    "$DEN_SID" "$HOME" | "$DEN_HOOK" validate-settings-write >/dev/null 2>&1
set_rc=$?
set -e

if [[ "$set_rc" -eq 2 ]]; then
    pass "validate-settings-write exited 2 (denied)"
else
    fail "validate-settings-write expected exit 2, got $set_rc"
fi

py_err=$(mktemp)
if python3 -c "
import json, sys
with open('$DEN_LOG') as f:
    lines = f.read().splitlines()
denied = [json.loads(l) for l in lines if json.loads(l).get('event') == 'denied']
# Two denials now: validate_memory_write from prior test, validate_settings_write here.
reasons = sorted(d['reason'] for d in denied)
if reasons != ['validate_memory_write', 'validate_settings_write']:
    sys.exit('expected both reasons, got: %r' % reasons)
settings_denial = next(d for d in denied if d['reason'] == 'validate_settings_write')
if settings_denial['tool_use_id'] != 'tu_deny_set':
    sys.exit('settings tool_use_id wrong: %r' % settings_denial)
if not settings_denial['target'].endswith('/.claude/settings.json'):
    sys.exit('settings target wrong: %r' % settings_denial)
" 2>"$py_err"; then
    pass "settings denial appended alongside memory denial"
else
    fail "settings denial wrong; got: $(cat "$DEN_LOG") | python stderr: $(cat "$py_err")"
fi
rm -f -- "$py_err"

section "validators — first denial writes the meta record too"

# A fresh session (separate from the one above): the very first write to
# the tools-JSONL is a denial. Verify the meta record is emitted just
# like cmd_log_tool_use's first-write path does.
DEN_SID2="ffffffff-ffff-4fff-ffff-ffffffffffff"
printf '{"vigil_session_id":"test-vsid2","log_dir":"%s","policy":"strict","launched_at":"2026-01-01T00:00:00Z","repo":"","branch":"","cwd":"/home/grault/code/foo"}\n' \
    "$DEN_LOG_DIR" > "$HOME/.config/vigil/sessions/$DEN_SID2.json"
DEN_LOG2="$DEN_LOG_DIR/tools-$DEN_SID2.jsonl"

set +e
printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_use_id":"tu_first","tool_input":{"file_path":"%s/.claude/settings.json","content":"x"}}' \
    "$DEN_SID2" "$HOME" | "$DEN_HOOK" validate-settings-write >/dev/null 2>&1
set -e

py_err=$(mktemp)
if python3 -c "
import json, sys
with open('$DEN_LOG2') as f:
    lines = f.read().splitlines()
if len(lines) != 2:
    sys.exit('expected 2 lines (meta + denial), got %d' % len(lines))
meta = json.loads(lines[0])
if meta.get('event') != 'meta' or meta.get('schema_version') != 1:
    sys.exit('first line is not meta: %r' % meta)
den = json.loads(lines[1])
if den.get('event') != 'denied':
    sys.exit('second line is not denied: %r' % den)
if den.get('reason') != 'validate_settings_write':
    sys.exit('reason wrong: %r' % den)
if den.get('tool_use_id') != 'tu_first':
    sys.exit('tool_use_id wrong: %r' % den)
if not den.get('target', '').endswith('/.claude/settings.json'):
    sys.exit('target wrong: %r' % den)
" 2>"$py_err"; then
    pass "first denial to a fresh tools-JSONL emits meta record on line 1 and full denial on line 2"
else
    fail "meta-on-first-denial wrong; got: $(cat "$DEN_LOG2") | python stderr: $(cat "$py_err")"
fi
rm -f -- "$py_err"

# Restore HOME before cleanup.
HOME="$DEN_ORIG_HOME"
export HOME
rm -rf -- "$DEN_HOME"


# =====================================================================

if [[ $failed -eq 0 ]]; then
    [[ "${VIGIL_TESTS_VERBOSE:-0}" == "1" ]] && printf '\nvigil-hook: all tests passed.\n'
    exit 0
else
    printf '\nvigil-hook: failures present.\n' >&2
    exit 1
fi
