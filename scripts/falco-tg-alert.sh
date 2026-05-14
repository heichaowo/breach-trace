#!/bin/bash
# Falco Telegram alert script for breach-trace
# Sends alert when SSH login is detected

# Load config
source /etc/breach-trace/.env 2>/dev/null || {
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
}

tail -F /var/log/falco/events.log 2>/dev/null | while read line; do
    if echo "$line" | grep -q "SSH login success"; then
        SRC=$(echo "$line" | grep -oP 'src=\K[0-9.]+')
        MSG="🚨 breach-trace 入侵告警
来源 IP: $SRC
时间: $(date '+%Y-%m-%d %H:%M:%S')
$line"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=${MSG}" > /dev/null 2>&1

        # Auto-start tcpdump for 5 minutes
        DUMPFILE="/var/log/breach-trace-dump-$(date +%Y%m%d-%H%M%S).pcap"
        timeout 300 tcpdump -i any -n not port 22 -w "$DUMPFILE" 2>/dev/null &
    fi
done
