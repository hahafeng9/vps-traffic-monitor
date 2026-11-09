#!/usr/bin/env bash
# ============================================================
# vps-traffic-monitor — 免费 VPS 流量监控 + TG 告警
#  https://github.com/hahafeng9/vps-traffic-monitor
#
# 功能（全部免费、无后台、无订阅）：
#  1. 流量统计：今日 / 本月 下载+上传（读 /proc/net/dev，不依赖 vnstat）
#  2. 速率监控：5 分钟采样一次，突发高流量告警（疑似木马/后门跑流量）
#  3. 监听端口基线：新增监听端口告警（疑似后门开端口）
#  4. 可疑出站：连接木马常用端口（4444/5555/6667/1337 等）时告警
#  5. 额度告警：日 / 月流量到 80% / 100% 时告警
#  6. 每日 09:00 TG 流量日报；终端 vps-monitor status 看实时仪表盘
#
# 配置：/etc/vps-monitor.conf（600，只存你自己的 bot token / chat id）
# 状态：/var/lib/vps-monitor/（流量计数、端口基线、告警冷却）
# 用法：vps-monitor install | status | check | report | test | config | baseline | uninstall
# ============================================================
set -u
# bash 5.2+ 默认 patsub_replacement：${var//pat/repl} 里 repl 的 & 会被展开为匹配内容，
# 导致 esc() 的 "&lt;" 变成 "<lt;"。统一关闭，保证所有 bash 版本行为一致。
shopt -u patsub_replacement 2>/dev/null || true

VERSION="1.1.0"
CONF="/etc/vps-monitor.conf"
STATE_DIR="/var/lib/vps-monitor"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="$STATE_DIR/monitor.log"

# ---------- 默认配置（可在 /etc/vps-monitor.conf 里改） ----------
BOT_TOKEN=""
CHAT_ID=""
# TG API 地址，被墙/受限网络可换成反代，如 https://tg-api.example.com
TG_API="https://api.telegram.org"
# 速率告警阈值（MB/s，5 分钟平均超过即告警）
SPIKE_MBPS=10
# 日流量上限（GB，0 = 不限制）
DAILY_LIMIT_GB=0
# 月流量上限（GB，0 = 不限制）
MONTHLY_LIMIT_GB=0
# 每日报告时间（systemd timer / cron 里用，脚本本身不依赖）
REPORT_HOUR=9
# 同一类告警冷却（秒，避免刷屏）
ALERT_COOLDOWN=3600

# 可疑出站端口（木马/远控/矿池常用）
SUSPICIOUS_PORTS="4444 5555 6667 6668 6669 1337 31337 12345 54321 9999"

# ---------- 工具 ----------
log() { mkdir -p "$STATE_DIR" 2>/dev/null; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null; }

# 字节转人类可读（B/KB/MB/GB/TB）
human() {
    local b=${1:-0}
    awk -v b="$b" 'BEGIN{
        if (b<1024) {printf "%.2f B", b}
        else if (b<1048576) {printf "%.2f KB", b/1024}
        else if (b<1073741824) {printf "%.2f MB", b/1048576}
        else if (b<1099511627776) {printf "%.2f GB", b/1073741824}
        else {printf "%.2f TB", b/1099511627776}
    }'
}

# 字节转 GB（两位小数）
to_gb() { awk -v b="${1:-0}" 'BEGIN{printf "%.2f", b/1073741824}'; }

# HTML 转义（TG parse_mode=HTML，实体必须带分号）
esc() {
    local s="$1"
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    printf '%s' "$s"
}

# 加载配置
load_conf() {
    [ -f "$CONF" ] && . "$CONF"
    : "${BOT_TOKEN:=}" "${CHAT_ID:=}" "${TG_API:=https://api.telegram.org}"
    : "${SPIKE_MBPS:=10}" "${DAILY_LIMIT_GB:=0}" "${MONTHLY_LIMIT_GB:=0}"
    : "${REPORT_HOUR:=9}" "${ALERT_COOLDOWN:=3600}"
}

