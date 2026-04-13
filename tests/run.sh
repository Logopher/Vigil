#!/usr/bin/env bash
# Top-level test runner. Executes every tests/<tier>.sh in order and
# exits non-zero if any tier fails.
set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")"

failed=()
for suite in ./*.sh; do
    name="$(basename "$suite")"
    [[ "$name" == "run.sh" ]] && continue
    printf '\n### %s ###\n' "$name"
    if bash "$suite"; then
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
