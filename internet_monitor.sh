#!/bin/bash

# Find the absolute path of the directory this script lives in
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET="1.1.1.1"
LOG_FILE="$SCRIPT_DIR/internet_drops.log"
LAST_STATE="UP"
DOWN_TIME=0

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitoring started." >> "$LOG_FILE"

while true; do
    ping -c 1 -t 2 $TARGET > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        if [ "$LAST_STATE" = "UP" ]; then
            LAST_STATE="DOWN"
            DOWN_TIME=$(date +%s)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] INTERNET DOWN" >> "$LOG_FILE"
        fi
    else
        if [ "$LAST_STATE" = "DOWN" ]; then
            LAST_STATE="UP"
            UP_TIME=$(date +%s)
            DURATION=$((UP_TIME - DOWN_TIME))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] INTERNET RECOVERED (Downtime: $DURATION seconds)" >> "$LOG_FILE"
        fi
    fi
    
    sleep 5
done
