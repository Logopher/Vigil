# shellcheck shell=bash
# Curated env-var allowlist for the vigil wrappers. Vars not on this
# list (and not matching LC_* or GIT_*) are unset before launching
# Claude — the default sandbox covers filesystem reads but env vars
# are inherited by every child process unless explicitly cleared.
#
# Add to this list (in your own ~/.bashrc, after sourcing this file)
# to pass through additional non-secret vars, e.g.:
#   _vigil_env_allowlist+=(AWS_PROFILE AWS_REGION)
_vigil_env_allowlist=(
    HOME PATH USER LOGNAME SHELL PWD TMPDIR
    TERM COLORTERM NO_COLOR CLICOLOR
    LANG LC_ALL TZ
    SSH_AUTH_SOCK SSH_AGENT_PID
    GPG_TTY GNUPGHOME
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
    EDITOR VISUAL PAGER
    DISPLAY WAYLAND_DISPLAY XAUTHORITY
    CLAUDE_CONFIG_DIR
)

_vigil_run_with_logging() (
    # Subshell so env scrubbing and exports don't leak back to the
    # interactive shell that invoked us.

    # Refresh sandbox.filesystem.deny{Read,Write} before each session.
    # Paths that have become symlinks, disappeared, or changed type
    # would otherwise cause bubblewrap to fail closed for every
    # subprocess. Cheap; silently skipped if the filter is missing.
    local filter="$HOME/.config/vigil/scripts/filter-sandbox-denies.py"
    if [[ -f "$filter" ]] && command -v python3 >/dev/null 2>&1; then
        python3 "$filter" >/dev/null || true
    fi

    # Strip env vars not on the allowlist. compgen -v lists every set
    # variable; unset on read-only or special vars fails harmlessly.
    # Membership check uses string match (not associative array) for
    # bash 3.2 compatibility — macOS ships /bin/bash 3.2.
    # Loop-locals use the _vigil_ prefix so the loop doesn't clobber
    # itself when it iterates over them via compgen -v.
    local _vigil_allow_str=" ${_vigil_env_allowlist[*]} "
    local _vigil_v
    while IFS= read -r _vigil_v; do
        [[ "$_vigil_allow_str" == *" $_vigil_v "* ]] && continue
        [[ "$_vigil_v" == LC_* ]] && continue
        [[ "$_vigil_v" == GIT_* ]] && continue
        [[ "$_vigil_v" == BASH* || "$_vigil_v" == _ || "$_vigil_v" == _vigil_* ]] && continue
        unset "$_vigil_v" 2>/dev/null || true
    done < <(compgen -v)

    # Optional post-scrub env injection. Lets users wire up opt-in
    # vars — notably an ssh-agent socket for signed commits — without
    # leaking them into every interactive shell via ~/.bashrc. The
    # file is sourced as shell, so keep it to `export VAR=value` lines.
    # Trust note: this is the one file in ~/.config/vigil/ whose
    # contents are executed, not read as data. Treat it like ~/.bashrc;
    # Vigil's threat model assumes the operator's home is not hostile.
    if [[ -f "$HOME/.config/vigil/signing.env" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.config/vigil/signing.env"
    fi

    VIGIL_SESSION_ID=$(date +%Y%m%d-%H%M%S)
    export VIGIL_SESSION_ID
    export VIGIL_LOG_DIR="$HOME/vigil-logs"
    mkdir -p "$VIGIL_LOG_DIR"

    # Extract active policy name from the --settings flag in $@.
    local active_policy="" _prev=""
    for _arg in "$@"; do
        [[ "$_prev" == "--settings" ]] && { active_policy=$(basename "${_arg%.json}"); break; }
        _prev="$_arg"
    done

    # Capture git state before the session starts so the sidecar reflects
    # the repo state Claude was operating against, not the post-session state.
    # _git_repo and _git_branch also form the filename suffix for browsability
    # and are embedded in the per-session JSON read by hooks.
    # Detached HEAD (branch == "HEAD") and non-git directories produce no suffix.
    local _git_repo _git_branch _git_head _suffix=""
    _git_repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)
    _git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null \
        | sed 's/[^a-zA-Z0-9._-]/-/g' || true)
    _git_head=$(git rev-parse HEAD 2>/dev/null || true)
    [[ -n "$_git_repo" && "$_git_repo" != "." \
        && -n "$_git_branch" && "$_git_branch" != "HEAD" ]] \
        && _suffix="-${_git_repo}-${_git_branch}"

    # Per-session handoff file. Hooks read this through a /proc-based
    # bridge keyed on VIGIL_WRAPPER_PID (see scripts/vigil-hook), so each
    # concurrent vigil shell gets its own file — the previous shared
    # ~/.config/vigil/.vigil-session singleton silently raced when two
    # sessions overlapped. BASHPID is the subshell's own PID (bash 4+);
    # the ${...:-$$} fallback gives bash 3.2 (macOS) the parent shell's
    # PID, which preserves per-terminal uniqueness but loses concurrency
    # within one terminal — acceptable since the /proc bridge is also
    # Linux-only (see COMPATIBILITY.md).
    local _wrapper_pid="${BASHPID:-$$}"
    export VIGIL_WRAPPER_PID="$_wrapper_pid"

    local _sessions_dir="$HOME/.config/vigil/sessions"
    if ! mkdir -p "$_sessions_dir" 2>/dev/null; then
        echo "vigil: warning: could not create $_sessions_dir — hooks will run without session context" >&2
    fi
    # chmod is reported on failure (no 2>/dev/null) so wrong-permission
    # situations are visible — falling back silently would mean a hook
    # reads or writes a file in a world-readable dir without warning.
    chmod 700 "$_sessions_dir" || true

    local _session_file="$_sessions_dir/wrapper-$_wrapper_pid.json"
    local _session_tmp _launched_at _safe_policy="" _safe_repo="" _safe_branch="" _safe_cwd=""
    _launched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Validate every embedded value before printf-ing it into JSON.
    # VIGIL_SESSION_ID (date format) and _launched_at (ISO 8601) are safe as-is.
    # VIGIL_LOG_DIR is derived from $HOME which has no JSON-unsafe chars on Linux.
    [[ "$active_policy" =~ ^[a-zA-Z0-9_-]+$ ]] && _safe_policy="$active_policy"
    [[ "$_git_repo" =~ ^[a-zA-Z0-9._-]+$ ]] && _safe_repo="$_git_repo"
    [[ "$_git_branch" =~ ^[a-zA-Z0-9._-]+$ ]] && _safe_branch="$_git_branch"
    # Launch CWD is read by vigil-hook validate-memory-write to compute
    # the session's project slug. Sourcing it from session context (not
    # from event_data['cwd']) keeps the slug stable across `cd` calls
    # the LLM may issue mid-session. Regex matches the conservative
    # JSON-safe subset shared by _safe_repo/_safe_branch above plus `/`;
    # paths containing spaces, quotes, `@`, `:`, or other characters that
    # would need JSON escaping silently leave _safe_cwd empty, and the
    # hook fails open. That is a deliberate trade — false-open on an
    # exotic path is preferable to corrupting the session JSON.
    [[ "$PWD" =~ ^[a-zA-Z0-9._+/-]+$ ]] && _safe_cwd="$PWD"
    # Atomic write (temp + rename) prevents partial-read by a hook that fires
    # immediately at SessionStart. Trap registered only on successful write so
    # a failed mktemp does not delete a sibling session's wrapper file.
    # Function runs in a subshell (...) — EXIT fires when the whole session
    # ends, after script(1) returns and all post-processing completes.
    # The bridged file at <harness_session_id>.json is owned by SessionEnd;
    # this trap only removes the wrapper-<pid>.json if SessionStart never
    # promoted it (e.g., claude crashed before any hook fired), and the
    # bridge marker the SessionStart hook drops for post-exec lookup.
    local _bridge_marker="$VIGIL_LOG_DIR/.bridge-$VIGIL_SESSION_ID"
    if _session_tmp="$(mktemp "$_sessions_dir/.wrapper-$_wrapper_pid.XXXXXX" 2>/dev/null)"; then
        if printf '{\n  "vigil_session_id": "%s",\n  "log_dir": "%s",\n  "policy": "%s",\n  "launched_at": "%s",\n  "repo": "%s",\n  "branch": "%s",\n  "cwd": "%s"\n}\n' \
                "$VIGIL_SESSION_ID" "$VIGIL_LOG_DIR" "$_safe_policy" "$_launched_at" \
                "$_safe_repo" "$_safe_branch" "$_safe_cwd" \
                > "$_session_tmp" \
            && mv -- "$_session_tmp" "$_session_file"; then
            trap 'rm -f -- "$_session_file" "$_bridge_marker"' EXIT
        else
            rm -f -- "$_session_tmp"
        fi
    else
        echo "vigil: warning: could not create session marker in $_sessions_dir — hooks will run without session context" >&2
    fi

    local logfile="$VIGIL_LOG_DIR/session-${VIGIL_SESSION_ID}${_suffix}.log"
    case "$(uname)" in
        Darwin|*BSD)
            # BSD script(1): `script [-q] file command...`
            script -q "$logfile" command claude "$@"
            ;;
        *)
            # util-linux script(1): `script -B file -c cmd`
            # printf '%q' (bash 4+) shell-escapes all words so spaces and
            # metacharacters survive re-parsing. script(1) interprets the
            # -c string via sh, not bash; printf '%q' uses $'...' ANSI-C
            # quoting for control characters, which is bash-only syntax.
            # In practice Claude arguments never contain control characters,
            # so sh -c handles the output correctly for all real inputs.
            script -B "$logfile" -c "$(printf '%q ' command claude "$@")"
            ;;
    esac

    # Capture HEAD and commits made during the session so the SZZ join in
    # scripts/join-sessions.py can resolve session→inducing-commit by exact
    # SHA lookup instead of the closest-author-timestamp heuristic. Both
    # variables stay empty (and the sidecar emits null) when pre-session HEAD
    # was unresolvable or when the session-end git rev-parse fails — e.g.,
    # non-git directory, or repo deleted mid-session.
    local _ended_at_git_head="" _commits_during_session=""
    if [[ -n "$_git_head" ]]; then
        _ended_at_git_head=$(git rev-parse HEAD 2>/dev/null || true)
        if [[ -n "$_ended_at_git_head" ]]; then
            # git log range is empty when HEAD is unchanged. Force-push or
            # rebase mid-session can leave _git_head unreachable; the range
            # then errors and produces an empty string, which the consumer
            # interprets the same as "no commits made."
            _commits_during_session=$(git log "$_git_head..HEAD" --format=%H 2>/dev/null || true)
        fi
    fi

    # Write sidecar metadata JSON. started_at is derived from VIGIL_SESSION_ID
    # (local time, no timezone suffix) so it matches the filename even if the
    # session ran past midnight. ended_at is captured immediately after script(1)
    # exits, so it reflects wall-clock session end in the same local-time format.
    # ccusage_jsonl is resolved via the harness session ID written to the
    # ~/vigil-logs/.bridge-<vigil_session_id> marker by vigil-hook at
    # SessionStart; falls back to a most-recent-mtime scan when the marker
    # is absent (e.g., SessionStart didn't fire or claude crashed before it).
    if command -v python3 >/dev/null 2>&1; then
        local _sid="$VIGIL_SESSION_ID"
        local _started_at="${_sid:0:4}-${_sid:4:2}-${_sid:6:2}T${_sid:9:2}:${_sid:11:2}:${_sid:13:2}"
        local _ended_at; _ended_at=$(date +%Y-%m-%dT%H:%M:%S)  # split form preserves exit status
        python3 -c "
