#!/usr/bin/env bash
# Sanity-check an installed claude-config tree. Reports PASS / WARN /
# FAIL per check; exits 0 if no FAIL, 1 otherwise. Read-only — never
# modifies any file. Intended to be safe to run at any time.
#
# Targets the live install at ~/.claude and ~/.config/claude-config,
# not the repo. Re-run after any install / update / system change.
set -uo pipefail
shopt -s nullglob

DEST_DIR="${HOME}/.config/claude-config"
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
    "$DEST_DIR/claude-aliases.sh" \
    "$DEST_DIR/scripts/filter-sandbox-denies.py" \
    "$DEST_DIR/profiles/default" \
    "$CLAUDE_DIR" \
    "$SETTINGS"
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
    for p in "$DEST_DIR/policies/"*.json; do
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
section "Hook scripts"

if [[ -f "$SETTINGS" && $have_python3 -eq 1 ]]; then
    # Extract every command path under settings.hooks.<event>[].hooks[]
    # whose type is "command". One path per line.
    # Assumes hook commands are bare paths (matches the current
    # settings.template.json convention). If a hook ever needs args or
    # an env-var prefix, this extractor needs updating to handle that.
    hook_paths=$(python3 - "$SETTINGS" <<'PY'
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
        while IFS= read -r hp; do
            if [[ ! -e "$hp" ]]; then
                report FAIL "hook missing: $(display_path "$hp")"
            elif [[ ! -x "$hp" ]]; then
                report FAIL "hook not executable: $(display_path "$hp")"
            else
                report PASS "$(display_path "$hp")"
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
section "Shell rc sources claude-aliases.sh"

aliases_path="$DEST_DIR/claude-aliases.sh"
sourced_in=()
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
    if [[ -f "$rc" ]] && grep -q "claude-aliases.sh" "$rc" 2>/dev/null; then
        sourced_in+=("$(display_path "$rc")")
    fi
done
if [[ ${#sourced_in[@]} -gt 0 ]]; then
    report PASS "claude-aliases.sh referenced in: ${sourced_in[*]}"
else
    report WARN "claude-aliases.sh not referenced in ~/.bashrc, ~/.bash_profile, ~/.zshrc, or ~/.profile (the wrapper that records sessions will not be active)"
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