# ---------- 状态文件 ----------
# 字段：DAY MONTH RX_DAY TX_DAY RX_MONTH TX_MONTH LAST_RX LAST_TX LAST_TS
#       BASELINE_PORTS ALERTED_PORTS ALERT_SPIKE ALERT_PORT ALERT_DAY80
#       ALERT_DAY100 ALERT_MON80 ALERT_MON100 ALERT_SUS
DAY="" MONTH="" RX_DAY=0 TX_DAY=0 RX_MONTH=0 TX_MONTH=0
LAST_RX=0 LAST_TX=0 LAST_TS=0
BASELINE_PORTS="" ALERTED_PORTS=""
ALERT_SPIKE=0 ALERT_PORT=0 ALERT_DAY80=0 ALERT_DAY100=0
ALERT_MON80=0 ALERT_MON100=0 ALERT_SUS=0

load_state() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    : "${DAY:=}" "${MONTH:=}" "${RX_DAY:=0}" "${TX_DAY:=0}" "${RX_MONTH:=0}" "${TX_MONTH:=0}"
    : "${LAST_RX:=0}" "${LAST_TX:=0}" "${LAST_TS:=0}"
    : "${BASELINE_PORTS:=}" "${ALERTED_PORTS:=}"
    : "${ALERT_SPIKE:=0}" "${ALERT_PORT:=0}" "${ALERT_DAY80:=0}" "${ALERT_DAY100:=0}"
    : "${ALERT_MON80:=0}" "${ALERT_MON100:=0}" "${ALERT_SUS:=0}"
}

save_state() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    cat > "$STATE_FILE" <<EOF
DAY="$DAY"
MONTH="$MONTH"
RX_DAY=$RX_DAY
TX_DAY=$TX_DAY
RX_MONTH=$RX_MONTH
TX_MONTH=$TX_MONTH
LAST_RX=$LAST_RX
LAST_TX=$LAST_TX
LAST_TS=$LAST_TS
BASELINE_PORTS="$BASELINE_PORTS"
ALERTED_PORTS="$ALERTED_PORTS"
ALERT_SPIKE=$ALERT_SPIKE
ALERT_PORT=$ALERT_PORT
ALERT_DAY80=$ALERT_DAY80
ALERT_DAY100=$ALERT_DAY100
ALERT_MON80=$ALERT_MON80
ALERT_MON100=$ALERT_MON100
ALERT_SUS=$ALERT_SUS
EOF
    chmod 600 "$STATE_FILE" 2>/dev/null
}

# ---------- 网络 ----------
# 自动找默认出口网卡
detect_iface() {
    local ifc=""
    ifc=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -z "$ifc" ]; then
        ifc=$(awk -F: '$1 !~ /lo|face/ {gsub(/ /,"",$1); print $1; exit}' /proc/net/dev 2>/dev/null)
    fi
    printf '%s' "$ifc"
}

# 读网卡收发字节：输出 "rx tx"
read_bytes() {
    local ifc="$1" line rx tx
    line=$(awk -v i="$ifc:" '$1==i{print}' /proc/net/dev 2>/dev/null)
    rx=$(echo "$line" | awk '{print $2}')
    tx=$(echo "$line" | awk '{print $10}')
    printf '%s %s' "${rx:-0}" "${tx:-0}"
}

# 主机外网 IP（结果缓存 1 小时，避免每条告警都请求外网）
public_ip() {
    local f="$STATE_DIR/ip_cache" now ts ip
    now=$(date +%s)
    if [ -f "$f" ]; then
        read -r ts ip < "$f" 2>/dev/null
        if [ -n "$ip" ] && [ "${ts:-0}" -gt 0 ] && [ $((now - ts)) -lt 3600 ]; then
            printf '%s' "$ip"
            return
        fi
    fi
    ip=$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
        || curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    if [ -n "$ip" ]; then
        printf '%s %s\n' "$now" "$ip" > "$f" 2>/dev/null
    fi
    printf '%s' "$ip"
}

# 监听端口（去重、排序，逗号分隔），如 "22,80,443"
listening_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un | paste -sd, -
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | awk '$4 ~ /:/{split($4,a,":"); print a[length(a)]}' | grep -E '^[0-9]+$' | sort -un | paste -sd, -
    else
        printf ''
    fi
}

