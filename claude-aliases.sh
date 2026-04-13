claude() {
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