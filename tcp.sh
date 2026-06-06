#!/bin/bash

# ==================================================
# --- 0. 基础配置与环境检查 ---
# ==================================================
SCRIPT_PATH="/usr/local/bin/tcp.sh"
SHORTCUT_PATH="/usr/local/bin/t"
STATE_DIR="/var/lib/tcp-dashboard"
BBR_OPT="/etc/sysctl.d/99-tcp-dashboard-bbr.conf"
SYSCTL_OPT="/etc/sysctl.d/99-tcp-dashboard-network.conf"
LIMITS_OPT="/etc/security/limits.d/99-tcp-dashboard.conf"
GAI_BACKUP="$STATE_DIR/gai.conf.original"
GAI_CREATED="$STATE_DIR/gai.conf.created"
RPS_STATE="$STATE_DIR/rps-state"
RPS_SOCK_FLOW_STATE="$STATE_DIR/rps-sock-flow-original"
MSS_RULE_ADDED="$STATE_DIR/mss-rule-added"
SHORTCUT_CREATED="$STATE_DIR/shortcut-created"
SYSCTL_STATE="$STATE_DIR/sysctl-original"

# 确保以 root 权限运行
if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [ "$EUID" -ne 0 ]; then
    echo -e "\\033[0;31m错误: 必须使用 root 权限运行此脚本！\\033[0m"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 自定义画线函数
draw_line() {
    echo -e "${YELLOW}--------------------------------------------------${NC}"
}

# ==================================================
# --- 1. 本地安装与快捷键设置 ---
# ==================================================
current_script_path() {
    readlink -f "$0" 2>/dev/null || printf '%s\n' "$0"
}