# 监听端口带进程名（用于告警详情），如 "4444/python3"
listening_ports_verbose() {
    if command -v ss >/dev/null 2>&1; then
        ss -tlnpH 2>/dev/null | awk '{port=$4; sub(/.*:/,"",port); proc=$6; gsub(/.*users:\(\("/,"",proc); gsub(/".*/,"",proc); if(proc=="") proc="?"; print port"/"proc}' | sort -u | paste -sd' ' -
    else
        printf ''
    fi
}

# 可疑出站连接：已建立的连接到木马常用端口，输出 "远端IP:端口"
suspicious_outbound() {
    local out="" p
    if ! command -v ss >/dev/null 2>&1; then printf ''; return; fi
    for p in $SUSPICIOUS_PORTS; do
        out="$out$(ss -tn state established 2>/dev/null | awk -v port=":$p" '$4 ~ port"$" {print $4}' | sort -u | paste -sd' ' -)"
        [ -n "$out" ] && out="$out "
    done
    printf '%s' "$out" | sed 's/  */ /g; s/^ *//; s/ *$//'
}

# ---------- TG ----------
send_tg() {
    local text="$1"
    load_conf
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        log "TG 未配置，跳过发送"
        return 1
    fi
    local code
    code=$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' \
        -X POST "${TG_API}/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=HTML" -d "disable_web_page_preview=true" 2>/dev/null) || code="000"
    if [ "$code" = "200" ]; then
        log "TG 发送成功"
        return 0
    fi
    log "TG 发送失败，HTTP $code"
    return 1
}

host_line() {
    local ip=""
    ip=$(public_ip)
    if [ -n "$ip" ]; then
        printf '🖥 <b>%s</b> (%s)' "$(esc "$(hostname)")" "$(esc "$ip")"
    else
        printf '🖥 <b>%s</b>' "$(esc "$(hostname)")"
    fi
}

