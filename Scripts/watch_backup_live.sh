#!/usr/bin/env bash
# watch_backup_live.sh
# Instant, zero-overhead backup progress monitor:
# 1. Inspects active backup process & child threads (PID, CPU, RAM, elapsed runtime)
# 2. Inspects lsof to see the exact files currently being written/read in the backup folder
# 3. Inspects Manifest.db / Status.plist / Snapshot status
# 4. Compares with previous state in /tmp/phosphor_backup_state.json

set -euo pipefail

UDID="${1:-00008120-001879082238C01E}"
INTERVAL="${2:-3}"
BASE_DIR="/Volumes/Sebas4TbAPFS/bkp/AppleDevicesBackups"
TARGET_DIR="$BASE_DIR/$UDID"
LOG_STATE="/tmp/phosphor_backup_state.json"
RUN_LOG="/tmp/phosphor_backup_run.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${BLUE}========================================================================${NC}"
echo -e "${BOLD}  Phosphor Live Backup Watcher (Delta Observer)${NC}"
echo -e "  UDID:        ${CYAN}$UDID${NC}"
echo -e "  Directory:   ${CYAN}$TARGET_DIR${NC}"
echo -e "  Interval:    ${INTERVAL}s"
echo -e "${BLUE}========================================================================${NC}"

while true; do
    NOW=$(date +%s)
    NOW_STR=$(date '+%H:%M:%S')

    # 1. Find active backup PID
    PY_PID=$(pgrep -f "pymobiledevice3 backup2 backup.*$UDID" | head -n 1 || true)
    BACKUP_TYPE="pymobiledevice3"
    if [ -z "$PY_PID" ]; then
        PY_PID=$(pgrep -f "idevicebackup2.*backup.*$UDID" | head -n 1 || true)
        BACKUP_TYPE="idevicebackup2"
    fi

    # 2. Check Process Health
    PROC_LINE="NO RUNNING BACKUP PID"
    CPU_USAGE="0.0"
    ACTIVE_FILES=""
    
    if [ -n "$PY_PID" ]; then
        CPU_USAGE=$(ps -p "$PY_PID" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0.0")
        ETIME=$(ps -p "$PY_PID" -o etime= 2>/dev/null | tr -d ' ' || echo "00:00")
        PROC_LINE="PID $PY_PID ($BACKUP_TYPE) CPU: ${CPU_USAGE}% | Runtime: $ETIME"

        # Find files opened by the backup process in the backup dir (instant lsof)
        ACTIVE_FILES=$(lsof -n -P -p "$PY_PID" 2>/dev/null | grep "$TARGET_DIR" | awk '{print $NF}' | tr '\n' ' ' || true)
    fi

    # 3. Read Status.plist if present
    STATUS_STR="none"
    if [ -f "$TARGET_DIR/Status.plist" ]; then
        STATUS_STR=$(plutil -p "$TARGET_DIR/Status.plist" 2>/dev/null | grep -E 'BackupState|SnapshotState' | tr '\n' ' ' | sed 's/  */ /g' || echo "Status.plist exists")
    fi

    # 4. Check Manifest.db size & modification
    M_SIZE="none"
    M_MOD="none"
    if [ -f "$TARGET_DIR/Manifest.db" ]; then
        M_SIZE=$(ls -lh "$TARGET_DIR/Manifest.db" 2>/dev/null | awk '{print $5}')
        M_MOD=$(stat -f "%Sm" -t "%H:%M:%S" "$TARGET_DIR/Manifest.db" 2>/dev/null || echo "none")
    fi

    # 5. Delta state tracking
    PREV_CPU="0.0"
    if [ -f "$LOG_STATE" ]; then
        PREV_CPU=$(grep -o '"cpu":"[^"]*"' "$LOG_STATE" 2>/dev/null | cut -d'"' -f4 || echo "0.0")
    fi
    echo "{\"time\":$NOW,\"cpu\":\"$CPU_USAGE\",\"pid\":\"${PY_PID:-none}\"}" > "$LOG_STATE"

    # Status indicator badge
    if [ -n "$PY_PID" ]; then
        if [ -n "$ACTIVE_FILES" ]; then
            BADGE="${GREEN}● WRITING FILES${NC}"
        elif (( $(echo "$CPU_USAGE > 1.0" | bc -l 2>/dev/null || echo 0) )); then
            BADGE="${CYAN}● DELTA-COMPUTING${NC}"
        else
            BADGE="${YELLOW}● WAITING ON DEVICE${NC}"
        fi
    else
        BADGE="${RED}○ STOPPED${NC}"
    fi

    WRITING_DESC="${ACTIVE_FILES:-none}"
    if [ "${#WRITING_DESC}" -gt 50 ]; then
        WRITING_DESC="...${WRITING_DESC: -47}"
    fi

    LINE="[$NOW_STR] $BADGE │ $PROC_LINE │ Manifest: $M_SIZE (mod $M_MOD) │ Active I/O: $WRITING_DESC │ Status: $STATUS_STR"
    echo -e "$LINE"
    echo "[$NOW_STR] $LINE" >> "$RUN_LOG"

    sleep "$INTERVAL"
done