install_local_script() {
    local source_path="$1"
    local destination="$2"
    local temp

    case "$source_path" in
        /dev/fd/*|/proc/*/fd/*|/dev/stdin|-)
            echo -e "${RED}当前启动方式没有稳定的本地脚本文件，拒绝自动安装。${NC}" >&2
            echo -e "${YELLOW}请先下载到本地文件，再执行: bash ./tcp.sh${NC}" >&2
            return 1
            ;;
    esac

    if [ ! -f "$source_path" ] || [ ! -r "$source_path" ]; then
        echo -e "${RED}找不到可读取的本地脚本文件: $source_path${NC}" >&2
        return 1
    fi

    temp=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if ! cp "$source_path" "$temp"; then
        rm -f "$temp"
        return 1
    fi
    if ! bash -n "$temp"; then
        echo -e "${RED}当前脚本不是有效的 Bash 脚本，拒绝安装。${NC}" >&2
        rm -f "$temp"
        return 1
    fi

    chmod 0755 "$temp"
    mv -f "$temp" "$destination"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [ "$(current_script_path)" != "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}>>> 正在安装脚本到本地系统...${NC}"
    mkdir -p /usr/local/bin
    if ! install_local_script "$(current_script_path)" "$SCRIPT_PATH"; then
        echo -e "${RED}安装失败，未修改现有脚本。${NC}" >&2
        exit 1
    fi

    # 不覆盖已有的同名命令
    if [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; then
        if [ "$(readlink -f "$SHORTCUT_PATH" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
            echo -e "${YELLOW}快捷命令 '$SHORTCUT_PATH' 已被占用，已保留原文件。${NC}"
        fi
    else
        install -d -m 0700 "$STATE_DIR"
        if ! ln -s "$SCRIPT_PATH" "$SHORTCUT_PATH"; then
            echo -e "${RED}快捷命令创建失败。${NC}" >&2
            exit 1
        fi
        if ! : >"$SHORTCUT_CREATED"; then
            rm -f "$SHORTCUT_PATH"
            exit 1
        fi
        echo -e "${GREEN}✅ 快捷命令 't' 已创建，以后在任意地方输入 t 即可打开面板。${NC}"
    fi

    # 核心：转为本地物理路径执行
    exec bash "$SCRIPT_PATH"
fi

# ==================================================
# --- 2. 脚本维护模块 (完全卸载) ---
# ==================================================
uninstall_script() {
    echo -e "\\n${RED}>>> 正在准备完全卸载脚本与快捷键...${NC}"
    read -p "确定要卸载吗？(这也会同时回退所有网络优化设置) [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在恢复网络默认设置...${NC}"
        if ! rollback_tcp_tune; then
            echo -e "${RED}回退未完全成功，已中止卸载。${NC}"
            return 1
        fi
        if [ -f "$SHORTCUT_CREATED" ] && [ "$(readlink -f "$SHORTCUT_PATH" 2>/dev/null)" = "$SCRIPT_PATH" ]; then
            rm -f "$SHORTCUT_PATH" && rm -f "$SHORTCUT_CREATED"
        fi
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}✅ 卸载成功：脚本配置已回退，脚本及其拥有的快捷键已移除。${NC}\\n"
        exit 0
    else
        echo -e "${GREEN}已取消卸载。${NC}"
        sleep 1
    fi
}

# ==================================================
# --- 3. TCP 调优功能模块 ---
# ==================================================
ensure_state_dir() {
    install -d -m 0700 "$STATE_DIR"
}

prepare_managed_file() {
    local path="$1" name="$2"
    ensure_state_dir
    if [ ! -e "$STATE_DIR/$name.backup" ] && [ ! -e "$STATE_DIR/$name.created" ]; then
        if [ -e "$path" ]; then
            cp -p "$path" "$STATE_DIR/$name.backup"
        else
            : >"$STATE_DIR/$name.created"
        fi
    fi
}

restore_managed_file() {
    local path="$1" name="$2"
    if [ -e "$STATE_DIR/$name.backup" ]; then
        cp -p "$STATE_DIR/$name.backup" "$path" || return 1
        rm -f "$STATE_DIR/$name.backup"
    elif [ -e "$STATE_DIR/$name.created" ]; then
        rm -f "$path" || return 1
        rm -f "$STATE_DIR/$name.created"
    fi
}

snapshot_sysctls() {
    local config="$1" key value
    ensure_state_dir
    [ -e "$SYSCTL_STATE" ] || : >"$SYSCTL_STATE"
    while IFS= read -r key; do
        grep -qF "${key}"$'\t' "$SYSCTL_STATE" && continue
        value=$(sysctl -n "$key" 2>/dev/null) || continue
        printf '%s\t%s\n' "$key" "$value" >>"$SYSCTL_STATE"
    done < <(awk -F= '/^[[:space:]]*[a-z]/ {gsub(/[[:space:]]/, "", $1); print $1}' "$config")
}

restore_sysctls() {
    local key value failed=0
    [ -e "$SYSCTL_STATE" ] || return 0
    while IFS=$'\t' read -r key value; do
        sysctl -w "$key=$value" >/dev/null || failed=1
    done <"$SYSCTL_STATE"
    [ "$failed" -eq 0 ] || return 1
    rm -f "$SYSCTL_STATE"
}

network_interfaces() {
    local path eth
    for path in /sys/class/net/*; do
        eth=${path##*/}
        case "$eth" in
            lo|docker*|veth*|br-*|any*|tung3*|sit0|tun*|wg*) continue ;;
        esac
        printf '%s\n' "$eth"
    done
}

rps_cpu_mask() {
    local cpu_count="$1" full_groups remainder mask
    [ "$cpu_count" -gt 0 ] || return 1
    full_groups=$((cpu_count / 32))
    remainder=$((cpu_count % 32))
    if [ "$remainder" -gt 0 ]; then
        printf -v mask '%x' "$(((1 << remainder) - 1))"
    else
        mask=ffffffff
        full_groups=$((full_groups - 1))
    fi
    while [ "$full_groups" -gt 0 ]; do
        mask+=",ffffffff"
        full_groups=$((full_groups - 1))
    done
    printf '%s\n' "$mask"
}

enable_bbr_tune() {
    echo -e "\\n${YELLOW}>>> 正在激活 BBR + FQ 拥塞算法...${NC}"
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo -e "${RED}当前内核不支持 BBR，未修改配置。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi
    prepare_managed_file "$BBR_OPT" bbr-config || return 1
    cat >"$BBR_OPT" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if [ $? -ne 0 ]; then restore_managed_file "$BBR_OPT" bbr-config; return 1; fi
    snapshot_sysctls "$BBR_OPT"
    if ! sysctl -p "$BBR_OPT"; then
        rollback_tcp_tune
        echo -e "${RED}BBR 配置应用失败，请检查上方错误。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi
    echo -e "\n${GREEN}✅ BBR + FQ 已应用并持久化。${NC}"
    echo -e "${YELLOW}==================================================${NC}"
	sleep 0.3
    printf "  %-24s : ${GREEN}%-15s${NC}\n" "Current Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    sleep 0.3
	printf "  %-24s : ${GREEN}%-15s${NC}\n" "Default Packet Scheduler" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    sleep 0.3
    echo -e "${YELLOW}==================================================${NC}"
    # ======================================================================

    read -r -p "按回车返回..."
}

