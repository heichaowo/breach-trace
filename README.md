# breach-trace

> 高交互蜜罐 + 实时审计日志外传 — 入侵取证方案

## 背景

本项目源于一次真实的服务器入侵事件：攻击者通过密码暴力破解入侵服务器，长达数周潜伏并利用该机器对外发起批量 SSH 扫描。事后溯源发现攻击者清除了 journal 日志和 wtmp 记录，留下极少痕迹。

为此设计了这套方案：**主动引诱攻击者进入蜜罐，通过内核级审计实时记录其所有行为，并将日志外传到攻击者无法触及的安全服务器**，从而实现完整的入侵取证和溯源。

## 架构

```
攻击者
  │
  ▼ SSH 密码登录（蜜罐）
蜜罐服务器（RN）
  ├── Falco eBPF      → SSH 登录告警 → Telegram
  ├── auditd          → 所有命令/文件/网络操作
  │     └── audisp-remote ──────────────────────┐
  ├── inotifywait     → 关键目录文件变动          │
  ├── rsyslog         → Falco/inotify 日志        │  实时推送
  └── tcpdump         → 登录时自动抓包            │
                                                  ▼
                                         安全接收端（HK）
                                           /var/log/audit/audit-rn.log
                                           /var/log/rn-honeypot.log
                                           honeypot-analyze.sh 一键分析
```

## 组件

| 组件 | 用途 |
|------|------|
| **Falco eBPF** | 内核级系统调用监控，SSH 登录成功立即推 Telegram |
| **auditd** | 记录所有 execve（命令执行）、文件读写、用户变更 |
| **audisp-remote** | 将 auditd 日志实时推送到安全接收端，攻击者无法删除 |
| **inotifywait** | 监控 /root /etc/ssh 等关键目录的文件变动 |
| **rsyslog** | 将 Falco/inotify 日志推送到安全接收端 |
| **tcpdump** | SSH 登录时自动启动，抓取攻击者的出站连接 |
| **honeypot-analyze.sh** | 部署在安全接收端，一键提取指定会话的完整操作记录 |

## 蜜罐配置

吸引攻击者进入的配置：
- 开启 SSH 密码登录
- 植入假密码文件（诱饵）
- 恢复旧密码（让已知攻击者能进入）

## 快速部署

### 蜜罐服务器（被入侵的服务器）

```bash
# 1. 克隆仓库
git clone https://github.com/heichaowo/breach-trace.git
cd breach-trace

# 2. 配置环境变量
cp .env.example .env
vim .env  # 填入 TG_BOT_TOKEN、TG_CHAT_ID、RECEIVER_IP

# 3. 一键部署
bash deploy.sh
```

### 安全接收端（另一台服务器）

```bash
# 部署接收端
bash deploy-receiver.sh

# 分析攻击者行为
honeypot-analyze.sh                    # 列出所有登录
honeypot-analyze.sh latest             # 最新 PTY session
honeypot-analyze.sh ip 1.2.3.4        # 按来源 IP 查询
honeypot-analyze.sh time 03:28:21     # non-PTY 按时间窗口分析
```

## 分析方法

攻击者上钩后，在安全接收端执行：

```bash
# PTY 登录（交互式）
honeypot-analyze.sh latest

# non-PTY 登录（自动化脚本，按时间窗口）
honeypot-analyze.sh time <登录时间>

# 查指定 IP 的所有登录
honeypot-analyze.sh ip 108.62.161.75
```

## 注意事项

- `.env` 文件包含敏感信息，**不要提交到 git**
- 安全接收端建议使用攻击者不知道的服务器
- 蜜罐服务器上的日志可能被攻击者删除，但 audisp-remote 已实时外传
- 开启蜜罐前确保业务数据已备份或迁移

## License

MIT
