# <<<<<<<<<<<<<<<<<<<< SlurmBot 
# Auto-start server on shell login and ensure crontab watchdog is present.

SLURMBOT_DIR="$HOME/.slurmbot"
SLURMBOT_SERVER="$SLURMBOT_DIR/slurmbot-server.sh"

# Start server if not already running
if ! pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
    nohup bash "$SLURMBOT_SERVER" >> "$SLURMBOT_DIR/server.log" 2>&1 &
fi

# Add crontab watchdog entry if not already present
if ! crontab -l 2>/dev/null | grep -q "slurmbot-server.sh"; then
    (crontab -l 2>/dev/null; echo "* * * * * pgrep -f slurmbot-server.sh > /dev/null || nohup bash $SLURMBOT_DIR/slurmbot-server.sh >> $SLURMBOT_DIR/server.log 2>&1 &") | crontab -
fi
# >>>>>>>>>>>>>>>>>>>>