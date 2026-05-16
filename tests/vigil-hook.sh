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

if [[ $failed -eq 0 ]]; then
    [[ "${VIGIL_TESTS_VERBOSE:-0}" == "1" ]] && printf '\nvigil-hook: all tests passed.\n'
    exit 0
else
    printf '\nvigil-hook: failures present.\n' >&2
    exit 1
fi
