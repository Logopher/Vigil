# Curated env-var allowlist for the claude wrappers. Vars not on this
# list (and not matching LC_* or GIT_*) are unset before launching
# Claude — the default sandbox covers filesystem reads but env vars
# are inherited by every child process unless explicitly cleared.
#
# Add to this list (in your own ~/.bashrc, after sourcing this file)
# to pass through additional non-secret vars, e.g.:
#   _claude_env_allowlist+=(AWS_PROFILE AWS_REGION)
_claude_env_allowlist=(
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

_claude_run_with_logging() (
    # Subshell so env scrubbing and exports don't leak back to the
    # interactive shell that invoked us.

    # Refresh sandbox.filesystem.deny{Read,Write} before each session.
    # Paths that have become symlinks, disappeared, or changed type
    # would otherwise cause bubblewrap to fail closed for every
    # subprocess. Cheap; silently skipped if the filter is missing.
    local filter="$HOME/.config/claude-config/scripts/filter-sandbox-denies.py"
    if [[ -f "$filter" ]] && command -v python3 >/dev/null 2>&1; then
        python3 "$filter" >/dev/null || true
    fi

    # Strip env vars not on the allowlist. compgen -v lists every set
    # variable; unset on read-only or special vars fails harmlessly.
    # Membership check uses string match (not associative array) for
    # bash 3.2 compatibility — macOS ships /bin/bash 3.2.
    # Loop-locals use the _claude_ prefix so the loop doesn't clobber
    # itself when it iterates over them via compgen -v.
    local _claude_allow_str=" ${_claude_env_allowlist[*]} "
    local _claude_v
    while IFS= read -r _claude_v; do
        [[ "$_claude_allow_str" == *" $_claude_v "* ]] && continue
        [[ "$_claude_v" == LC_* ]] && continue
        [[ "$_claude_v" == GIT_* ]] && continue
        [[ "$_claude_v" == BASH* || "$_claude_v" == _ || "$_claude_v" == _claude_* ]] && continue
        unset "$_claude_v" 2>/dev/null || true
    done < <(compgen -v)

    export CLAUDE_SESSION_ID=$(date +%Y%m%d-%H%M%S)
    export CLAUDE_LOG_DIR="$HOME/claude-logs"
    mkdir -p "$CLAUDE_LOG_DIR"
    local logfile="$CLAUDE_LOG_DIR/session-$CLAUDE_SESSION_ID.log"
    case "$(uname)" in
        Darwin|*BSD)
            # BSD script(1): `script [-q] file command...`
            script -q "$logfile" command claude "$@"
            ;;
        *)
            # util-linux script(1): `script -B file -c cmd`
            script -B "$logfile" -c "command claude $*"
            ;;
    esac

    # Post-process the raw script(1) capture into a readable .txt
    # transcript alongside it. The .log keeps full TTY fidelity for
    # replay; the .txt is for actual reading and grep-ability.
    local stripper="$HOME/.config/claude-config/scripts/strip-ansi.py"
    if [[ -f "$stripper" && -f "$logfile" ]] && command -v python3 >/dev/null 2>&1; then
        python3 "$stripper" "$logfile" "${logfile%.log}.txt" 2>/dev/null || true
    fi
)

claude() {
    _claude_run_with_logging "$@"
}

claude-dev() {
    local project_root
    project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || project_root="$PWD"
    (
        cd "$project_root" || return 1
        _claude_run_with_logging --settings "$HOME/.config/claude-config/policies/dev.json" "$@"
    )
}

claude-strict() {
    _claude_run_with_logging --settings "$HOME/.config/claude-config/policies/strict.json" "$@"
}

claude-yolo() {
    _claude_run_with_logging --settings "$HOME/.config/claude-config/policies/yolo.json" "$@"
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
# format used by _claude_run_with_logging above.
claude-log() {
    local logdir="$HOME/claude-logs"
    local pager="${PAGER:-less}"
    local arg="${1:-}"

    shopt -s nullglob
    local all=("$logdir"/session-*.txt)
    shopt -u nullglob

    if [[ ${#all[@]} -eq 0 ]]; then
        echo "claude-log: no transcripts in $logdir" >&2
        return 1
    fi

    # Reverse to newest-first; filenames (session-YYYYMMDD-HHMMSS.txt)
    # sort lexicographically the same as chronologically.
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
            echo "claude-log: only ${#files[@]} transcript(s) available" >&2
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
            echo "claude-log: no transcript matching '$arg'" >&2
            return 1
        fi
    fi

    # eval lets multi-word PAGER values work (e.g., PAGER="less -R").
    # Target is shell-quoted to survive paths with spaces.
    eval "$pager $(printf '%q' "$target")"
}

# Prune ~/claude-logs. Forwards args to scripts/prune-logs.py; run
# `claude-log-prune --help` for flags. The same script runs
# automatically at SessionStart (90d age, 2G cap) via the profile
# hook; this wrapper is for manual on-demand pruning with custom
# thresholds or --dry-run.
claude-log-prune() {
    local script="$HOME/.config/claude-config/scripts/prune-logs.py"
    if [[ ! -f "$script" ]]; then
        echo "claude-log-prune: $script not found" >&2
        return 1
    fi
    python3 "$script" "$@"
}
