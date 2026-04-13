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
    local _allow_str=" ${_claude_env_allowlist[*]} "
    local _v
    while IFS= read -r _v; do
        [[ "$_allow_str" == *" $_v "* ]] && continue
        [[ "$_v" == LC_* ]] && continue
        [[ "$_v" == GIT_* ]] && continue
        [[ "$_v" == BASH* || "$_v" == _ || "$_v" == _claude_* ]] && continue
        unset "$_v" 2>/dev/null || true
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
