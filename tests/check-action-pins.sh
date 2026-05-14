#!/usr/bin/env bash
# Verify all GitHub Actions referenced in .github/workflows/ are pinned
# by full SHA (40 hex chars). Local actions (uses: ./... or ../...) are
# exempt. Mirrors the policy named in CLAUDE.md "Editing conventions":
# every third-party action must be pinned as `<sha> # vX.Y.Z`.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)" \
    || { printf 'FATAL: cannot resolve repo root from %s\n' "$0" >&2; exit 1; }
WORKFLOWS_DIR="$REPO_DIR/.github/workflows"

failed=0
pass() { [[ "${VIGIL_TESTS_VERBOSE:-0}" == "1" ]] && printf '  PASS  %s\n' "$1"; return 0; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }

if [[ ! -d "$WORKFLOWS_DIR" ]]; then
    pass "no .github/workflows/ directory; nothing to check"
    exit 0
fi

files=("$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml)
if [[ ${#files[@]} -eq 0 ]]; then
    pass "no workflow files in .github/workflows/"
    exit 0
fi

for f in "${files[@]}"; do
    rel="${f#"$REPO_DIR/"}"
    while IFS=: read -r lineno content; do
        # Strip leading whitespace, leading "- ", and the "uses:" key.
        body="${content#"${content%%[![:space:]]*}"}"
        body="${body#- }"
        body="${body#uses:}"
        body="${body#"${body%%[![:space:]]*}"}"

        # Local actions (uses: ./...) are exempt; CLAUDE.md "Editing
        # conventions" pins this exemption to the leading-./ form.
        case "$body" in
            ./*) pass "$rel:$lineno local action exempt ($body)"; continue ;;
        esac

        # Extract the @ref portion (after last '@'), stopping at space/tab/#.
        ref="${body##*@}"
        ref="${ref%% *}"
        ref="${ref%%	*}"
        ref="${ref%%#*}"

        # Accept upper- or lowercase hex; GitHub treats both as valid.
        if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
            pass "$rel:$lineno $ref"
        else
            fail "$rel:$lineno not pinned by full SHA (found '$ref'); use '<sha> # vX.Y.Z'"
        fi
    done < <(grep -nE '^[[:space:]]*-[[:space:]]*uses:' "$f" || true)
done

if [[ $failed -eq 0 && "${VIGIL_TESTS_VERBOSE:-0}" == "1" ]]; then
    echo "All workflow action pins verified."
fi

exit "$failed"