import json, re, sys, os, glob as _g
# argv[9]  = VIGIL_LOG_DIR
# argv[10] = VIGIL_SESSION_ID
_UUID_RE = re.compile(r'^[0-9a-fA-F-]+\$')
ccusage_jsonl = ''
harness_sid = ''
bridge_marker = os.path.join(sys.argv[9], f'.bridge-{sys.argv[10]}')
try:
    with open(bridge_marker) as f:
        candidate = f.read().strip()
    # Guard against unexpected content in case the marker is ever corrupted;
    # the value is written by vigil-hook (trusted) but a regex check is cheap.
    if _UUID_RE.match(candidate):
        harness_sid = candidate
        matches = _g.glob(os.path.expanduser(
            f'~/.claude/projects/*/{harness_sid}.jsonl'))
        if matches:
            ccusage_jsonl = matches[0]
except OSError:
    pass
if not ccusage_jsonl:
    files = _g.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'),
                    recursive=True)
    try:
        ccusage_jsonl = max(files, key=os.path.getmtime) if files else ''
    except OSError:
        ccusage_jsonl = ''
end_head = sys.argv[7] or None
commits_str = sys.argv[8]
if commits_str:
    commits_during_session = commits_str.splitlines()
elif end_head is not None:
    commits_during_session = []