# ---------- 核心：一次检查 ----------
do_check() {
    load_conf
    load_state

    # 防并发：上一轮 check 未结束时跳过本轮（timer 触发过密/网络卡时保护）
    if command -v flock >/dev/null 2>&1; then
        exec 9>>"$STATE_DIR/.lock" 2>/dev/null || true
        if ! flock -n 9 2>/dev/null; then
            log "上一实例仍在运行，跳过本次 check"
            return 0
        fi
    fi

    local ifc rx tx now today month
    ifc=$(detect_iface)
    [ -z "$ifc" ] && { log "找不到出口网卡"; return 1; }
    read -r rx tx <<< "$(read_bytes "$ifc")"
    now=$(date +%s)
    today=$(date +%F)
    month=$(date +%Y-%m)

    # --- 日期滚动：新的一天 / 新的一个月 ---
    if [ "$DAY" != "$today" ]; then
        if [ -n "$DAY" ]; then
            RX_MONTH=$((RX_MONTH + RX_DAY)); TX_MONTH=$((TX_MONTH + TX_DAY))
        fi
        DAY="$today"; RX_DAY=0; TX_DAY=0
        ALERT_DAY80=0; ALERT_DAY100=0
    fi
    if [ "$MONTH" != "$month" ]; then
        MONTH="$month"; RX_MONTH=0; TX_MONTH=0
        ALERT_MON80=0; ALERT_MON100=0
    fi

    # --- 速率与累计 ---
    local rate_bps=0 elapsed=0 drx=0 dtx=0
    if [ "$LAST_TS" -gt 0 ] && [ "$now" -gt "$LAST_TS" ]; then
        elapsed=$((now - LAST_TS))
        drx=$((rx - LAST_RX)); dtx=$((tx - LAST_TX))
        # 计数器回绕/重启：负数按 0 计
        [ "$drx" -lt 0 ] && drx=0
        [ "$dtx" -lt 0 ] && dtx=0
        rate_bps=$(( (drx + dtx) / elapsed ))
        RX_DAY=$((RX_DAY + drx)); TX_DAY=$((TX_DAY + dtx))
        RX_MONTH=$((RX_MONTH + drx)); TX_MONTH=$((TX_MONTH + dtx))
    fi
    LAST_RX=$rx; LAST_TX=$tx; LAST_TS=$now

    local rate_mbps day_total month_total
    rate_mbps=$(awk -v r="$rate_bps" 'BEGIN{printf "%.2f", r/1048576}')
    day_total=$((RX_DAY + TX_DAY))
    month_total=$((RX_MONTH + TX_MONTH))

    # --- 1. 速率突增告警 ---
    local spike_bytes=$((SPIKE_MBPS * 1048576))
    if [ "$rate_bps" -gt "$spike_bytes" ] && [ $((now - ALERT_SPIKE)) -gt "$ALERT_COOLDOWN" ]; then
        ALERT_SPIKE=$now
        save_state
        local ports_now
        ports_now=$(listening_ports_verbose)
        send_tg "$(cat <<EOF
🚨 <b>流量异常告警</b>
$(host_line)
⏰ $(esc "$(date '+%Y-%m-%d %H:%M:%S')")

📈 当前速率：<b>$(esc "$rate_mbps") MB/s</b>（阈值 $(esc "$SPIKE_MBPS") MB/s）
📥 今日下载：$(esc "$(human "$RX_DAY")")
📤 今日上传：$(esc "$(human "$TX_DAY")")
📦 今日总计：<b>$(esc "$(human "$day_total")")</b>

🔌 监听端口：$(esc "${ports_now:-未知}")

⚠️ <b>可能原因：未知进程大量跑流量（木马/后门/挖矿/被刷）</b>
🔍 请立即检查：<code>vps-monitor status</code>
EOF
)"
        log "速率告警：${rate_mbps} MB/s"
    fi

    # --- 2. 日额度告警 ---
    if [ "$DAILY_LIMIT_GB" -gt 0 ]; then
        local pct
        pct=$(awk -v t="$day_total" -v l="$DAILY_LIMIT_GB" 'BEGIN{printf "%d", t/1073741824/l*100}')
        if [ "$pct" -ge 100 ] && [ "$ALERT_DAY100" -eq 0 ]; then
            ALERT_DAY100=1; save_state
            send_tg "⚠️ <b>日流量已超限</b>
$(host_line)
📦 今日总计：<b>$(esc "$(human "$day_total")")</b>（日限 $(esc "$DAILY_LIMIT_GB") GB，$(esc "$pct")%）"
        elif [ "$pct" -ge 80 ] && [ "$ALERT_DAY80" -eq 0 ]; then
            ALERT_DAY80=1; save_state
            send_tg "⚠️ <b>日流量将用完</b>
$(host_line)
📦 今日总计：<b>$(esc "$(human "$day_total")")</b>（日限 $(esc "$DAILY_LIMIT_GB") GB，$(esc "$pct")%）"
        fi
    fi

    # --- 3. 月额度告警 ---
    if [ "$MONTHLY_LIMIT_GB" -gt 0 ]; then
        local pct
        pct=$(awk -v t="$month_total" -v l="$MONTHLY_LIMIT_GB" 'BEGIN{printf "%d", t/1073741824/l*100}')
        if [ "$pct" -ge 100 ] && [ "$ALERT_MON100" -eq 0 ]; then
            ALERT_MON100=1; save_state
            send_tg "⚠️ <b>月流量已超限</b>
$(host_line)
📦 本月累计：<b>$(esc "$(human "$month_total")")</b>（月限 $(esc "$MONTHLY_LIMIT_GB") GB，$(esc "$pct")%）"
        elif [ "$pct" -ge 80 ] && [ "$ALERT_MON80" -eq 0 ]; then
            ALERT_MON80=1; save_state
            send_tg "⚠️ <b>月流量将用完</b>
