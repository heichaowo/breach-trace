#!/bin/bash
# honeypot-analyze.sh v3
# 支持 PTY session 和 non-PTY 时间窗口两种分析方式
# 用法:
#   ./honeypot-analyze.sh                    # 列出所有登录
#   ./honeypot-analyze.sh latest             # 最新 PTY session
#   ./honeypot-analyze.sh session <id>       # 指定 session
#   ./honeypot-analyze.sh time <HH:MM:SS>    # non-PTY 按时间窗口（±60秒）
#   ./honeypot-analyze.sh ip <ip>            # 按来源 IP 查所有登录

AUDIT_LOG="/var/log/audit/audit-rn.log"
SYSLOG="/var/log/rn-honeypot.log"

show_login_list() {
    echo "=== SSH 登录记录（Falco）==="
    grep "SSH connection accepted\|SSH login" "$SYSLOG" 2>/dev/null | \
        sed 's/.*falco: //' | awk '{print NR".", $0}'
    echo ""
    echo "=== PTY 会话列表（auditd）==="
    grep "type=LOGIN" "$AUDIT_LOG" 2>/dev/null | \
        grep -v "ses=4294967295" | \
        awk -F'msg=audit\\(' '{print $2}' | \
        grep -oE '[0-9]+\.[0-9]+|ses=[0-9]+' | \
        paste - - | \
        while read ts ses; do
            ts_int=$(echo $ts | cut -d. -f1)
            dt=$(date -d "@$ts_int" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r $ts_int "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            echo "  $dt  $ses"
        done | tail -20
    echo ""
    echo "用法:"
    echo "  $0 latest              # 最新 PTY session"
    echo "  $0 session <id>        # 指定 session ID"
    echo "  $0 time <HH:MM:SS>     # non-PTY 按时间分析（RN 本地时间 PDT）"
    echo "  $0 ip <ip>             # 查指定 IP 的所有登录"
}

analyze_session() {
    local SES="$1"
    echo "=== Session $SES 操作记录 ==="
    echo ""
    echo "--- 登录信息 ---"
    grep "ses=$SES[^0-9]" "$AUDIT_LOG" | grep "type=LOGIN" | head -3
    echo ""
    echo "--- 命令列表 ---"
    grep "ses=$SES[^0-9]" "$AUDIT_LOG" | grep "type=SYSCALL.*exec_cmd" | \
        while read line; do
            ts=$(echo "$line" | grep -oE 'audit\([0-9]+' | grep -oE '[0-9]+')
            comm=$(echo "$line" | grep -oE 'comm="[^"]*"' | sed 's/comm=//;s/"//g')
            dt=$(date -d "@$ts" "+%H:%M:%S" 2>/dev/null)
            echo "  $dt  $comm"
        done | head -50
    echo ""
    echo "--- 访问的文件 ---"
    grep "ses=$SES[^0-9]" "$AUDIT_LOG" | grep "type=PATH" | \
        grep -oE 'name="[^"]*"' | sed 's/name=//;s/"//g' | \
        grep -v "^/proc\|^/sys\|^/dev" | sort -u | head -20
}

analyze_by_time() {
    local TIME="$1"
    local DATE=$(date "+%Y-%m-%d")
    local TS=$(date -d "$DATE $TIME PDT" +%s 2>/dev/null || date -d "$DATE $TIME" +%s)
    local TS_START=$((TS - 60))
    local TS_END=$((TS + 60))

    echo "=== non-PTY 时间窗口分析 ==="
    echo "时间范围: $(date -d @$TS_START '+%H:%M:%S') ~ $(date -d @$TS_END '+%H:%M:%S') (PDT)"
    echo ""
    echo "--- 执行的命令 ---"
    grep "type=SYSCALL.*exec_cmd" "$AUDIT_LOG" | \
        while read line; do
            ts=$(echo "$line" | grep -oE 'audit\([0-9]+' | grep -oE '[0-9]+')
            if [ "$ts" -ge "$TS_START" ] && [ "$ts" -le "$TS_END" ]; then
                comm=$(echo "$line" | grep -oE 'comm="[^"]*"' | sed 's/comm=//;s/"//g')
                ses=$(echo "$line" | grep -oE 'ses=[0-9]+' | grep -oE '[0-9]+')
                dt=$(date -d "@$ts" "+%H:%M:%S" 2>/dev/null)
                echo "  $dt  ses=$ses  $comm"
            fi
        done | sort | head -50
    echo ""
    echo "--- EXECVE 完整参数 ---"
    awk -v start=$TS_START -v end=$TS_END '
    /type=EXECVE/ {
        match($0, /msg=audit\(([0-9]+)/, arr)
        ts = arr[1]+0
        if (ts >= start && ts <= end) print $0
    }' "$AUDIT_LOG" | \
        grep -oE 'a[0-9]+="[^"]*"' | sed 's/a[0-9]*=//;s/"//g' | \
        tr '\n' ' ' | fold -s -w 100
    echo ""
    echo "--- 访问的文件 ---"
    awk -v start=$TS_START -v end=$TS_END '
    /type=PATH/ {
        match($0, /msg=audit\(([0-9]+)/, arr)
        ts = arr[1]+0
        if (ts >= start && ts <= end) print $0
    }' "$AUDIT_LOG" | \
        grep -oE 'name="[^"]*"' | sed 's/name=//;s/"//g' | \
        grep -v "^/proc\|^/sys\|^/dev" | sort -u | head -30
    echo ""
    echo "--- 网络连接 ---"
    awk -v start=$TS_START -v end=$TS_END '
    /type=SOCKADDR/ {
        match($0, /msg=audit\(([0-9]+)/, arr)
        ts = arr[1]+0
        if (ts >= start && ts <= end) print $0
    }' "$AUDIT_LOG" | head -10
}

analyze_by_ip() {
    local IP="$1"
    echo "=== IP $IP 的所有登录记录 ==="
    grep "$IP" "$SYSLOG" 2>/dev/null | tail -20
    echo ""
    echo "--- 对应的登录时间（PDT）---"
    grep "Accepted.*$IP\|$IP.*Accepted" "$SYSLOG" 2>/dev/null | \
        grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | \
        while read t; do
            echo "  登录时间: $t PDT  →  用法: $0 time $t"
        done
}

# 主逻辑
case "$1" in
    "")
        show_login_list
        ;;
    "latest")
        SES=$(grep "type=SYSCALL" "$AUDIT_LOG" | grep -v "ses=4294967295" | \
              grep -oE 'ses=[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
        [ -z "$SES" ] && echo "暂无 PTY session" && exit 0
        analyze_session "$SES"
        ;;
    "session")
        analyze_session "$2"
        ;;
    "time")
        analyze_by_time "$2"
        ;;
    "ip")
        analyze_by_ip "$2"
        ;;
    *)
        analyze_session "$1"
        ;;
esac
