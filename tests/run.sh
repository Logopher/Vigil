#!/usr/bin/env bash
# Top-level test runner. Executes every tests/<tier>.sh in order and
# exits non-zero if any tier fails.
#
# By default, suppresses PASS lines (and the "All X tests passed."
# per-suite summaries) so failures stand out. Pass -v / --verbose to
# restore the loud output: PASS, SKIP, and per-suite summaries all
# print. The flag works by exporting VIGIL_TESTS_VERBOSE=1 to every
# suite; the helpers in each tests/*.sh and tests/*.py read it.
set -euo pipefail
shopt -s nullglob

verbose=0
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) verbose=1 ;;
        -h|--help)
            cat <<'USAGE'
Usage: tests/run.sh [-v|--verbose]

Runs every tests/*.sh and tests/*.py suite in lexical order.
By default prints only FAIL lines, section headers, suite banners,
and the final summary — passing tests are silent so failures are
easy to find. Pass -v / --verbose to also print PASS / SKIP lines
and per-suite "All X tests passed." summaries.
USAGE
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done
export VIGIL_TESTS_VERBOSE="$verbose"

cd "$(dirname "$0")"

failed=()
for suite in ./*.sh ./*.py; do
    name="$(basename "$suite")"
    [[ "$name" == "run.sh" ]] && continue
    printf '\n### %s ###\n' "$name"
    case "$suite" in
        *.sh) runner=(bash "$suite") ;;
        *.py) runner=(python3 "$suite") ;;
    esac
    if "${runner[@]}"; then
        :
    else
        failed+=("$name")
    fi
done

printf '\n==========\n'
if [[ ${#failed[@]} -eq 0 ]]; then
    echo "All suites passed."
    exit 0
else
    echo "Failed suites: ${failed[*]}"
    exit 1
fi