$(host_line)
📦 本月累计：<b>$(esc "$(human "$month_total")")</b>（月限 $(esc "$MONTHLY_LIMIT_GB") GB，$(esc "$pct")%）"
        fi
    fi

    # --- 4. 新增监听端口告警（独立冷却 ALERT_PORT） ---
    local ports_now new_ports=""
    ports_now=$(listening_ports)
    if [ -n "$ports_now" ]; then
        if [ -z "$BASELINE_PORTS" ]; then
            BASELINE_PORTS="$ports_now"
            log "端口基线已建立：$BASELINE_PORTS"
        else
            local p found
            for p in $(echo "$ports_now" | tr ',' ' '); do
                found=0
                for q in $(echo "$BASELINE_PORTS" | tr ',' ' '); do [ "$p" = "$q" ] && found=1 && break; done
                if [ "$found" -eq 0 ]; then
                    for q in $(echo "$ALERTED_PORTS" | tr ',' ' '); do [ "$p" = "$q" ] && found=2 && break; done
                    [ "$found" -eq 0 ] && new_ports="${new_ports:+$new_ports,}$p"
                fi
            done
            if [ -n "$new_ports" ] && [ $((now - ALERT_PORT)) -gt "$ALERT_COOLDOWN" ]; then
                ALERT_PORT=$now
                ALERTED_PORTS="${ALERTED_PORTS:+$ALERTED_PORTS,}$new_ports"
                save_state
                local verbose
                verbose=$(listening_ports_verbose)
                send_tg "$(cat <<EOF
🚨 <b>新增监听端口</b>
$(host_line)
⏰ $(esc "$(date '+%Y-%m-%d %H:%M:%S')")

🔌 新端口：<b>$(esc "$new_ports")</b>
📋 当前监听：$(esc "${verbose:-未知}")
📋 基线端口：$(esc "$BASELINE_PORTS")

⚠️ <b>该端口不在基线中，可能是后门/木马开的端口，请立即核查</b>
🔍 查进程：<code>ss -tlnp | grep $new_ports</code>
EOF
)"
                log "新增端口告警：$new_ports"
            fi
        fi
    fi

    # --- 5. 可疑出站告警 ---
    local sus
    sus=$(suspicious_outbound)
    if [ -n "$sus" ] && [ $((now - ALERT_SUS)) -gt "$ALERT_COOLDOWN" ]; then
        ALERT_SUS=$now
        save_state
        send_tg "🚨 <b>可疑出站连接</b>
$(host_line)
⏰ $(esc "$(date '+%Y-%m-%d %H:%M:%S')")

🔗 正在连接木马常用端口：<b>$(esc "$sus")</b>

⚠️ <b>可能是木马/后门在回连控制端，请立即核查进程</b>
🔍 查连接：<code>ss -tn state established</code>"
        log "可疑出站告警：$sus"
    fi

    save_state
    log "check ok：速率 ${rate_mbps} MB/s，今日 $(human "$day_total")，本月 $(human "$month_total")"
    return 0
}

# ---------- 每日报告 ----------
do_report() {
    load_conf
    load_state
    local ifc day_total month_total up load ports_now
    ifc=$(detect_iface)
    day_total=$((RX_DAY + TX_DAY))
    month_total=$((RX_MONTH + TX_MONTH))
    up=$(uptime -p 2>/dev/null || uptime | sed 's/.*up *//; s/, *[0-9]* user.*//')
    load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    ports_now=$(listening_ports)

    local month_line=""
    if [ "$MONTHLY_LIMIT_GB" -gt 0 ]; then
        local pct bar_n bar
        pct=$(awk -v t="$month_total" -v l="$MONTHLY_LIMIT_GB" 'BEGIN{printf "%d", t/1073741824/l*100}')
        bar_n=$((pct / 10)); [ "$bar_n" -gt 10 ] && bar_n=10
        bar=""
        [ "$bar_n" -gt 0 ] && bar=$(printf '█%.0s' $(seq 1 "$bar_n" 2>/dev/null))
        [ $((10 - bar_n)) -gt 0 ] && bar="$bar$(printf '░%.0s' $(seq 1 $((10 - bar_n)) 2>/dev/null))"
        month_line="
📆 本月累计：$(esc "$(human "$month_total")") / $(esc "$MONTHLY_LIMIT_GB") GB（$(esc "$pct")%）
$(esc "$bar")"
    else
        month_line="
📆 本月累计：$(esc "$(human "$month_total")")"
    fi

    local warn="✅ 未发现异常"
    [ -n "$ALERTED_PORTS" ] && warn="⚠️ 曾出现新增端口：$(esc "$ALERTED_PORTS")（已告警，请核查）"

    if send_tg "$(cat <<EOF
📊 <b>VPS 流量日报</b>
$(host_line)
📅 $(esc "$(date '+%Y-%m-%d')") · ⏱ 运行：$(esc "$up") · 📈 负载：$(esc "$load")

📥 今日下载：$(esc "$(human "$RX_DAY")")
📤 今日上传：$(esc "$(human "$TX_DAY")")
📦 今日总计：<b>$(esc "$(human "$day_total")")</b>${month_line}

🔌 监听端口：$(esc "${ports_now:-未知}")
${warn}
EOF
)"; then
        echo "日报已发到 TG"
    else
        echo "TG 未配置或发送失败，日报未发出（跑 vps-monitor config 配好再试）"
    fi
}

