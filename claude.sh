claude() {
    export CLAUDE_SESSION_ID=$(date +%Y%m%d-%H%M%S)
    export CLAUDE_LOG_DIR=~/claude-logs
    mkdir -p "$CLAUDE_LOG_DIR"
    local logfile="$CLAUDE_LOG_DIR/session-$CLAUDE_SESSION_ID.log"
    script -B "$logfile" -c "command claude $*"
    unset CLAUDE_SESSION_ID CLAUDE_LOG_DIR
}