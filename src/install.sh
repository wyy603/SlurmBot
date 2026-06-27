#!/bin/bash
# SlurmBot installer — deploys SlurmBot to ~/.slurmbot/ and configures
# shell startup files so the server launches on login.
#
# Usage (one-liner):
#   curl -sSL https://raw.githubusercontent.com/wyy603/SlurmBot/master/src/install.sh | bash

set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/wyy603/SlurmBot/master/src"
SLURMBOT_DIR="$HOME/.slurmbot"

echo "╔══════════════════════════════════════════╗"
echo "║       🤖 SlurmBot Installer              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# --- Preflight checks ---
if ! command -v curl > /dev/null 2>&1; then
    echo "ERROR: curl is required but not installed."
    exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
    echo "ERROR: jq is required but not installed."
    echo "       Install it with: sudo apt install jq  (or equivalent)"
    exit 1
fi

if ! command -v squeue > /dev/null 2>&1; then
    echo "WARNING: squeue not found. SlurmBot needs squeue to monitor jobs."
    echo "         Are you on an HPC login node?"
fi

echo "── Configuration ──────────────────────────"
echo ""

read -r -p "  Slurm username: " SLURM_USER
while [ -z "$SLURM_USER" ]; do
    echo "  (required)"
    read -r -p "  Slurm username: " SLURM_USER
done

read -r -p "  Telegram chat ID: " CHAT_ID
while [ -z "$CHAT_ID" ]; do
    echo "  (required — get your chat ID from @userinfobot on Telegram)"
    read -r -p "  Telegram chat ID: " CHAT_ID
done

echo ""

# --- Create target directory ---
mkdir -p "$SLURMBOT_DIR"
echo "[1/5] Created $SLURMBOT_DIR"

# --- Fetch server script ---
echo "[2/5] Fetching slurmbot-server.sh..."
curl -sSL "$GITHUB_RAW/slurmbot-server.sh" -o "$SLURMBOT_DIR/slurmbot-server.sh"
chmod +x "$SLURMBOT_DIR/slurmbot-server.sh"
echo "      Done"

# --- Fetch and fill config template ---
echo "[3/5] Creating config.json..."
curl -sSL "$GITHUB_RAW/config.template.json" -o "$SLURMBOT_DIR/config.json"
# Substitute user and telegram_chat_id into the template
jq --arg user "$SLURM_USER" --arg chat_id "$CHAT_ID" \
    '.user = $user | .telegram_chat_id = $chat_id' \
    "$SLURMBOT_DIR/config.json" > "$SLURMBOT_DIR/config.json.tmp"
mv "$SLURMBOT_DIR/config.json.tmp" "$SLURMBOT_DIR/config.json"
chmod 600 "$SLURMBOT_DIR/config.json"
echo "      Config written (permissions locked to 600)"

# --- Append shell fragments ---
append_fragment() {
    local rc="$1"
    local fragment_name="$2"

    if [ ! -f "$rc" ]; then
        echo "      $rc does not exist, skipped"
        return
    fi

    if grep -q "slurmbot-server.sh" "$rc" 2>/dev/null; then
        echo "      $rc already has SlurmBot fragment, skipped"
        return
    fi

    curl -sSL "$GITHUB_RAW/$fragment_name" >> "$rc"
    echo "      Appended SlurmBot fragment to $rc"
}

echo "[4/5] Configuring shell startup files..."
append_fragment "$HOME/.bashrc" ".bashrc"
append_fragment "$HOME/.zshrc"  ".zshrc"

# --- Start the server now ---
echo "[5/5] Starting SlurmBot server..."
echo ""

SLURMBOT_UPDATE="$SLURMBOT_DIR/last_update"

if pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
    echo "      Server is already running."
elif [ -f "$SLURMBOT_UPDATE" ]; then
    last_ts=$(cat "$SLURMBOT_UPDATE" 2>/dev/null) || last_ts="0"
    case "$last_ts" in *[!0-9]*|"") last_ts=0;; esac
    now=$(date +%s)
    elapsed=$((now - last_ts))
    if [ "$elapsed" -le 60 ] 2>/dev/null; then
        echo "      Server was started less than 60s ago ($elapsed"$"s), skipping."
    else
        date +%s > "$SLURMBOT_UPDATE"
        nohup bash "$SLURMBOT_DIR/slurmbot-server.sh" >> "$SLURMBOT_DIR/server.log" 2>&1 &
        sleep 1
        if pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
            echo "      Server started successfully."
        else
            echo "      WARNING: Server may have failed to start."
            echo "               Check $SLURMBOT_DIR/server.log"
        fi
    fi
else
    date +%s > "$SLURMBOT_UPDATE"
    nohup bash "$SLURMBOT_DIR/slurmbot-server.sh" >> "$SLURMBOT_DIR/server.log" 2>&1 &
    sleep 1
    if pgrep -f "slurmbot-server.sh" > /dev/null 2>&1; then
        echo "      Server started successfully."
    else
        echo "      WARNING: Server may have failed to start."
        echo "               Check $SLURMBOT_DIR/server.log"
    fi
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ✅ Installation complete!          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Logs  → $SLURMBOT_DIR/server.log"
echo "  Config → $SLURMBOT_DIR/config.json"
echo ""
echo "  SlurmBot will auto-start on every new shell login."