else:
    commits_during_session = None
print(json.dumps({
    'cwd':                    sys.argv[1],
    'git_branch':             sys.argv[2],
    'git_head':               sys.argv[3],
    'active_policy':          sys.argv[4],
    'started_at':             sys.argv[5],
    'ended_at':               sys.argv[6],
    'ended_at_git_head':      end_head,
    'commits_during_session': commits_during_session,
    'harness_session_id':     harness_sid or None,
    'ccusage_jsonl':          ccusage_jsonl,
}, indent=2))
" "$PWD" "$_git_branch" "$_git_head" "$active_policy" "$_started_at" "$_ended_at" \
            "$_ended_at_git_head" "$_commits_during_session" \
            "$VIGIL_LOG_DIR" "$VIGIL_SESSION_ID" \
            > "${logfile%.log}.json" 2>/dev/null || true
    fi

    # Strip ANSI from the raw script(1) capture into a .txt companion,
    # then discard the .log. Strip failure is reported on stderr; the
    # .log is only removed on success so a failed strip leaves the raw
    # file intact rather than nothing.
    local stripper="$HOME/.config/vigil/scripts/strip-ansi.py"
    if [[ -f "$stripper" && -f "$logfile" ]] && command -v python3 >/dev/null 2>&1; then
        local _txtfile="${logfile%.log}.txt"
        python3 "$stripper" "$logfile" "$_txtfile" \
            && rm -f -- "$logfile" \
            || echo "vigil: strip-ansi failed; raw log kept at $logfile" >&2
        # Prepend a self-describing policy header so the transcript is
        # readable without consulting the sidecar JSON. Validate the
        # policy name to a safe character class before embedding it.
        if [[ "$active_policy" =~ ^[a-zA-Z0-9_-]+$ && -f "$_txtfile" ]]; then
            local _tmp=""
            if _tmp=$(mktemp); then
                if { printf '# vigil-policy: %s\n' "$active_policy"; cat "$_txtfile"; } > "$_tmp" \
                        && mv -- "$_tmp" "$_txtfile"; then
                    : # prepend succeeded
                else
                    rm -f -- "$_tmp"
                fi
            fi
        fi
    fi
)

