#!/usr/bin/env bash
# Sanity-check an installed Vigil tree. Reports PASS / WARN /
# FAIL per check; exits 0 if no FAIL, 1 otherwise. Read-only — never
# modifies any file. Intended to be safe to run at any time.
#
# Targets the live install at ~/.claude and ~/.config/vigil,
# not the repo. Re-run after any install / update / system change.
set -uo pipefail
shopt -s nullglob

DEST_DIR="${HOME}/.config/vigil"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"

display_path() { printf '%s' "${1/#$HOME/\~}"; }

failures=0
warnings=0
report() {
    local level="$1" msg="$2"
    case "$level" in
        PASS) printf '  PASS  %s\n' "$msg" ;;
        WARN) printf '  WARN  %s\n' "$msg"; warnings=$((warnings + 1)) ;;
        FAIL) printf '  FAIL  %s\n' "$msg" >&2; failures=$((failures + 1)) ;;
    esac
}
section() { printf '\n-- %s --\n' "$1"; }

# -----------------------------------------------------------------------------
section "Prerequisites"

if command -v python3 >/dev/null 2>&1; then
    report PASS "python3 available"
    have_python3=1
else
    report FAIL "python3 not found in PATH (required by hooks and filter-sandbox-denies)"
    have_python3=0
fi

case "$(uname -s)" in
    Linux)
        if command -v bwrap >/dev/null 2>&1; then
            report PASS "bwrap available ($(bwrap --version 2>/dev/null | head -1))"
        else
            report FAIL "bwrap not found in PATH (sandbox cannot start)"
        fi
        ;;
    *)
        report WARN "bwrap check skipped on $(uname -s) (sandbox is Linux-only)"
        ;;
esac

# -----------------------------------------------------------------------------
section "Installed tree"

for path in \
    "$DEST_DIR/vigil-aliases.sh" \
    "$DEST_DIR/scripts/filter-sandbox-denies.py" \
    "$DEST_DIR/profiles/default" \
    "$CLAUDE_DIR" \
    "$SETTINGS" \
    "${CLAUDE_DIR}/settings.local.json"
do
    if [[ -e "$path" || -L "$path" ]]; then
        report PASS "$(display_path "$path")"
    else
        report FAIL "missing: $(display_path "$path")"
    fi
done

if [[ ! -d "$DEST_DIR/policies" ]]; then
    report FAIL "$(display_path "$DEST_DIR/policies") directory missing"
else
    policy_count=0
    for _ in "$DEST_DIR/policies/"*.json; do
        policy_count=$((policy_count + 1))
    done
    if [[ $policy_count -gt 0 ]]; then
        report PASS "$policy_count policy file(s) installed under $(display_path "$DEST_DIR/policies")"
    else
        report FAIL "no policy files under $(display_path "$DEST_DIR/policies")"
    fi
fi

# -----------------------------------------------------------------------------
section "settings.json"

if [[ -f "$SETTINGS" && $have_python3 -eq 1 ]]; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS" >/dev/null 2>&1; then
        report PASS "valid JSON"
    else
        report FAIL "settings.json is not valid JSON"
    fi
else
    report WARN "skipping JSON / hook checks (settings.json or python3 missing)"
fi

# -----------------------------------------------------------------------------
section "Hook commands"

if [[ -f "$SETTINGS" && $have_python3 -eq 1 ]]; then
    # Extract the first token of every command-type hook under
    # settings.hooks.<event>[].hooks[]. Deduplicated: the dispatcher
    # `vigil-hook` appears across many entries; one PASS line per unique
    # command is enough. Absolute paths and bare PATH-resolved names are
    # both supported (the harness invokes either form).
    hook_paths=$(python3 - "$SETTINGS" <<'PY' | sort -u
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
for event, entries in (s.get("hooks") or {}).items():
    for entry in entries or []:
        for h in entry.get("hooks", []):
            if h.get("type") == "command":
                cmd = h.get("command", "")
                path = cmd.split()[0] if cmd else ""
                if path:
                    print(path)
PY
)
    if [[ -z "$hook_paths" ]]; then
        report WARN "no command-type hooks declared in settings.json"
    else
        while IFS= read -r tok; do
            if [[ "$tok" == /* ]]; then
                # Absolute path: check directly.
                if [[ ! -e "$tok" ]]; then
                    report FAIL "hook missing: $(display_path "$tok")"
                elif [[ ! -x "$tok" ]]; then
                    report FAIL "hook not executable: $(display_path "$tok")"
                else
                    report PASS "$(display_path "$tok")"
                fi
            else
                # Bare name: resolve via PATH. `command -v` returns empty
                # for both "not on PATH" and "absolute path that doesn't
                # exist", but the absolute-path branch above already
                # handles the latter — empty here means truly not on PATH.
                resolved=$(command -v -- "$tok" 2>/dev/null || true)
                if [[ -z "$resolved" ]]; then
                    report FAIL "hook command not on PATH: $tok"
                elif [[ ! -x "$resolved" ]]; then
                    report FAIL "hook not executable: $(display_path "$resolved")"
                else
                    report PASS "$tok ($(display_path "$resolved"))"
                fi
            fi
        done <<< "$hook_paths"
    fi
fi

# -----------------------------------------------------------------------------
section "Sandbox deny lists in sync"

filter_script="$DEST_DIR/scripts/filter-sandbox-denies.py"
if [[ -f "$filter_script" && -f "$SETTINGS" && $have_python3 -eq 1 ]]; then
    out=$(python3 "$filter_script" --check "$SETTINGS" 2>&1)
    rc=$?
    case $rc in
        0) report PASS "denyRead/denyWrite match current filesystem state" ;;
        1)
            report FAIL "deny lists are stale; re-run install.sh or filter-sandbox-denies.py"
            while IFS= read -r line; do
                printf '         %s\n' "$line" >&2
            done <<< "$out"
            ;;
        *)
            report FAIL "filter-sandbox-denies --check exited $rc"
            printf '%s\n' "$out" >&2
            ;;
    esac
else
    report WARN "skipping deny-list check (filter script, settings.json, or python3 missing)"
fi

# -----------------------------------------------------------------------------
section "Shell rc sources vigil-aliases.sh"

sourced_in=()
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
    if [[ -f "$rc" ]] && grep -q "vigil-aliases.sh" "$rc" 2>/dev/null; then
        sourced_in+=("$(display_path "$rc")")
    fi
done
if [[ ${#sourced_in[@]} -gt 0 ]]; then
    report PASS "vigil-aliases.sh referenced in: ${sourced_in[*]}"
else
    report WARN "vigil-aliases.sh not referenced in ~/.bashrc, ~/.bash_profile, ~/.zshrc, or ~/.profile (the wrapper that records sessions will not be active)"
fi

# -----------------------------------------------------------------------------
printf '\n==========\n'
if [[ $failures -eq 0 ]]; then
    if [[ $warnings -eq 0 ]]; then
        echo "doctor: all checks passed."
    else
        echo "doctor: passed with $warnings warning(s)."
    fi
    exit 0
else
    echo "doctor: $failures failure(s), $warnings warning(s)."
    exit 1
fi
