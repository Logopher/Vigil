_claude_run_with_logging() {
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
    unset CLAUDE_SESSION_ID CLAUDE_LOG_DIR
}

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