#!/bin/bash
# Inotify monitor for breach-trace
# Monitors critical directories for file changes

LOGFILE="/var/log/honeypot-inotify.log"

inotifywait -m -r \
    -e create,modify,delete,moved_to,moved_from \
    /root /etc/ssh /etc/cron.d /var/spool/cron /usr/local/bin \
    --format '%T %w %f %e' \
    --timefmt '%Y-%m-%d %H:%M:%S' \
    2>/dev/null >> "$LOGFILE" &

echo "inotifywait started (PID: $!)"