smart_tune_tcp_tune() {
    local old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control)
    local old_somax=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "默认")
    local old_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
    local old_file=$(ulimit -n)

    echo -e "\\n${YELLOW}>>> 正在启动系统环境扫描...${NC}"
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local cpu_count=$(nproc)
    local buf_bytes=$((mem_total_kb * 5 / 100 * 1024))

    echo -e "  - 核心数: ${CYAN}${cpu_count}${NC} | 内存总量: ${CYAN}$((mem_total_kb / 1024))MB${NC}"
    echo -e "  - 动态缓冲区分配: ${CYAN}$((buf_bytes / 1024 / 1024))MB${NC} (基于总内存 5%)"
    sleep 0.5

    echo -e "\\n${YELLOW}>>> 正在写入网络内核配置...${NC}"
    
    prepare_managed_file "$SYSCTL_OPT" network-config || return 1
    cat >"$SYSCTL_OPT" <<EOF
# --- 基础队列算法 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 缓冲区与容量优化 ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = ${buf_bytes}
net.core.wmem_max = ${buf_bytes}
net.ipv4.tcp_rmem = 4096 87380 ${buf_bytes}
net.ipv4.tcp_wmem = 4096 65536 ${buf_bytes}
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152


# --- 翻墙/Reality 环境针对性调优 ---
# 减少发送队列积压
net.ipv4.tcp_notsent_lowat = 16384
# 开启 MTU 探测，解决部分运营商阻断 ICMP 导致的连接黑洞
net.ipv4.tcp_mtu_probing = 1
# 扩容 UDP 缓冲区
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

    # 开启 ECN（显式拥塞通知）
net.ipv4.tcp_ecn = 1

# 限制孤儿连接数
net.ipv4.tcp_max_orphans = 32768

# --- 连接稳定性优化 ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fastopen = 3
EOF
    if [ $? -ne 0 ]; then restore_managed_file "$SYSCTL_OPT" network-config; return 1; fi
    snapshot_sysctls "$SYSCTL_OPT"
    if ! sysctl -p "$SYSCTL_OPT"; then
        rollback_tcp_tune
        echo -e "${RED}部分内核参数不受当前系统支持，请检查上方错误。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    echo -e "\n${GREEN}✅ 网络参数已应用：${NC}"
    draw_line
    printf "  %-30s : ${GREEN}%-15s${NC}\n" "TCP Not-Sent Low Watermark" "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
    sleep 0.3
    printf "  %-30s : ${GREEN}%-15s${NC}\n" "MTU Probing" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    sleep 0.3
    printf "  %-30s : ${GREEN}%-15s${NC}\n" "UDP Receive Minimum" "$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null)"
    sleep 0.3
    printf "  %-30s : ${GREEN}%-15s${NC}\n" "ECN" "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)"
    sleep 0.3
    printf "  %-30s : ${GREEN}%-15s${NC}\n" "Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    # ======================================================================

    mkdir -p /etc/security/limits.d/
    prepare_managed_file "$LIMITS_OPT" limits-config || return 1
    cat >"$LIMITS_OPT" <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
    if [ $? -ne 0 ]; then restore_managed_file "$LIMITS_OPT" limits-config; return 1; fi

    if command -v iptables &>/dev/null; then
        ensure_state_dir
        if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            if iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; then
                : >"$MSS_RULE_ADDED"
            else
                echo -e "${RED}MSS Clamp 规则添加失败。${NC}"
                rollback_tcp_tune
                return 1
            fi
        fi
        echo -e "${GREEN}  ✔ MSS Clamp 规则已存在。${NC}"
    fi

	# ======= 【新加入的代码】=======
    # 强行刷新当前进程的限制，让主菜单状态栏实时显示优化后的数值
    ulimit -n 1048576 2>/dev/null || true
    # ===============================

    echo -e "\\n${GREEN}✅ 调优完成，当前参数:${NC}"
    draw_line
	sleep 0.3
    printf "  %-12s: %-15s -> ${GREEN}%-15s${NC}\\n" "拥塞算法" "$old_bbr" "bbr"
	sleep 0.3
    printf "  %-12s: %-15s -> ${GREEN}%-15s${NC}\\n" "最大连接" "$old_somax" "65535"
	sleep 0.3
    printf "  %-12s: %-15s -> ${GREEN}%-15s${NC}\\n" "文件句柄" "$old_file" "1048576"
	sleep 0.3
    printf "  %-12s: %-15s -> ${GREEN}%-15s${NC}\\n" "网络缓冲" "$((old_rmem / 1024 / 1024))MB" "$((buf_bytes / 1024 / 1024))MB"
	sleep 0.3
    echo -e "\\n${PURPLE}ℹ sysctl 配置已写入 $SYSCTL_OPT${NC}"
	sleep 0.3
    echo -e "${PURPLE}ℹ 重启服务器后配置依然生效，回退请使用选项 5${NC}"

    read -p "按回车返回..."
}

