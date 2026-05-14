#!/bin/bash
# breach-trace deploy.sh
# Deploy honeypot + audit on the target server

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load env
if [ -f "$REPO_DIR/.env" ]; then
    source "$REPO_DIR/.env"
else
    echo "ERROR: .env not found. Copy .env.example to .env and fill in values."
    exit 1
fi

[ -z "$TG_BOT_TOKEN" ] && echo "ERROR: TG_BOT_TOKEN not set" && exit 1
[ -z "$TG_CHAT_ID" ] && echo "ERROR: TG_CHAT_ID not set" && exit 1
[ -z "$RECEIVER_IP" ] && echo "ERROR: RECEIVER_IP not set" && exit 1

echo "=== breach-trace deployment ==="
echo "Receiver: $RECEIVER_IP"
echo ""

echo "--- 1. Install dependencies ---"
apt-get install -y falco auditd audispd-plugins inotify-tools tcpdump rsyslog -q 2>&1 | grep -E "installed|already|error" || true

echo "--- 2. Configure Falco ---"
mkdir -p /etc/falco
cp "$REPO_DIR/falco/falco_rules.yaml" /etc/falco/falco_rules.yaml
cat > /etc/falco/falco.yaml << EOF
engine:
  kind: modern_ebpf
rules_files:
  - /etc/falco/falco_rules.yaml
output_timeout: 2000
outputs:
  rate: 0
  max_burst: 10000
syslog_output:
  enabled: false
file_output:
  enabled: true
  keep_alive: true
  filename: /var/log/falco/events.log
stdout_output:
  enabled: false
log_level: info
priority: warning
EOF
systemctl enable falco
systemctl restart falco

echo "--- 3. Configure auditd ---"
cp "$REPO_DIR/auditd/honeypot.rules" /etc/audit/rules.d/honeypot.rules
augenrules --load
systemctl enable auditd
service auditd restart

echo "--- 4. Configure audisp-remote ---"
sed "s/RECEIVER_IP/$RECEIVER_IP/g" "$REPO_DIR/audisp/audisp-remote.conf" \
    > /etc/audit/audisp-remote.conf
python3 -c "
c = open('/etc/audit/plugins.d/au-remote.conf').read()
c = c.replace('active = no', 'active = yes')
open('/etc/audit/plugins.d/au-remote.conf', 'w').write(c)
"
service auditd restart

echo "--- 5. Configure rsyslog ---"
sed "s/RECEIVER_IP/$RECEIVER_IP/g" "$REPO_DIR/rsyslog/98-breach-trace.conf" \
    > /etc/rsyslog.d/98-breach-trace.conf
systemctl restart rsyslog

echo "--- 6. Deploy inotify monitor ---"
mkdir -p /var/log
cp "$REPO_DIR/scripts/honeypot-inotify.sh" /usr/local/bin/honeypot-inotify.sh
chmod +x /usr/local/bin/honeypot-inotify.sh
cat > /etc/systemd/system/honeypot-inotify.service << 'EOF'
[Unit]
Description=breach-trace inotify monitor
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/honeypot-inotify.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable honeypot-inotify
systemctl restart honeypot-inotify

echo "--- 7. Deploy Telegram alert ---"
mkdir -p /etc/breach-trace
cp "$REPO_DIR/.env" /etc/breach-trace/.env
chmod 600 /etc/breach-trace/.env
# Replace token in alert script
sed "s/your_bot_token_here/$TG_BOT_TOKEN/g; s/your_chat_id_here/$TG_CHAT_ID/g" \
    "$REPO_DIR/scripts/falco-tg-alert.sh" > /usr/local/bin/falco-tg-alert.sh
chmod +x /usr/local/bin/falco-tg-alert.sh
cat > /etc/systemd/system/falco-tg-alert.service << 'EOF'
[Unit]
Description=breach-trace Telegram alert
After=falco.service

[Service]
Type=simple
ExecStart=/usr/local/bin/falco-tg-alert.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable falco-tg-alert
systemctl restart falco-tg-alert

echo ""
echo "=== Deployment complete ==="
systemctl status falco --no-pager | grep Active
systemctl status auditd --no-pager | grep Active
systemctl status honeypot-inotify --no-pager | grep Active
systemctl status falco-tg-alert --no-pager | grep Active
