#!/usr/bin/env bash
# Tier 1 static checks: JSON validity, shell syntax, matcher syntax,
# template marker leakage. No installation or execution; catches common
# regressions in isolation.
set -uo pipefail
shopt -s nullglob globstar

cd "$(dirname "$0")/.."

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

# Enumerate files once. Excluded paths:
#   .git/            — git internals
#   tests/           — the tests themselves
#   .claude/         — sandbox-masked placeholders (see default profile CLAUDE.md)
#   ./.mcp.json      — sandbox-masked placeholder
# `-type f` is also requested, though some sandbox implementations produce
# file types that do not match -type f or -type c cleanly.
find_tracked() {
    find . -type f -name "$1" \
        -not -path './.git/*' \
        -not -path './tests/*' \
        -not -path './.claude/*' \
        -not -path './.mcp.json' \
        | sort
}
mapfile -t json_files < <(find_tracked '*.json')
mapfile -t shell_files < <(find_tracked '*.sh')

# --- 1. JSON validity ---
section "JSON validity"
for f in "${json_files[@]}"; do
    if python3 -c "import json,sys; json.load(open('$f'))" >/dev/null 2>&1; then
        pass "$f"
    else
        fail "$f does not parse as JSON"
    fi
done

# --- 2. Shell script syntax ---
section "Shell script syntax"
for f in "${shell_files[@]}"; do
    if bash -n "$f" 2>/dev/null; then
        pass "$f"
    else
        fail "$f has a syntax error"
        bash -n "$f" || true
    fi
done

# --- 3. Matcher syntax ---
# Detect `Bash(singleword *)` (space form) which should be `Bash(singleword:*)`.
# Multi-token prefixes like `Bash(git checkout -- *)` are intentionally
# excluded — `--` is a literal end-of-options marker, not a wildcard.
section "Matcher syntax (no single-word space-form)"
if [[ ${#json_files[@]} -gt 0 ]]; then
    offenders="$(grep -En '"Bash\([a-zA-Z][a-zA-Z0-9_-]* \*\)"' "${json_files[@]}" || true)"
else
    offenders=""
fi
if [[ -z "$offenders" ]]; then
    pass "no space-form single-word matchers"
else
    fail "space-form matchers found; use colon form (Bash(cmd:*)):"
    printf '%s\n' "$offenders" >&2
fi

# --- 4. Template marker leakage ---
# Live (non-template) JSON files must not contain {{...}} markers.
section "Template marker leakage"
leaked=0
for f in "${json_files[@]}"; do
    case "$f" in
        *.template.json) continue ;;
    esac
    if grep -Hn '{{[^}]*}}' "$f" >/dev/null 2>&1; then
        fail "$f contains template markers"
        grep -Hn '{{[^}]*}}' "$f" >&2
        leaked=1
    fi
done
[[ $leaked -eq 0 ]] && pass "no template markers in live JSON files"

exit $failed