# ---------- 终端仪表盘 ----------
do_status() {
    load_conf
    load_state
    local ifc rx1 tx1 rx2 tx2 rate_mbps day_total month_total ip up load ports_now
    ifc=$(detect_iface)
    [ -z "$ifc" ] && { echo "找不到出口网卡"; return 1; }
    read -r rx1 tx1 <<< "$(read_bytes "$ifc")"
    sleep 2
    read -r rx2 tx2 <<< "$(read_bytes "$ifc")"
    # 采样差负数保护（中途重启/回绕）
    local dr=$((rx2 - rx1)) dt=$((tx2 - tx1))
    [ "$dr" -lt 0 ] && dr=0
    [ "$dt" -lt 0 ] && dt=0
    rate_mbps=$(awk -v r=$((dr + dt)) 'BEGIN{printf "%.2f", r/2/1048576}')
    day_total=$((RX_DAY + TX_DAY))
    month_total=$((RX_MONTH + TX_MONTH))
    ip=$(public_ip)
    up=$(uptime -p 2>/dev/null || uptime | sed 's/.*up *//; s/, *[0-9]* user.*//')
    load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    ports_now=$(listening_ports)

    local C_R='\033[0m' C_G='\033[32m' C_Y='\033[33m' C_C='\033[36m' C_B='\033[1m'
    local tg_state="未配置"
    [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] && tg_state="已配置"

    echo -e "${C_B}━━━━━━━━ VPS 流量监控 ━━━━━━━━${C_R}"
    printf '主机   : %s %s\n' "$(hostname)" "${ip:+($ip)}"
    printf '运行   : %s · 负载 %s\n' "$up" "$load"
    printf '网卡   : %s\n' "$ifc"
    echo -e "${C_B}━━━━━━━━ 流量 ━━━━━━━━${C_R}"
    printf '今日下载 : %s\n' "$(human "$RX_DAY")"
    printf '今日上传 : %s\n' "$(human "$TX_DAY")"
    printf '今日总计 : %s\n' "$(human "$day_total")"
    if [ "$DAILY_LIMIT_GB" -gt 0 ]; then
        printf '日限额   : %s GB（已用 %s%%）\n' "$DAILY_LIMIT_GB" "$(awk -v t="$day_total" -v l="$DAILY_LIMIT_GB" 'BEGIN{printf "%d", t/1073741824/l*100}')"
    fi
    printf '本月累计 : %s\n' "$(human "$month_total")"
    if [ "$MONTHLY_LIMIT_GB" -gt 0 ]; then
        printf '月限额   : %s GB（已用 %s%%）\n' "$MONTHLY_LIMIT_GB" "$(awk -v t="$month_total" -v l="$MONTHLY_LIMIT_GB" 'BEGIN{printf "%d", t/1073741824/l*100}')"
    fi
    printf '当前速率 : %s MB/s（告警阈值 %s MB/s）\n' "$rate_mbps" "$SPIKE_MBPS"
    echo -e "${C_B}━━━━━━━━ 安全 ━━━━━━━━${C_R}"
    printf '监听端口 : %s\n' "${ports_now:-未知}"
    printf '基线端口 : %s\n' "${BASELINE_PORTS:-未建立（跑一次 vps-monitor check 即建立）}"
    [ -n "$ALERTED_PORTS" ] && printf '⚠ 曾告警新增端口 : %s（请核查）\n' "$ALERTED_PORTS"
    printf 'TG 通知  : %s\n' "$tg_state"
    echo -e "${C_B}━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
    echo "命令：vps-monitor check（检查一次）· report（发日报）· test（TG 测试）· config（改配置）"
}

