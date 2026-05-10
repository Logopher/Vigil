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
pass()    { printf '  PASS  %s\n' "$1"; }
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
# Slug derivation: cwd.replace('/', '-') — so cwd /home/grault/code/foo
# yields slug "-home-grault-code-foo". Cross-project means the target's
# project-slug component differs from the calling cwd's slug.

section "validate-memory-write — denies"

expect_deny validate-memory-write \
    'Cross-project memory write (slug mismatch)' \
    "$(printf '{"tool_name":"Write","cwd":"/home/grault/code/foo","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' "$HOME")"

expect_deny validate-memory-write \
    'Cross-project Edit' \
    "$(printf '{"tool_name":"Edit","cwd":"/home/grault/code/foo","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","old_string":"a","new_string":"b"}}' "$HOME")"

expect_deny validate-memory-write \
    'Cross-project MultiEdit' \
    "$(printf '{"tool_name":"MultiEdit","cwd":"/home/grault/code/foo","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md"}}' "$HOME")"

section "validate-memory-write — allows"

expect_allow validate-memory-write \
    'Same-project memory write' \
    "$(printf '{"tool_name":"Write","cwd":"/home/grault/code/foo","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-foo/memory/note.md","content":"x"}}' "$HOME")"

expect_allow validate-memory-write \
    'Project subdir that is not /memory/' \
    "$(printf '{"tool_name":"Write","cwd":"/home/grault/code/foo","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/cache/x.txt","content":"x"}}' "$HOME")"

expect_allow validate-memory-write \
    'File outside ~/.claude/projects/' \
    "$(printf '{"tool_name":"Write","cwd":"/home/grault/code/foo","tool_input":{"file_path":"%s/code/foo/x.md","content":"x"}}' "$HOME")"

expect_allow validate-memory-write \
    'Bash to memory path (not a write tool)' \
    "$(printf '{"tool_name":"Bash","cwd":"/home/grault/code/foo","tool_input":{"command":"cat %s/.claude/projects/-home-grault-code-bar/memory/note.md"}}' "$HOME")"

expect_allow validate-memory-write \
    'Missing cwd (fail-open)' \
    "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.claude/projects/-home-grault-code-bar/memory/note.md","content":"x"}}' "$HOME")"

expect_allow validate-memory-write \
    'Empty stdin (fail-open)' \
    ''

expect_allow validate-memory-write \
    'Garbage stdin (fail-open)' \
    'not-json{{{'


# =====================================================================

if [[ $failed -eq 0 ]]; then
    printf '\nvigil-hook: all tests passed.\n'
    exit 0
else
    printf '\nvigil-hook: failures present.\n' >&2
    exit 1
fi
