#!/bin/bash
# SlurmBot server — monitors Slurm job queue and reports changes to Telegram.
# Sends direct messages to the user via Telegram Bot API (sendMessage).
# Runs as a background daemon on an HPC login node.

set -euo pipefail

CONFIG="$HOME/.slurmbot/config.json"
LAST_FILE="$HOME/.slurmbot/last_squeue.txt"
LOG_FILE="$HOME/.slurmbot/server.log"
INTERVAL=5

mkdir -p "$HOME/.slurmbot"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

die() {
    log "FATAL: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

if [ ! -f "$CONFIG" ]; then
    die "Config file not found: $CONFIG"
fi

if ! command -v jq > /dev/null 2>&1; then
    die "jq is not installed — required for parsing config and building Telegram payloads"
fi

USER_NAME=$(jq -r '.user' "$CONFIG")
TELEGRAM_BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG")
TELEGRAM_CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG")

if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "null" ]; then
    die "'user' is not set in $CONFIG"
fi
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ "$TELEGRAM_BOT_TOKEN" = "null" ]; then
    die "'telegram_bot_token' is not set in $CONFIG"
fi
if [ -z "$TELEGRAM_CHAT_ID" ] || [ "$TELEGRAM_CHAT_ID" = "null" ]; then
    die "'telegram_chat_id' is not set in $CONFIG"
fi

TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

log "SlurmBot server started (user=$USER_NAME, chat_id=$TELEGRAM_CHAT_ID, interval=${INTERVAL}s)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Escape < > & for Telegram HTML parse_mode.
escape_html() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$1"
}

# Send a message to the user via Telegram sendMessage API.
notify_telegram() {
    local text="$1"
    local response

    response=$(curl -s -X POST \
        -H 'Content-type: application/json' \
        -d "$(jq -n \
            --arg chat_id "$TELEGRAM_CHAT_ID" \
            --arg text "$text" \
            '{chat_id: $chat_id, text: $text, parse_mode: "HTML"}')" \
        "$TELEGRAM_API" 2>/dev/null || true)

    local ok
    ok=$(echo "$response" | jq -r '.ok' 2>/dev/null)

    if [ "$ok" = "true" ]; then
        log "Sent to Telegram OK (chat_id=$TELEGRAM_CHAT_ID)"
    else
        local desc
        desc=$(echo "$response" | jq -r '.description // "unknown"' 2>/dev/null)
        log "ERROR: Telegram API error: $desc"
    fi
}

# ---------------------------------------------------------------------------
# Squeue helpers
# ---------------------------------------------------------------------------

# Pipe-delimited format for easy parsing.
# Fields: JOBID | NAME | PARTITION | STATE | START_TIME | REASON | NODES
# TIME column intentionally excluded.
# No width limits on NAME — user wants full job names.
SQUEUE_FMT="%i|%j|%P|%t|%S|%r|%D"

get_squeue() {
    squeue -u "$USER_NAME" --noheader -o "$SQUEUE_FMT" 2>&1 || true
}

# Extract numeric job IDs from raw squeue output.
extract_job_ids() {
    local data="$1"
    echo "$data" \
        | grep -v "^(no jobs)$" \
        | awk -F'|' '{print $1}' \
        | grep -E '^[0-9]+$' \
        | sort
}

# Find the full line in raw squeue output matching a given job ID.
# Job ID is the first pipe-delimited field.
find_job_lines() {
    local data="$1"
    local jid="$2"
    echo "$data" | grep -E "^${jid}\|" || true
}

# Parse one pipe-delimited squeue line into human-readable format.
# Input:  JOBID|NAME|PARTITION|STATE|START|REASON|NODES
# Output: multi-line description with full job name.
format_job() {
    local line="$1"
    local jid name partition state start reason nodes

    IFS='|' read -r jid name partition state start reason nodes <<< "$line"

    local escaped_name
    escaped_name=$(escape_html "$name")
    printf '%s\n' "  • <code>${escaped_name}</code>"
    printf '%s\n' "    job ID: ${jid}"
    printf '%s\n' "    partition: ${partition}"

    # State: R = Running, anything else = Pending / held etc.
    if [ "$state" = "R" ]; then
        printf '%s\n' "    started: ${start}"
        [ -n "$nodes" ] && [ "$nodes" != "0" ] && printf '%s\n' "    nodes: ${nodes}" || true
    else
        [ -n "$reason" ] && printf '%s\n' "    reason: ${reason}" || true
        [ -n "$start" ] && [ "$start" != "N/A" ] && printf '%s\n' "    expected start: ${start}" || true
    fi
}

