#!/bin/bash
# SlurmBot installer — deploys SlurmBot to ~/.slurmbot/ and configures
# shell startup files so the server launches on login.
#
# Usage:
#   cd src/hpc && bash install.sh

set -euo pipefail

SLURMBOT_DIR="$HOME/.slurmbot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== SlurmBot Installer ==="
echo ""

# --- Create target directory ---
mkdir -p "$SLURMBOT_DIR"
echo "[1/4] Created $SLURMBOT_DIR"

# --- Deploy server script ---
cp "$SCRIPT_DIR/slurmbot-server.sh" "$SLURMBOT_DIR/slurmbot-server.sh"
chmod +x "$SLURMBOT_DIR/slurmbot-server.sh"
echo "[2/4] Deployed slurmbot-server.sh"

# --- Deploy user config (only if not already present) ---
if [ ! -f "$SLURMBOT_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.json" "$SLURMBOT_DIR/config.json"
    echo "[3/4] Created $SLURMBOT_DIR/config.json"
    echo "      >>> Please edit 'user' and 'telegram_chat_id' in $SLURMBOT_DIR/config.json <<<"
else
    echo "[3/4] $SLURMBOT_DIR/config.json already exists, skipped"
fi

# --- Append shell fragments ---
append_fragment() {
    local rc="$1"
    local fragment="$2"

    if [ ! -f "$rc" ]; then
        echo "      $rc does not exist, skipped"
        return
    fi

    if grep -q "slurmbot-server.sh" "$rc" 2>/dev/null; then
        echo "      $rc already has SlurmBot fragment, skipped"
        return
    fi

    cat "$fragment" >> "$rc"
    echo "      Appended SlurmBot fragment to $rc"
}

echo "[4/4] Configuring shell startup files..."
append_fragment "$HOME/.bashrc" "$SCRIPT_DIR/.bashrc"
append_fragment "$HOME/.zshrc"  "$SCRIPT_DIR/.zshrc"

# --- Start the server now ---
echo ""
echo "=== Starting SlurmBot server ==="
if pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
    echo "Server is already running."
else
    nohup bash "$SLURMBOT_DIR/slurmbot-server.sh" >> "$SLURMBOT_DIR/server.log" 2>&1 &
    sleep 1
    if pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
        echo "Server started successfully."
    else
        echo "WARNING: Server may have failed to start. Check $SLURMBOT_DIR/server.log"
    fi
fi

echo ""
echo "=== Done ==="
echo "Logs: $SLURMBOT_DIR/server.log"