optimize_nic_tune() {
    echo -e "\\n${YELLOW}>>> 正在配置接收包转向 (RPS)...${NC}"
    local cpu_count rps_cpus eth rps_file rfc_file
    local -a interfaces
    cpu_count=$(nproc)
    rps_cpus=$(rps_cpu_mask "$cpu_count")
    mapfile -t interfaces < <(network_interfaces)
    ensure_state_dir
    if [ ! -f "$RPS_STATE" ]; then
        : >"$RPS_STATE"
        for eth in "${interfaces[@]}"; do
            for rps_file in "/sys/class/net/$eth"/queues/rx-*/rps_cpus; do
                [ -f "$rps_file" ] && printf '%s\t%s\n' "$rps_file" "$(cat "$rps_file")" >>"$RPS_STATE"
            done
            for rfc_file in "/sys/class/net/$eth"/queues/rx-*/rps_flow_cnt; do
                [ -f "$rfc_file" ] && printf '%s\t%s\n' "$rfc_file" "$(cat "$rfc_file")" >>"$RPS_STATE"
            done
        done
    fi
    if [ ! -f "$RPS_SOCK_FLOW_STATE" ]; then
        sysctl -n net.core.rps_sock_flow_entries >"$RPS_SOCK_FLOW_STATE.tmp" || return 1
        mv "$RPS_SOCK_FLOW_STATE.tmp" "$RPS_SOCK_FLOW_STATE"
    fi
    for eth in "${interfaces[@]}"; do
        for rps_file in "/sys/class/net/$eth"/queues/rx-*/rps_cpus; do [ ! -f "$rps_file" ] || echo "$rps_cpus" >"$rps_file" || { rollback_tcp_tune; return 1; }; done
        for rfc_file in "/sys/class/net/$eth"/queues/rx-*/rps_flow_cnt; do [ ! -f "$rfc_file" ] || echo "4096" >"$rfc_file" || { rollback_tcp_tune; return 1; }; done
    done
    if ! sysctl -w net.core.rps_sock_flow_entries=32768; then
        echo -e "${RED}RPS 全局流表配置失败。${NC}"
        rollback_tcp_tune
        return 1
    fi
    echo -e "\n${GREEN}✅ RPS 配置已应用：${NC}"
    draw_line
    echo -e "${PURPLE}ℹ 已将 RPS CPU mask 配置为 $rps_cpus。${NC}\n"
    # ======================================================================

    read -p "按回车返回..."
}

set_ipv4_priority() {
    echo -e "\\n${YELLOW}>>> 正在调整系统互联网协议优先级...${NC}"
    ensure_state_dir
    if [ ! -e "$GAI_BACKUP" ] && [ ! -e "$GAI_CREATED" ]; then
        if [ -e /etc/gai.conf ]; then
            cp -p /etc/gai.conf "$GAI_BACKUP"
        else
            : >"$GAI_CREATED"
        fi
    fi
    if [ ! -f /etc/gai.conf ]; then
        : >/etc/gai.conf
    fi

    if ! grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
        echo "precedence ::ffff:0:0/96  100" >>/etc/gai.conf
    fi

    echo -e "\n${GREEN}✅ 优化成功！当前系统已设置为 [ IPv4 优先 ]。${NC}"
    read -p "按回车返回..."
}

