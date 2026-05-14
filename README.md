# breach-trace

> Active Deception + Kernel-Level Forensic Auditing with Secure Log Forwarding

A production-tested intrusion forensics framework that lures attackers into a honeypot, records every action at the kernel level, and exfiltrates logs in real-time to a secure receiver the attacker cannot reach.

## Background

This project was born from a real intrusion incident: an attacker gained root access via password brute-force and remained undetected for weeks, using the compromised server as an SSH scanning relay. Upon discovery, the attacker had already wiped the journal logs and wtmp records, leaving minimal forensic evidence.

**breach-trace** solves this by combining three layers:

1. **Active Deception** — Re-enable password auth and plant decoy credential files to lure the attacker back in
2. **Kernel-Level Auditing** — Capture every syscall, command execution, file access, and network connection at the kernel level (Falco eBPF + auditd). The attacker cannot detect or bypass this layer
3. **Secure Log Forwarding** — Stream all audit data in real-time to a separate server the attacker has no knowledge of, via audisp-remote and rsyslog. Even if the attacker wipes every log on the honeypot, the evidence is already safe

## Architecture

```
Attacker
  │
  ▼  SSH password login (honeypot)
Honeypot Server
  ├── Falco eBPF        →  SSH login alert  →  Telegram
  ├── auditd            →  all execve / file ops / network
  │     └── audisp-remote ─────────────────────────────┐
  ├── inotifywait       →  critical directory changes    │  real-time
  ├── rsyslog           →  Falco + inotify logs          │  forwarding
  └── tcpdump           →  auto-capture on login         │
                                                         ▼
                                              Secure Receiver
                                              /var/log/audit/audit-rn.log
                                              /var/log/rn-honeypot.log
                                              honeypot-analyze.sh
```

## Components

| Component | Role |
|-----------|------|
| **Falco eBPF** | Kernel-level syscall monitoring; alerts Telegram on successful SSH login |
| **auditd** | Records all execve (commands), file reads/writes, user changes |
| **audisp-remote** | Streams auditd events in real-time to the secure receiver — attacker cannot delete these |
| **inotifywait** | Watches /root, /etc/ssh, and other critical directories for changes |
| **rsyslog** | Forwards Falco and inotify logs to the secure receiver |
| **tcpdump** | Auto-starts on login, captures attacker's outbound connections for 5 minutes |
| **honeypot-analyze.sh** | Deployed on the receiver; one-command forensic analysis of any session |

## Quick Start

### Honeypot Server (the compromised server)

```bash
# Clone the repo
git clone https://github.com/heichaowo/breach-trace.git
cd breach-trace

# Configure environment
cp .env.example .env
vim .env  # Set TG_BOT_TOKEN, TG_CHAT_ID, RECEIVER_IP

# Deploy
bash deploy.sh
```

### Secure Receiver (a separate server the attacker doesn't know about)

```bash
bash deploy-receiver.sh
```

## Forensic Analysis

Once an attacker is detected (Telegram alert fires), run on the receiver:

```bash
# List all SSH logins
honeypot-analyze.sh

# Analyze latest PTY session (interactive login)
honeypot-analyze.sh latest

# Analyze non-PTY login by time window (automated scripts)
honeypot-analyze.sh time 03:28:21

# Show all activity from a specific IP
honeypot-analyze.sh ip 108.62.161.75

# Analyze a specific session ID
honeypot-analyze.sh session 16082
```

### PTY vs non-PTY

| Login Type | auditd Session ID | Analysis Method |
|------------|-------------------|-----------------|
| Interactive (PTY) | Unique session ID | `honeypot-analyze.sh latest` or `session <id>` |
| Automated script (non-PTY) | 4294967295 (unset) | `honeypot-analyze.sh time <HH:MM:SS>` |

Non-PTY logins (common with automated attack tools) share session ID `4294967295` with system processes. breach-trace handles this by filtering on the login timestamp ±60 seconds.

## Honeypot Configuration

To lure the attacker back:
- Re-enable SSH password authentication
- Restore the original compromised password
- Plant a decoy credential file at `/root/.ssh_credentials_backup` with fake server passwords
- The attacker will find the decoy and attempt to use those credentials — revealing their targets

## Security Notes

- **Never commit `.env`** — it contains your bot token and receiver IP
- The secure receiver should be a server the attacker has no knowledge of
- All logs on the honeypot may be wiped by the attacker; `audisp-remote` ensures evidence is preserved on the receiver before any cleanup can occur
- Tested on Debian 12 with kernel 6.x (Falco modern eBPF requires kernel ≥ 5.8)

## License

MIT
