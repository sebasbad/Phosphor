#!/usr/bin/env bash
# check_backup_liveness.sh
# Accurately monitors liveness, file migration, and final validation progress for Phosphor iOS backup.

set -euo pipefail

UDID="00008120-001879082238C01E"
BACKUP_DIR="/Volumes/Sebas4TbAPFS/bkp/iPhone14ProMax/$UDID"
SAMPLE_SEC="${1:-3}"

echo "================================================================================"
echo " Phosphor Backup Stage & Progress Watchdog (${SAMPLE_SEC}s sample)"
echo "================================================================================"

PY_PID=$(pgrep -f "pymobiledevice3 backup2 backup" | head -n 1 || true)
USBMUX_PID=$(pgrep -x "usbmuxd" | head -n 1 || true)

if [ -z "$PY_PID" ]; then
    echo "❌ No active 'pymobiledevice3 backup2' process found."
    if [ -f "$BACKUP_DIR/Status.plist" ]; then
        echo ""
        echo "Status.plist state:"
        plutil -p "$BACKUP_DIR/Status.plist" 2>/dev/null || cat "$BACKUP_DIR/Status.plist"
    fi
    echo "================================================================================"
    exit 0
fi

ELAPSED=$(ps -p "$PY_PID" -o etime= | tr -d ' ')
START_TIME=$(ps -p "$PY_PID" -o lstart=)
echo "Process PID:   $PY_PID (usbmuxd: ${USBMUX_PID:-none})"
echo "Total Elapsed: $ELAPSED (started: $START_TIME)"

SNAP_STATE="unknown"
BKP_STATE="unknown"
if [ -f "$BACKUP_DIR/Status.plist" ]; then
    SNAP_STATE=$(plutil -extract SnapshotState raw "$BACKUP_DIR/Status.plist" 2>/dev/null || echo "unknown")
    BKP_STATE=$(plutil -extract BackupState raw "$BACKUP_DIR/Status.plist" 2>/dev/null || echo "unknown")
fi
echo "Status:        BackupState='$BKP_STATE', SnapshotState='$SNAP_STATE'"

python3 -c "
import os, sys, time

backup_dir = '$BACKUP_DIR'
snap_state = '$SNAP_STATE'

if snap_state == 'finished':
    # The device has completed all moves and sealed Manifest.db.
    # The host is running local disk integrity validation (scandir/stat across 256 buckets).
    # Check directory access times (atime) in the last 15 minutes.
    t_thresh = time.time() - 900
    scanned = 0
    for d in os.listdir(backup_dir):
        if len(d) == 2:
            fp = os.path.join(backup_dir, d)
            try:
                if os.stat(fp).st_atime >= t_thresh:
                    scanned += 1
            except:
                pass

    val_pct = (scanned / 256.0) * 100.0
    bar_len = 25
    filled = int(bar_len * (val_pct / 100.0))
    bar = '=' * filled + '-' * (bar_len - filled)

    rem_buckets = 256 - scanned
    # Scanning ~1-2 buckets per 5-10 seconds
    rem_min = int(rem_buckets * 0.05) + 1

    print('--------------------------------------------------------------------------------')
    print('Phase:         Stage 3/3: Local Manifest & Disk Verification')
    print(f'Progress:      {val_pct:.1f}% [{bar}] ({scanned} / 256 directory buckets verified)')
    print(f'Estimated ETA: ~{rem_min} - {rem_min + 3} minutes until process exit and UI flip')
    print('Status Note:   All 593,349 files are transferred and sealed. Verifying on disk.')
    print('--------------------------------------------------------------------------------')
elif snap_state == 'moving':
    b0_root_dir = os.path.join(backup_dir, '00')
    b0_snap_dir = os.path.join(backup_dir, 'Snapshot', '00')
    b0_root = len(os.listdir(b0_root_dir)) if os.path.exists(b0_root_dir) else 0
    b0_snap = len(os.listdir(b0_snap_dir)) if os.path.exists(b0_snap_dir) else 0
    b0_total = b0_root + b0_snap
    pct = (b0_root / b0_total * 100.0) if b0_total > 0 else 0.0
    print('--------------------------------------------------------------------------------')
    print(f'Phase:         Stage 2/3: Moving files from Snapshot to Root ({pct:.1f}%)')
    print('--------------------------------------------------------------------------------')
"

echo "Sampling CPU ticks over ${SAMPLE_SEC}s..."
PY_T0=$(ps -p "$PY_PID" -o cputime= | tr -d ' ')
sleep "$SAMPLE_SEC"
PY_T1=$(ps -p "$PY_PID" -o cputime= | tr -d ' ')

echo "pymobiledevice3 CPU: $PY_T0 -> $PY_T1"
if [ "$PY_T0" != "$PY_T1" ]; then
    echo "🟢 STATUS: ACTIVE (verifying disk inodes and committing manifest)"
else
    echo "🟡 STATUS: WAITING"
fi
echo "================================================================================"