rollback_tcp_tune() {
    local state_path state_value failed=0
    restore_managed_file "$SYSCTL_OPT" network-config || failed=1
    restore_managed_file "$LIMITS_OPT" limits-config || failed=1
    restore_managed_file "$BBR_OPT" bbr-config || failed=1

    if [ -f "$GAI_BACKUP" ]; then
        cp -p "$GAI_BACKUP" /etc/gai.conf && rm -f "$GAI_BACKUP" || failed=1
    elif [ -f "$GAI_CREATED" ]; then
        rm -f /etc/gai.conf || failed=1
    fi
    [ "$failed" -ne 0 ] || rm -f "$GAI_CREATED"

    if command -v iptables &>/dev/null && [ -f "$MSS_RULE_ADDED" ]; then
        if iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; then rm -f "$MSS_RULE_ADDED"; else failed=1; fi
    fi

    if [ -f "$RPS_STATE" ]; then
        while IFS=$'\t' read -r state_path state_value; do
            [ ! -f "$state_path" ] || printf '%s\n' "$state_value" >"$state_path" || failed=1
        done <"$RPS_STATE"
        [ "$failed" -ne 0 ] || rm -f "$RPS_STATE"
    fi
    if [ -f "$RPS_SOCK_FLOW_STATE" ]; then
        if sysctl -w "net.core.rps_sock_flow_entries=$(cat "$RPS_SOCK_FLOW_STATE")"; then rm -f "$RPS_SOCK_FLOW_STATE"; else failed=1; fi
    fi

    sysctl --system || failed=1
    restore_sysctls || failed=1
    if [ "$failed" -ne 0 ]; then
        echo -e "${RED}回退未完全成功；恢复状态已保留，可重试。${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ 回退完成：已移除脚本配置并恢复脚本保存的原始状态。${NC}"
}


# ==================================================
# --- 4. 主循环菜单 (动态闭环重构) ---
# ==================================================
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

while true; do
    # --- 实时动态状态检测 ---
    # 1. 检测 IPv4 优先状态
    if [ -f /etc/gai.conf ] && grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf; then
        status_ipv4="${GREEN}[已激活]${NC}"
    else
        status_ipv4="${RED}[未开启]${NC}"
    fi

    # 2. 检测 BBR 状态
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        status_bbr="${GREEN}[已激活]${NC}"
    else
        status_bbr="${RED}[未开启]${NC}"
    fi

    # 3. 检测内核调优状态
    if [ -f "$SYSCTL_OPT" ]; then
        status_sysctl="${GREEN}[已激活]${NC}"
    else
        status_sysctl="${RED}[未开启]${NC}"
    fi

    # 4. 检测网卡队列状态 (通过全局套接字流控制条目状态进行智能检测)
    if [ "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" = "32768" ]; then
        status_nic="${GREEN}[已激活]${NC}"
    else
        status_nic="${RED}[未开启]${NC}"
    fi

    # --- 渲染菜单界面 ---
    clear
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}              TCP/UDP 网络配置面板              ${NC}"
    echo -e "${GREEN}              本地安装路径: $SCRIPT_PATH${NC}"
    echo -e "${GREEN}                    快捷命令: t                    ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "  1. 设置 IPv4 优先解析     -> $status_ipv4  :[解决 IPv6 绕路导致的握手卡顿]"
    echo -e "  2. 开启 BBR + FQ          -> $status_bbr  :[设置拥塞控制与队列算法]"
    echo -e "  3. 网络内核参数调优       -> $status_sysctl  :[配置缓冲区、队列与连接参数]"
    echo -e "  4. 接收包转向 (RPS)        -> $status_nic  :[配置接收队列 CPU mask 与流表]"
    echo -e "  5. 回退脚本配置            -> [恢复脚本保存的原始状态]"
    echo -e "  6. 彻底卸载面板脚本"
    echo -e "  0. 退出脚本"
    draw_line
    echo -e "当前状态: 算法: ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control)${NC} | 句柄: ${GREEN}$(ulimit -n)${NC}"
    draw_line
    
    read -p "请选择数字 [0-6]: " t_opt
    case "$t_opt" in
    1) set_ipv4_priority ;;
    2) enable_bbr_tune ;;
    3) smart_tune_tcp_tune ;;
    4) optimize_nic_tune ;;
    5) rollback_tcp_tune && read -p "按回车返回..." ;;
    6) uninstall_script ;;
    0) exit 0 ;;
    *) echo -e "${RED}输入错误，请输入正确数字！${NC}" && sleep 1 ;;
    esac
done