# Format a list of job lines into a grouped message block.
# Separates running (R) from pending (PD / others).
format_job_list() {
    local data="$1"
    local running="" pending="" output=""
    local state

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        state=$(echo "$line" | awk -F'|' '{print $4}')
        if [ "$state" = "R" ]; then
            running+="$line"$'\n'
        else
            pending+="$line"$'\n'
        fi
    done <<< "$data"

    if [ -n "$running" ]; then
        output+="<b>🏃 Running:</b>"$'\n'
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            output+="$(format_job "$line")"$'\n'
        done <<< "$running"
    fi

    if [ -n "$pending" ]; then
        [ -n "$output" ] && output+=$'\n'
        output+="<b>⏳ Pending:</b>"$'\n'
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            output+="$(format_job "$line")"$'\n'
        done <<< "$pending"
    fi

    echo "$output"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

log "Entering main loop"

while true; do
    raw_current=$(get_squeue)

    # Detect squeue command failures (error messages start with "squeue:")
    if echo "$raw_current" | grep -qE "^squeue:" 2>/dev/null; then
        log "WARNING: squeue error — $raw_current"
        sleep "$INTERVAL"
        continue
    fi

    # Normalize empty output to a stable placeholder
    if [ -z "$raw_current" ]; then
        raw_current="(no jobs)"
    fi

    if [ -f "$LAST_FILE" ]; then
        last=$(cat "$LAST_FILE")
    fi

    if [ -z "$last" ]; then
        # First run — report the full initial queue so the user knows
        # monitoring is active.
        log "First run, reporting initial state"

        if [ "$raw_current" = "(no jobs)" ]; then
            msg="<b>SlurmBot</b> started monitoring <code>${USER_NAME}</code>"$'\n'"No jobs in queue."
        else
            msg="<b>SlurmBot</b> started monitoring <code>${USER_NAME}</code>"$'\n'"Initial queue:"$'\n'
            msg+="$(format_job_list "$raw_current")"
        fi
        notify_telegram "$msg"
    else
        log "Computing diffs..."

        curr_ids=$(extract_job_ids "$raw_current")
        last_ids=$(extract_job_ids "$last")

        # --- Compute diff ---
        new_ids=$(comm -13 <(echo "$last_ids") <(echo "$curr_ids") 2>/dev/null || true)
        done_ids=$(comm -23 <(echo "$last_ids") <(echo "$curr_ids") 2>/dev/null || true)

        # Find common IDs with changed lines (state transitions like PD→R)
        common_ids=$(comm -12 <(echo "$last_ids") <(echo "$curr_ids") 2>/dev/null || true)
        changed_ids=""
        while IFS= read -r jid; do
            [ -z "$jid" ] && continue
            old_line=$(find_job_lines "$last" "$jid")
            new_line=$(find_job_lines "$raw_current" "$jid")
            old_noreason=$(echo "$old_line" | awk -F'|' 'BEGIN{OFS="|"} {print $1,$2,$3,$4,$7}')
            new_noreason=$(echo "$new_line" | awk -F'|' 'BEGIN{OFS="|"} {print $1,$2,$3,$4,$7}')
            if [ "$old_noreason" != "$new_noreason" ] && [ -n "$old_line" ] && [ -n "$new_line" ]; then
                changed_ids+="$jid"$'\n'
            fi
        done <<< "$common_ids"

        if [ -n "$new_ids" ] || [ -n "$done_ids" ] || [ -n "$changed_ids" ]; then
            log "Changes detected, building report..."

            # --- Build Telegram message (HTML format) ---
            msg="<b>SlurmBot</b> — jobs changed for <code>${USER_NAME}</code>"

            if [ -n "$new_ids" ]; then
                msg+=$'\n\n'"<b>🆕 New jobs:</b>"$'\n'
                while IFS= read -r jid; do
                    [ -z "$jid" ] && continue
                    line=$(find_job_lines "$raw_current" "$jid")
                    if [ -n "$line" ]; then
                        msg+="$(format_job "$line")"$'\n'
                    fi
                done <<< "$new_ids"
            fi

            if [ -n "$done_ids" ]; then
                msg+=$'\n'"<b>✅ Completed / gone:</b>"$'\n'
                while IFS= read -r jid; do
                    [ -z "$jid" ] && continue
                    line=$(find_job_lines "$last" "$jid")
                    if [ -n "$line" ]; then
                        msg+="$(format_job "$line")"$'\n'
                    fi
                done <<< "$done_ids"
            fi

            if [ -n "$changed_ids" ]; then
                msg+=$'\n'"<b>🔄 State changed:</b>"$'\n'
                while IFS= read -r jid; do
                    [ -z "$jid" ] && continue
                    new_line=$(find_job_lines "$raw_current" "$jid")
                    if [ -n "$new_line" ]; then
                        msg+="$(format_job "$new_line")"$'\n'
                    fi
                done <<< "$changed_ids"
            fi

            msg+="═══════════════════"$'\n'"Current jobs:"$'\n'
            msg+="$(format_job_list "$raw_current")"

            notify_telegram "$msg"
        fi
    fi

    echo "$raw_current" > "$LAST_FILE"
    sleep "$INTERVAL"
done
