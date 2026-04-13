#!/bin/bash
LOGFILE="$CLAUDE_LOG_DIR/session-$CLAUDE_SESSION_ID.log"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
echo "--- TOOL USE [$TIMESTAMP] ---" >> "$LOGFILE"
cat >> "$LOGFILE"  # hooks receive JSON on stdin
echo "" >> "$LOGFILE"