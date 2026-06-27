# <<<<<<<<<<<<<<<<<<<< SlurmBot
# Auto-start server on shell login.

SLURMBOT_DIR="$HOME/.slurmbot"
SLURMBOT_SERVER="$SLURMBOT_DIR/slurmbot-server.sh"
SLURMBOT_UPDATE="$SLURMBOT_DIR/last_update"

# Start server only if (no existing process) AND (no recent start attempt ≤60s)
if ! pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
    last_ts=$(cat "$SLURMBOT_UPDATE" 2>/dev/null) || last_ts="0"
    case "$last_ts" in *[!0-9]*|"") last_ts=0;; esac
    now=$(date +%s)
    if [ "$((now - last_ts))" -gt 60 ] 2>/dev/null; then
        date +%s > "$SLURMBOT_UPDATE"
        nohup bash "$SLURMBOT_SERVER" >> "$SLURMBOT_DIR/server.log" 2>&1 &
    fi
fi
# >>>>>>>>>>>>>>>>>>>>>
