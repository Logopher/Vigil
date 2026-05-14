#!/usr/bin/env bash
# run-pyszz.sh — One-command B-SZZ + Vigil session-cost join.
#
# Generates a bugfix-commit input from the target repo, runs pyszz against
# a symlinked local checkout (no network clone — pyszz copytrees from the
# user's existing clone into its own tempdir, mutates that copy, cleans up),
# and caches the output keyed by HEAD SHA so reruns against the same HEAD
# skip pyszz entirely.
#
# With --join, pipes the cached pyszz output through scripts/join-sessions.py
# to produce per-bug session-cost rows.
#
# pyszz output accumulates in $PYSZZ_DIR/out/ across runs; this script
# captures the latest file by mtime after each invocation. Manage that
# directory yourself if it grows.

set -euo pipefail

repo="$PWD"
repo_name=""
cache_dir="$HOME/.cache/vigil/pyszz"
conf="${VIGIL_PYSZZ_CONF:-$HOME/.config/vigil/pyszz.yml}"
force=0
join=0
join_args=()

usage() {
    # Stream goes to stdout for --help, stderr for the error path. Caller
    # picks the right exit code; the function itself does not exit.
    cat <<'USAGE'
Usage: run-pyszz.sh [--repo DIR] [--repo-name OWNER/REPO] [--cache-dir DIR]
                    [--conf FILE] [--force] [--join] [-- <join-sessions args>]

Run pyszz B-SZZ on the target repo's fix commits and cache the output by
HEAD SHA. With --join, pipes the result through join-sessions.py.

Environment:
  PYSZZ_DIR          pyszz_v2 checkout (default: ~/code/pyszz_v2)
  VIGIL_PYSZZ_CONF   pyszz conf yml    (default: ~/.config/vigil/pyszz.yml)

Exit codes:
  0  success
  1  required dependency missing (PYSZZ_DIR, conf, or join-sessions.py)
  2  --repo is not a git repo / repo-name unresolvable / bad CLI usage
  3  pyszz invocation failed
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        repo="$2"; shift 2 ;;
        --repo-name)   repo_name="$2"; shift 2 ;;
        --cache-dir)   cache_dir="$2"; shift 2 ;;
        --conf)        conf="$2"; shift 2 ;;
        --force)       force=1; shift ;;
        --join)        join=1; shift ;;
        --)            shift; join_args=("$@"); break ;;
        -h|--help)     usage; exit 0 ;;
        *)
            printf 'run-pyszz: unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

PYSZZ_DIR="${PYSZZ_DIR:-$HOME/code/pyszz_v2}"
if [[ ! -f "$PYSZZ_DIR/main.py" ]]; then
    printf 'run-pyszz: pyszz_v2 not found at %s\n' "$PYSZZ_DIR" >&2
    printf 'Set PYSZZ_DIR to your pyszz_v2 checkout, or clone it:\n' >&2
    printf '  git clone https://github.com/grosa1/pyszz_v2 ~/code/pyszz_v2\n' >&2
    exit 1
fi

if [[ ! -f "$conf" ]]; then
    printf 'run-pyszz: pyszz config not found at %s\n' "$conf" >&2
    printf 'Pass --conf FILE or set VIGIL_PYSZZ_CONF.\n' >&2
    exit 1
fi

head_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
if [[ -z "$head_sha" ]]; then
    printf 'run-pyszz: %s is not a git repository\n' "$repo" >&2
    exit 2
fi

# Derive repo_name from origin if not given. Both forms supported:
#   git@github.com:owner/repo[.git]
#   https://github.com/owner/repo[.git]
if [[ -z "$repo_name" ]]; then
    origin_url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
    if [[ -z "$origin_url" ]]; then
        printf 'run-pyszz: no origin remote; pass --repo-name OWNER/REPO\n' >&2
        exit 2
    fi
    case "$origin_url" in
        git@*:*)        repo_name="${origin_url#*:}" ;;
        https://*/*/*)  repo_name="${origin_url#https://*/}" ;;
        *)
            printf 'run-pyszz: cannot parse origin URL: %s\n' "$origin_url" >&2
            printf 'Pass --repo-name OWNER/REPO explicitly.\n' >&2
            exit 2
            ;;
    esac
    repo_name="${repo_name%.git}"
fi
if [[ ! "$repo_name" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    printf 'run-pyszz: invalid repo-name: %s (expected OWNER/REPO)\n' "$repo_name" >&2
    exit 2
fi

# Cache key keeps owner/repo in the filename (slash → "__") so the cache
# works as a flat directory.
key="${repo_name//\//__}-${head_sha}"
cache_out="$cache_dir/pyszz-$key.json"
cache_input="$cache_dir/bugfix-$key.json"

mkdir -p "$cache_dir"

if [[ -f "$cache_out" && $force -eq 0 ]]; then
    : # cache hit — fall through to optional --join
else
    # Build the bugfix input. SHAs are [0-9a-f]+ and repo_name was validated
    # above, so direct interpolation into JSON is safe (no escaping needed).
    fixes=$(git -C "$repo" log --grep='^fix[:(]' --format='%H' 2>/dev/null || true)
    {
        printf '['
        first=1
        while IFS= read -r sha; do
            [[ -z "$sha" ]] && continue
            if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
            printf '{"repo_name":"%s","fix_commit_hash":"%s"}' "$repo_name" "$sha"
        done <<< "$fixes"
        printf ']'
    } > "$cache_input"

    # Symlink user's checkout into pyszz's expected <owner>/<repo> layout.
    # pyszz's AbstractSZZ.__init__ copytrees from this path into its own
    # tempdir; the user's working tree is never mutated.
    owner="${repo_name%/*}"
    name="${repo_name#*/}"
    repos_dir="$cache_dir/repos"
    mkdir -p "$repos_dir/$owner"
    ln -sfn "$repo" "$repos_dir/$owner/$name"

    # pyszz's out_dir is hardcoded relative to CWD, so we cd into PYSZZ_DIR.
    # main.py argv: <bugfix.json> <conf.yml> [repos_dir]
    if ! ( cd "$PYSZZ_DIR" && python3 main.py "$cache_input" "$conf" "$repos_dir" ); then
        printf 'run-pyszz: pyszz invocation failed\n' >&2
        exit 3
    fi

    # Capture the latest pyszz output file by mtime. pyszz writes
    # bic_<conf-base>_<ts>[.NN].json; mtime sort handles the .NN collision tail.
    # find emits mtime-prefixed paths so sort -nr picks the newest; absent
    # out/ directory or empty match yields an empty string handled below.
    latest=$(find "$PYSZZ_DIR/out" -maxdepth 1 -type f -name 'bic_*.json' \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n 1 | cut -d' ' -f2- || true)
    if [[ -z "$latest" || ! -f "$latest" ]]; then
        printf 'run-pyszz: pyszz produced no output in %s/out/\n' "$PYSZZ_DIR" >&2
        exit 3
    fi
    cp -- "$latest" "$cache_out"
fi

if [[ $join -eq 1 ]]; then
    join_script="$HOME/.config/vigil/scripts/join-sessions.py"
    if [[ ! -f "$join_script" ]]; then
        # Fall back to the in-repo path so the script is usable pre-install.
        join_script="$(dirname "${BASH_SOURCE[0]}")/join-sessions.py"
    fi
    if [[ ! -f "$join_script" ]]; then
        printf 'run-pyszz: join-sessions.py not found\n' >&2
        exit 1
    fi
    exec python3 "$join_script" --pyszz "$cache_out" --repo "$repo" "${join_args[@]}"
fi

printf 'pyszz output: %s\n' "$cache_out"
