#!/usr/bin/env bash
# check_backup_liveness.sh
# Accurately monitors liveness, logs historical progress checkpoints, and calculates
# moving-average velocity to provide self-correcting ETA estimates for Phosphor iOS backup.

set -euo pipefail

UDID="00008120-001879082238C01E"
BACKUP_DIR="/Volumes/Sebas4TbAPFS/bkp/iPhone14ProMax/$UDID"
SAMPLE_SEC="${1:-3}"
HISTORY_FILE="/tmp/phosphor_backup_history.csv"

echo "================================================================================"
echo " Phosphor Backup Liveness & Self-Correcting Watchdog (${SAMPLE_SEC}s sample)"
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
history_file = '$HISTORY_FILE'

if snap_state == 'finished':
    print('--------------------------------------------------------------------------------')
    print('Progress:      100% [========================================]')
    print('Phase:         COMPLETED & SEALED! iPhone is safe to disconnect.')
    print('--------------------------------------------------------------------------------')
elif snap_state == 'moving':
    # Direct fast sample of bucket 00 (<50ms APFS metadata read)
    b0_root_dir = os.path.join(backup_dir, '00')
    b0_snap_dir = os.path.join(backup_dir, 'Snapshot', '00')
    b0_root = len(os.listdir(b0_root_dir)) if os.path.exists(b0_root_dir) else 0
    b0_snap = len(os.listdir(b0_snap_dir)) if os.path.exists(b0_snap_dir) else 0
    b0_total = b0_root + b0_snap

    # Across all 256 hash buckets:
    est_moved = b0_root * 256
    est_remaining = b0_snap * 256
    est_total_files = b0_total * 256
    moving_phase_pct = (b0_root / b0_total * 100.0) if b0_total > 0 else 0.0
    overall_pct = 90.0 + (moving_phase_pct * 0.09)

    now = time.time()
    now_iso = time.strftime('%H:%M:%S', time.localtime(now))

    # Append current observation to history CSV: timestamp,epoch,moved,remaining
    try:
        with open(history_file, 'a') as f:
            f.write(f'{now_iso},{now:.1f},{est_moved},{est_remaining}\n')
    except Exception:
        pass

    # Read all historical checkpoints
    history = []
    if os.path.exists(history_file):
        try:
            with open(history_file, 'r') as f:
                for line in f:
                    parts = line.strip().split(',')
                    if len(parts) == 4:
                        history.append({
                            'time_str': parts[0],
                            'epoch': float(parts[1]),
                            'moved': int(parts[2]),
                            'rem': int(parts[3])
                        })
        except Exception:
            pass

    # Self-correcting moving-average calculation:
    # 1. Short-term (last 3-5 entries)
    # 2. Medium/Long-term (first recorded checkpoint in session vs now)
    rate_str = 'Collecting initial baseline...'
    eta_str = 'Estimating baseline...'
    checkpoints_str = f'{len(history)} checkpoint(s) logged'

    if len(history) >= 2:
        # Long-term regression baseline across entire watchdog observation
        first = history[0]
        total_dt = now - first['epoch']
        total_dmoved = est_moved - first['moved']

        # Short-term recent rate (last 5 min or last entry > 15s ago)
        recent_candidates = [h for h in history if now - h['epoch'] >= 15]
        if recent_candidates:
            ref = recent_candidates[-1]
            rec_dt = now - ref['epoch']
            rec_dmoved = est_moved - ref['moved']
            rec_rate = (rec_dmoved / rec_dt) if rec_dt > 0 else 0
        else:
            rec_rate = 0

        avg_rate = (total_dmoved / total_dt) if total_dt > 0 else 0

        # Blended smoothed velocity: 70% long-term historical trend + 30% instantaneous
        effective_rate = (0.7 * avg_rate + 0.3 * rec_rate) if rec_rate > 0 else avg_rate

        if effective_rate > 0:
            rate_str = f'{effective_rate:.1f} files/sec (~{effective_rate * 60:,.0f} files/min)'
            rem_sec = est_remaining / effective_rate
            m, s = divmod(int(rem_sec), 60)
            h, m = divmod(m, 60)
            if h > 0:
                eta_str = f'~{h}h {m}m ({time.strftime(\"%H:%M\", time.localtime(now + rem_sec))})'
            else:
                eta_str = f'~{m}m {s}s ({time.strftime(\"%H:%M\", time.localtime(now + rem_sec))})'
        else:
            rate_str = 'waiting on next device batch ACK'
            eta_str = 'calibrating with next batch'

    bar_len = 25
    filled = int(bar_len * (overall_pct / 100.0))
    bar = '=' * filled + '-' * (bar_len - filled)

    print('--------------------------------------------------------------------------------')
    print(f'Active Phase:  Moving files out of Snapshot/ into Root ({moving_phase_pct:.1f}% of phase)')
    print(f'Progress:      {overall_pct:.2f}% [{bar}]')
    print(f'Items Moved:   ~{est_moved:,} / ~{est_total_files:,} files (~{est_remaining:,} remaining in Snapshot)')
    print(f'History:       {checkpoints_str} in /tmp/phosphor_backup_history.csv')
    print(f'Current Speed: {rate_str}')
    print(f'Corrected ETA: {eta_str}')
    print('--------------------------------------------------------------------------------')
elif snap_state == 'uploading':
    print('--------------------------------------------------------------------------------')
    print('Progress:      ~85% - 90% (Transferring file payloads into Snapshot/)')
    print('--------------------------------------------------------------------------------')
"

echo "Sampling CPU & USB bus ticks over ${SAMPLE_SEC}s..."
PY_T0=$(ps -p "$PY_PID" -o cputime= | tr -d ' ')
USB_T0=$([ -n "$USBMUX_PID" ] && ps -p "$USBMUX_PID" -o cputime= | tr -d ' ' || echo "0")

sleep "$SAMPLE_SEC"

PY_T1=$(ps -p "$PY_PID" -o cputime= | tr -d ' ')
USB_T1=$([ -n "$USBMUX_PID" ] && ps -p "$USBMUX_PID" -o cputime= | tr -d ' ' || echo "0")

echo "pymobiledevice3 CPU: $PY_T0 -> $PY_T1"
[ -n "$USBMUX_PID" ] && echo "usbmuxd CPU:         $USB_T0 -> $USB_T1"

echo ""
if [ "$PY_T0" != "$PY_T1" ] || [ "$USB_T0" != "$USB_T1" ]; then
    echo "🟢 STATUS: ACTIVE (system actively reorganizing files / processing)"
else
    echo "🟡 STATUS: WAITING (batch transition)"
fi
echo "================================================================================"