# ---------- 安装 ----------
do_install() {
    local self
    case "$0" in
        /dev/fd/*|*proc/self/fd*|*/dev/stdin*)
            echo "curl|bash 方式无法定位脚本文件，请先下载再安装："
            echo "  curl -Ls \"https://raw.githubusercontent.com/hahafeng9/vps-traffic-monitor/main/vps-monitor.sh?v=\$(date +%s)\" -o /tmp/vps-monitor.sh"
            echo "  bash /tmp/vps-monitor.sh install"
            return 1 ;;
    esac
    self=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 root 运行：sudo bash $self install"
        return 1
    fi
    if [ ! -f "$self" ]; then
        echo "找不到脚本文件 $self"
        return 1
    fi
    load_conf

    mkdir -p /usr/local/bin "$STATE_DIR"
    cp -f "$self" /usr/local/bin/vps-monitor
    chmod +x /usr/local/bin/vps-monitor

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -v 'vps-monitor' | crontab - 2>/dev/null

        cat > /etc/systemd/system/vps-monitor.service <<'UNIT'
[Unit]
Description=VPS traffic monitor check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-monitor check
UNIT

        cat > /etc/systemd/system/vps-monitor-report.service <<'UNIT'
[Unit]
Description=VPS traffic monitor daily report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-monitor report
UNIT

        cat > /etc/systemd/system/vps-monitor.timer <<UNIT
[Unit]
Description=Run vps-monitor check every 5 minutes

[Timer]
OnCalendar=*-*-* *:0/5
Persistent=true
Unit=vps-monitor.service

[Install]
WantedBy=timers.target
UNIT

        cat > /etc/systemd/system/vps-monitor-report.timer <<UNIT
[Unit]
Description=Run vps-monitor daily report

[Timer]
OnCalendar=*-*-* ${REPORT_HOUR}:00:00
Persistent=true
Unit=vps-monitor-report.service

[Install]
WantedBy=timers.target
UNIT

        systemctl daemon-reload
        systemctl enable --now vps-monitor.timer vps-monitor-report.timer
        echo "已安装（systemd）：check 每 5 分钟 · report 每天 ${REPORT_HOUR} 点"
    elif command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v 'vps-monitor'; \
         echo "*/5 * * * * /usr/local/bin/vps-monitor check >/dev/null 2>&1"; \
         echo "0 ${REPORT_HOUR} * * * /usr/local/bin/vps-monitor report >/dev/null 2>&1") | crontab -
        echo "已安装（cron）：check 每 5 分钟 · report 每天 ${REPORT_HOUR} 点"
    else
        echo "系统没有 systemd 也没有 crontab，请手动加定时任务"
        return 1
    fi
    echo "下一步：vps-monitor config 配置 TG 通知，然后 vps-monitor test 测试"

    # 安装完直接引导配置 TG（回车默认进入）
    printf '是否现在配置 TG 通知？[Y/n]：'
    read -r a
    if [ "$a" != "n" ] && [ "$a" != "N" ]; then
        do_config
    else
        echo "稍后运行 vps-monitor config 也可以配置"
    fi
}

