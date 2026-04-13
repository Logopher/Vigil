#!/bin/bash
LOGFILE="$CLAUDE_LOG_DIR/session-$CLAUDE_SESSION_ID.log"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
echo "--- TOOL RESULT [$TIMESTAMP] ---" >> "$LOGFILE"
cat >> "$LOGFILE"
echo "" >> "$LOGFILE"