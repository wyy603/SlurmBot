# <<<<<<<<<<<<<<<<<<<< SlurmBot
# Auto-start server on shell login.

SLURMBOT_DIR="$HOME/.slurmbot"
SLURMBOT_SERVER="$SLURMBOT_DIR/slurmbot-server.sh"

# Start server if not already running
if ! pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
    nohup bash "$SLURMBOT_SERVER" >> "$SLURMBOT_DIR/server.log" 2>&1 &
fi
# >>>>>>>>>>>>>>>>>>>>