# ---------- 配置 / 测试 / 基线 ----------
do_config() {
    load_conf
    echo "=== TG 通知配置 ==="
    echo "去 @BotFather 新建 bot 拿 token；给 bot 发 /start 后，用 @userinfobot 查 chat id。"
    echo "提示：VPS 在受限网络时，可装完后手动在 $CONF 里改 TG_API 为反代地址"
    printf 'BOT_TOKEN（当前：%s）：' "${BOT_TOKEN:+已设置}"
    read -r t; [ -n "$t" ] && BOT_TOKEN="$t"
    printf 'CHAT_ID（当前：%s）：' "${CHAT_ID:-未设置}"
    read -r c; [ -n "$c" ] && CHAT_ID="$c"
    printf '速率告警阈值 MB/s（当前 %s）：' "$SPIKE_MBPS"
    read -r v; [ -n "$v" ] && SPIKE_MBPS="$v"
    printf '日流量上限 GB，0=不限（当前 %s）：' "$DAILY_LIMIT_GB"
    read -r v; [ -n "$v" ] && DAILY_LIMIT_GB="$v"
    printf '月流量上限 GB，0=不限（当前 %s）：' "$MONTHLY_LIMIT_GB"
    read -r v; [ -n "$v" ] && MONTHLY_LIMIT_GB="$v"
    printf '每日报告时间，0-23 点（当前 %s）：' "$REPORT_HOUR"
    read -r v; [ -n "$v" ] && REPORT_HOUR="$v"
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
TG_API="$TG_API"
SPIKE_MBPS=$SPIKE_MBPS
DAILY_LIMIT_GB=$DAILY_LIMIT_GB
MONTHLY_LIMIT_GB=$MONTHLY_LIMIT_GB
REPORT_HOUR=$REPORT_HOUR
ALERT_COOLDOWN=$ALERT_COOLDOWN
EOF
    chmod 600 "$CONF"
    echo "配置已保存到 $CONF（600 权限）"
}

do_test() {
    load_conf
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        echo "TG 未配置，先跑：vps-monitor config"
        return 1
    fi
    if send_tg "✅ <b>vps-traffic-monitor 测试</b>
$(host_line)
⏰ $(esc "$(date '+%Y-%m-%d %H:%M:%S')")
TG 通知正常，流量监控已就绪。"; then
        echo "测试消息已发（去 TG 看看）"
    else
        echo "TG 发送失败，检查 token / chat id / 网络（详见 $LOG_FILE）"
        return 1
    fi
}

do_baseline() {
    load_conf
    load_state
    local p
    p=$(listening_ports)
    if [ -z "$p" ]; then echo "读不到监听端口（需要 ss 或 netstat）"; return 1; fi
    BASELINE_PORTS="$p"
    ALERTED_PORTS=""
    save_state
    echo "端口基线已更新：$p"
}

do_uninstall() {
    printf '确定卸载 vps-traffic-monitor？删除服务/定时任务/配置/状态 [y/N]：'
    read -r a
    [ "$a" != "y" ] && [ "$a" != "Y" ] && { echo "已取消"; return 0; }
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now vps-monitor.timer vps-monitor-report.timer vps-monitor.service vps-monitor-report.service 2>/dev/null
        rm -f /etc/systemd/system/vps-monitor*.service /etc/systemd/system/vps-monitor*.timer
        systemctl daemon-reload 2>/dev/null
    fi
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v 'vps-monitor' | crontab - 2>/dev/null
    fi
    rm -rf /usr/local/bin/vps-monitor "$CONF" "$STATE_DIR"
    echo "已卸载"
}

usage() {
    echo "vps-traffic-monitor v$VERSION — 免费 VPS 流量监控 + TG 告警"
    echo "用法：vps-monitor <命令>"
    echo "  install   一键安装（复制命令 + systemd 定时，无 systemd 用 cron）"
    echo "  status    终端仪表盘（流量、速率、端口、配置）"
    echo "  check     立即检查一次（速率/额度/端口/出站），异常发 TG"
    echo "  report    立即发一次 TG 流量日报"
    echo "  test      发一条 TG 测试消息"
    echo "  config    交互配置 TG token / chat id / 阈值"
    echo "  baseline  重新采集监听端口基线"
    echo "  uninstall 卸载"
}

case "${1:-status}" in
    install)  do_install ;;
    status)   do_status ;;
    check)    do_check ;;
    report)   do_report ;;
    test)     do_test ;;
    config)   do_config ;;
    baseline) do_baseline ;;
    uninstall) do_uninstall ;;
    -h|--help|help) usage ;;
    *) echo "未知命令：$1"; usage; exit 1 ;;
esac
