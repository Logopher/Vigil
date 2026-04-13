#!/usr/bin/env bash
# Tier 3 policy semantics: JSON-structural invariants across the default
# profile and the three shipped policies. Verifies deny-list consistency,
# allow/deny non-contradiction, and that the shipped policies compose
# cleanly with the profile.
#
# Requires: jq
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP  jq not installed; Tier 3 semantic checks require jq." >&2
    exit 0
fi

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

PROFILE="$REPO_DIR/profiles/default/settings.template.json"
DEV="$REPO_DIR/policies/dev.template.json"
STRICT="$REPO_DIR/policies/strict.template.json"
YOLO="$REPO_DIR/policies/yolo.json"

# -----------------------------------------------------------------------------
section "Profile has expected top-level keys"
for key in sandbox permissions hooks; do
    if jq -e "has(\"$key\")" "$PROFILE" >/dev/null; then
        pass "profile has key: $key"
    else
        fail "profile missing key: $key"
    fi
done

# -----------------------------------------------------------------------------
section "Deny baseline consistency (profile vs. strict)"
profile_deny=$(jq -c '.permissions.deny // [] | sort' "$PROFILE")
strict_deny=$(jq -c '.permissions.deny // [] | sort' "$STRICT")
if [[ "$profile_deny" == "$strict_deny" ]]; then
    pass "profile baseline deny matches strict policy deny"
else
    fail "profile and strict deny lists differ"
    diff \
        <(jq -r '.permissions.deny // [] | sort | .[]' "$PROFILE") \
        <(jq -r '.permissions.deny // [] | sort | .[]' "$STRICT") \
        >&2 || true
fi

# -----------------------------------------------------------------------------
section "Dev deny is a superset of profile deny"
missing=0
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if ! jq -e --arg e "$entry" '.permissions.deny // [] | any(. == $e)' "$DEV" >/dev/null; then
        fail "dev missing baseline deny: $entry"
        missing=1
    fi
done < <(jq -r '.permissions.deny[]? // empty' "$PROFILE")
[[ $missing -eq 0 ]] && pass "dev contains every baseline deny"

# -----------------------------------------------------------------------------
section "Yolo retains minimum catastrophe guards"
for guard in "Bash(rm:*)" "Bash(sudo:*)"; do
    if jq -e --arg g "$guard" '.permissions.deny // [] | any(. == $g)' "$YOLO" >/dev/null; then
        pass "yolo denies $guard"
    else
        fail "yolo missing guard: $guard"
    fi
done

# -----------------------------------------------------------------------------
section "No policy allow conflicts with profile deny (exact-string)"
for policy in "$DEV" "$STRICT" "$YOLO"; do
    name=$(basename "$policy")
    conflict_count=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if jq -e --arg e "$entry" '.permissions.deny // [] | any(. == $e)' "$PROFILE" >/dev/null; then
            fail "$name: allow entry '$entry' matches profile deny"
            conflict_count=$((conflict_count + 1))
        fi
    done < <(jq -r '.permissions.allow[]? // empty' "$policy")
    [[ $conflict_count -eq 0 ]] && pass "$name: no allow entries match profile deny (exact-string)"
done

# -----------------------------------------------------------------------------
section "Deep merge produces valid JSON with expected top-level shape"
# jq's `*` is a recursive merge; the result should retain sandbox and
# hooks from the profile while the policy's permissions overlay. This
# does not claim to match Claude Code's actual merge semantics — it
# verifies the two files can coexist without type conflicts.
for policy in "$DEV" "$STRICT" "$YOLO"; do
    name=$(basename "$policy")
    if ! merged=$(jq -s '.[0] * .[1]' "$PROFILE" "$policy" 2>/dev/null); then
        fail "$name: jq merge failed (type conflict?)"
        continue
    fi
    missing_keys=()
    for key in sandbox permissions hooks; do
        if ! printf '%s' "$merged" | jq -e "has(\"$key\")" >/dev/null; then
            missing_keys+=("$key")
        fi
    done
    if [[ ${#missing_keys[@]} -eq 0 ]]; then
        pass "$name: merges with profile retaining all top-level keys"
    else
        fail "$name: merged result missing keys: ${missing_keys[*]}"
    fi
done

exit $failed
