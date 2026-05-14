#!/bin/bash
# breach-trace deploy-receiver.sh
# Deploy log receiver on the safe server

set -e
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== breach-trace receiver deployment ==="

echo "--- 1. Install dependencies ---"
apt-get install -y rsyslog auditd -q 2>&1 | grep -E "installed|already" || true

echo "--- 2. Configure auditd to receive remote logs ---"
cat > /etc/audit/auditd.conf << 'EOF'
tcp_listen_port = 60
tcp_listen_queue = 5
tcp_max_per_addr = 1
log_file = /var/log/audit/audit-rn.log
log_format = RAW
log_group = adm
priority_boost = 4
flush = INCREMENTAL_ASYNC
freq = 50
num_logs = 10
max_log_file = 50
max_log_file_action = ROTATE
space_left = 100
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SUSPEND
disk_full_action = SUSPEND
disk_error_action = SUSPEND
EOF
systemctl restart auditd

echo "--- 3. Configure rsyslog to receive syslog ---"
read -p "Honeypot server IP: " HONEYPOT_IP
sed "s/HONEYPOT_IP/$HONEYPOT_IP/g" "$REPO_DIR/rsyslog/01-receive.conf" \
    > /etc/rsyslog.d/01-receive.conf
systemctl restart rsyslog

echo "--- 4. Deploy analysis script ---"
cp "$REPO_DIR/scripts/honeypot-analyze.sh" /usr/local/bin/honeypot-analyze.sh
chmod +x /usr/local/bin/honeypot-analyze.sh

echo "--- 5. Open firewall ports ---"
iptables -A INPUT -p tcp --dport 514 -s "$HONEYPOT_IP" -j ACCEPT
iptables -A INPUT -p tcp --dport 60 -s "$HONEYPOT_IP" -j ACCEPT
echo "Ports 514 and 60 opened for $HONEYPOT_IP"

echo ""
echo "=== Receiver deployment complete ==="
echo "Logs: /var/log/audit/audit-rn.log"
echo "      /var/log/rn-honeypot.log"
echo "Analysis: honeypot-analyze.sh"