vigil() {
    if [[ "${1-}" == "set-default" ]]; then
        shift
        vigil_set_default "$@"
        return
    fi
    _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/strict.json" "$@"
}

vigil-dev() {
    local project_root
    project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || project_root="$PWD"
    (
        cd "$project_root" || return 1
        _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/dev.json" "$@"
    )
}

vigil-strict() {
    _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/strict.json" "$@"
}

vigil-yolo() {
    _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/yolo.json" "$@"
}

vigil_set_default() {
    local force=0 target="" current_profile="default" raw_profile=""
    local vigil_dir="$HOME/.config/vigil"
    local target_bundle="" current_bundle="" staging="" tmp_profile=""
    local dirty=() f="" arg=""

    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            -*)
                printf 'vigil set-default: unknown option: %s\n' "$arg" >&2
                return 1
                ;;
            *)
                if [[ -n "$target" ]]; then
                    printf 'vigil set-default: unexpected argument: %s\n' "$arg" >&2
                    return 1
                fi
                target="$arg"
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        printf 'Usage: vigil set-default [--force] <profile>\n' >&2
        printf 'Per-session override: CLAUDE_CONFIG_DIR=~/.config/vigil/profiles/<profile> vigil ...\n' >&2
        return 1
    fi

    # Reject path-traversal and shell-metacharacter content in profile name.
    if [[ ! "$target" =~ ^[a-zA-Z0-9-]+$ ]]; then
        printf 'vigil set-default: invalid profile name: %s\n' "$target" >&2
        return 1
    fi

    target_bundle="$vigil_dir/profiles/$target"

    if [[ ! -f "$target_bundle/settings.json" ]]; then
        printf 'vigil set-default: profile "%s" not found (expected %s/settings.json)\n' \
            "$target" "$target_bundle" >&2
        return 1
    fi

    if pgrep -x claude >/dev/null 2>&1; then
        printf 'vigil set-default: Claude Code is running — close all sessions before switching profiles\n' >&2
        return 1
    fi
    # Belt-and-suspenders open-files check; skipped silently if lsof is absent.
    if command -v lsof >/dev/null 2>&1 && lsof +D "$HOME/.claude/" 2>/dev/null | grep -q .; then
        printf 'vigil set-default: files under ~/.claude/ are open — close all sessions before switching profiles\n' >&2
        return 1
    fi

    if [[ -f "$vigil_dir/active-profile" ]]; then
        raw_profile="$(cat "$vigil_dir/active-profile")"
        if [[ "$raw_profile" =~ ^[a-zA-Z0-9-]+$ ]]; then
            current_profile="$raw_profile"
        else
            printf 'vigil set-default: active-profile contains invalid value "%s", treating as "default"\n' \
                "$raw_profile" >&2
        fi
    fi

    if [[ "$current_profile" == "$target" ]]; then
        printf 'Already on profile: %s\n' "$target"
        return 0
    fi

    # Diff check against current bundle. Fires symmetrically for both
    # profiles: ~/.config/vigil/profiles/<name> is a real directory distinct
    # from ~/.claude/, so comparing live files against the bundle catches
    # local edits in either direction.
    if [[ $force -eq 0 ]]; then
        current_bundle="$vigil_dir/profiles/$current_profile"
        dirty=()
        for f in settings.json CLAUDE.md settings.local.template.json; do
            if [[ -f "$HOME/.claude/$f" && -f "$current_bundle/$f" ]] && \
               ! diff -q "$HOME/.claude/$f" "$current_bundle/$f" >/dev/null 2>&1; then
                dirty+=("$HOME/.claude/$f")
            fi
        done
        if [[ -d "$HOME/.claude/agents" ]] && \
           ! diff -rq "$HOME/.claude/agents" "$current_bundle/agents" >/dev/null 2>&1; then
            dirty+=("$HOME/.claude/agents/")
        fi
        if [[ ${#dirty[@]} -gt 0 ]]; then
            printf 'vigil set-default: local edits detected — copy them to the bundle or pass --force to overwrite:\n' >&2
            printf '  %s\n' "${dirty[@]}" >&2
            return 1
        fi
    fi

    staging="$vigil_dir/staging"
    [[ -n "$staging" ]] || { printf 'vigil set-default: internal error: empty staging path\n' >&2; return 1; }
    rm -rf "$staging"
    mkdir -p "$staging"
    cp -r -- "$target_bundle/." "$staging/"

    for f in settings.json CLAUDE.md settings.local.template.json; do
        if [[ -f "$staging/$f" ]]; then
            [[ -f "$HOME/.claude/$f" ]] && mv -- "$HOME/.claude/$f" "$HOME/.claude/$f.bak"
            mv -- "$staging/$f" "$HOME/.claude/$f"
            rm -f "$HOME/.claude/$f.bak"
        fi
    done
    if [[ -d "$staging/agents" ]]; then
        [[ -d "$HOME/.claude/agents" ]] && mv -- "$HOME/.claude/agents" "$HOME/.claude/agents.bak"
        mv -- "$staging/agents" "$HOME/.claude/agents"
        rm -rf "$HOME/.claude/agents.bak"
    fi
    rm -rf "$staging"

    # Regenerate settings.local.json so hook paths resolve to ~/.claude,
    # not the source bundle path they were baked to at install time.
    local live_template="$HOME/.claude/settings.local.template.json"
    if [[ -f "$live_template" ]]; then
        local tmp_local
        tmp_local="$(mktemp "$HOME/.claude/.settings.local.XXXXXX")"
        if sed -e "s|{{PROFILE_DIR}}|$HOME/.claude|g" \
               -e "s|{{HOME}}|$HOME|g" \
               "$live_template" > "$tmp_local"; then
            mv -- "$tmp_local" "$HOME/.claude/settings.local.json"
        else
            rm -f "$tmp_local"
            printf 'vigil set-default: error: failed to regenerate settings.local.json\n' >&2
            return 1
        fi
    else
        printf 'vigil set-default: warning: settings.local.template.json missing from profile bundle — hook paths may be stale\n' >&2
    fi

    # Write active-profile atomically via temp-file rename.
    tmp_profile="$(mktemp "$vigil_dir/.active-profile.XXXXXX")"
    printf '%s\n' "$target" > "$tmp_profile"
    mv -- "$tmp_profile" "$vigil_dir/active-profile"

    printf 'Switched to profile: %s\n' "$target"
}

# Operator-only: install the per-repo pre-push review gate. Sandboxed
# Vigil sessions deny `Bash(vigil-install-review:*)` in every policy.
# Run from inside the target repo so the CWD-pinned sandbox denies
# (filter-sandbox-denies.py expands the placeholder at vigil launch)
# already cover its .git/config and .git/hooks/.
vigil-install-review() {
    "$HOME/.config/vigil/scripts/vigil-install-review" "$@"
}

# Open a session transcript in $PAGER. With no args, opens the most
# recent. With -N (e.g., -1), opens the transcript that many positions
# back from newest: -1 is the previous session, -2 the one before that.
# With a date-prefix string (e.g., 20260413 or 2026-04-13), opens the
# first transcript whose timestamp starts with that prefix; dashes are
# stripped before matching since session filenames use compact
# YYYYMMDD-HHMMSS form.
#
# Sorting relies on session filenames being fixed-width and lex-sortable
# the same as chronologically — keep in sync with the session-filename
# format used by _vigil_run_with_logging above.
vigil-log() {
    local logdir="$HOME/vigil-logs"
    local pager="${PAGER:-less}"
    local arg="${1:-}"

    shopt -s nullglob
    local all=("$logdir"/session-*.txt)
    shopt -u nullglob

    if [[ ${#all[@]} -eq 0 ]]; then
        echo "vigil-log: no transcripts in $logdir" >&2
        return 1
    fi

    # Reverse to newest-first; the YYYYMMDD-HHMMSS timestamp prefix makes
    # filenames sort lexicographically the same as chronologically.
    local files=()
    local i
    for ((i=${#all[@]}-1; i>=0; i--)); do
        files+=("${all[$i]}")
    done

    local target=""
    if [[ -z "$arg" ]]; then
        target="${files[0]}"
    elif [[ "$arg" =~ ^-[0-9]+$ ]]; then
        local idx="${arg#-}"
        if (( idx >= ${#files[@]} )); then
            echo "vigil-log: only ${#files[@]} transcript(s) available" >&2
            return 1
        fi
        target="${files[$idx]}"
    else
        local query="${arg//-/}"
        local f base stamp
        for f in "${files[@]}"; do
            base="$(basename "$f")"
            stamp="${base#session-}"
            stamp="${stamp%.txt}"
            if [[ "$stamp" == "$query"* ]]; then
                target="$f"
                break
            fi
        done
        if [[ -z "$target" ]]; then
            echo "vigil-log: no transcript matching '$arg'" >&2
            return 1
        fi
    fi

    # eval lets multi-word PAGER values work (e.g., PAGER="less -R").
    # Target is shell-quoted to survive paths with spaces.
    eval "$pager $(printf '%q' "$target")"
}

# Prune ~/vigil-logs. Forwards args to scripts/prune-logs.py; run
# `vigil-log-prune --help` for flags. The same script runs
# automatically at SessionStart (180d age, 2G cap) via the profile
# hook; this wrapper is for manual on-demand pruning with custom
# thresholds or --dry-run.
vigil-log-prune() {
    local script="$HOME/.config/vigil/scripts/prune-logs.py"
    if [[ ! -f "$script" ]]; then
        echo "vigil-log-prune: $script not found" >&2
        return 1
    fi
    python3 "$script" "$@"
}

# Per-session cost and token analytics. Scans ~/vigil-logs/session-*.json
# sidecars and joins each with its ccusage JSONL to produce a flat report.
# Run `vigil-analyze --help` for flags (--format csv, --max-age-days, etc.).
vigil-analyze() {
    local script="$HOME/.config/vigil/scripts/vigil-sessions.py"
    if [[ ! -f "$script" ]]; then
        echo "vigil-analyze: $script not found" >&2
        return 1
    fi
    python3 "$script" "$@"
}
