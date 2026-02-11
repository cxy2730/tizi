#!/bin/bash
#
# BBR 一键加速脚本 (Debian)
# 支持 IPv4 + IPv6 双栈, 面向中国优化
#

set -e

# ============== 颜色定义 ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ============== 前置检查 ==============
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 sudo 运行此脚本: sudo bash $0"
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "无法检测操作系统"
    fi
    source /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        warn "当前系统为 $ID，此脚本为 Debian 设计，继续运行可能存在兼容性问题"
    fi
    info "检测到系统: $PRETTY_NAME"
}

# ============== 查看当前 BBR 状态 ==============
show_bbr_status() {
    echo ""
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}  BBR 当前状态${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo ""

    # 内核版本
    echo -e "${CYAN}内核版本:${RESET}       $(uname -r)"

    # 拥塞控制算法
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    echo -e "${CYAN}拥塞控制:${RESET}       $CURRENT_CC"

    # 队列调度
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    echo -e "${CYAN}队列调度:${RESET}       $CURRENT_QDISC"

    # BBR 模块
    if lsmod 2>/dev/null | grep -q tcp_bbr; then
        echo -e "${CYAN}BBR 模块:${RESET}       ${GREEN}已加载${RESET}"
    else
        echo -e "${CYAN}BBR 模块:${RESET}       ${RED}未加载${RESET}"
    fi

    # BBR 模块信息
    BBR_INFO=$(modinfo tcp_bbr 2>/dev/null | grep -i 'description\|version' || echo "不可用")
    echo -e "${CYAN}模块信息:${RESET}       $BBR_INFO"

    # IPv6 状态
    IPV6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "未知")
    if [[ "$IPV6_DISABLED" == "0" ]]; then
        echo -e "${CYAN}IPv6:${RESET}           ${GREEN}已启用${RESET}"
    else
        echo -e "${CYAN}IPv6:${RESET}           ${RED}已禁用${RESET}"
    fi

    # 缓冲区
    RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "未知")
    WMEM=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "未知")
    echo -e "${CYAN}接收缓冲区:${RESET}     $RMEM"
    echo -e "${CYAN}发送缓冲区:${RESET}     $WMEM"

    # 可用拥塞控制
    AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
    echo -e "${CYAN}可用算法:${RESET}       $AVAILABLE"

    echo ""
}

# ============== 启用 BBR 加速 ==============
enable_bbr() {
    info "配置 BBR 拥塞控制算法..."

    # 检查当前是否已启用 BBR (net.ipv4.tcp_congestion_control 同时控制 IPv4 和 IPv6)
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        info "BBR 已处于启用状态 (IPv4 + IPv6)"
    else
        # 加载 tcp_bbr 模块
        modprobe tcp_bbr 2>/dev/null || true
        mkdir -p /etc/modules-load.d
        if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
            echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
        fi

        # 设置 BBR 为默认拥塞控制
        sysctl -w net.core.default_qdisc=fq          >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

        # 持久化写入 sysctl.conf
        sed -i '/net.core.default_qdisc/d'          /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        cat >> /etc/sysctl.conf <<SYSEOF

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSEOF
    fi

    # 网络参数优化 (不限速, 面向中国优化)
    sed -i '/# 网络缓冲区优化/d'      /etc/sysctl.conf
    sed -i '/# 中国跨境线路优化/d'    /etc/sysctl.conf
    sed -i '/# UDP 优化/d'            /etc/sysctl.conf
    sed -i '/# IPv6 双栈支持/d'       /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d'          /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d'          /etc/sysctl.conf
    sed -i '/net.core.rmem_default/d'      /etc/sysctl.conf
    sed -i '/net.core.wmem_default/d'      /etc/sysctl.conf
    sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf
    sed -i '/net.core.somaxconn/d'         /etc/sysctl.conf
    sed -i '/net.core.optmem_max/d'        /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_rmem/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_wmem/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_syn_backlog/d'  /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_mtu_probing/d'   /etc/sysctl.conf
    sed -i '/net.ipv4.udp_mem/d'           /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d'      /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fin_timeout/d'   /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_time/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_intvl/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_probes/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_tw_buckets/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_syncookies/d'    /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_tw_reuse/d'      /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_timestamps/d'    /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_sack/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fack/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_adv_win_scale/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    sed -i '/net.ipv4.ip_local_port_range/d' /etc/sysctl.conf
    sed -i '/net.ipv4.ip_forward/d'        /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.forwarding/d'       /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.forwarding/d'   /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.accept_ra/d'        /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.accept_ra/d'    /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.disable_ipv6/d'     /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.lo.disable_ipv6/d'      /etc/sysctl.conf
    sed -i '/net.ipv6.ip6frag_high_thresh/d'       /etc/sysctl.conf
    sed -i '/net.ipv6.ip6frag_low_thresh/d'        /etc/sysctl.conf
    sed -i '/net.ipv6.route.gc_timeout/d'          /etc/sysctl.conf
    sed -i '/net.ipv6.neigh.default.gc_stale_time/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.router_solicitations/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<SYSEOF

# 网络缓冲区优化 (不限速, 面向中国优化)
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=65536
net.core.somaxconn=8192
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.udp_mem=65536 131072 524288

# 中国跨境线路优化 (高延迟高丢包)
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_tw_buckets=65536
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.ip_forward=1

# UDP 优化
net.core.optmem_max=65536

# IPv6 双栈支持 + BBR IPv6 优化
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv6.conf.all.router_solicitations=-1
net.ipv6.ip6frag_high_thresh=524288
net.ipv6.ip6frag_low_thresh=393216
net.ipv6.route.gc_timeout=600
net.ipv6.neigh.default.gc_stale_time=120
SYSEOF

    # 立即生效
    sysctl -p >/dev/null 2>&1 || true

    # 验证 (net.ipv4.tcp_congestion_control 同时生效于 IPv4 和 IPv6)
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    IPV6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        info "BBR 启用成功 (IPv4 + IPv6), 网络缓冲区已优化, 无带宽限制"
    else
        warn "BBR 启用可能失败, 当前拥塞控制: $CURRENT_CC"
    fi
    if [[ "$IPV6_DISABLED" == "0" ]]; then
        info "IPv6 已启用, BBR 对 IPv6 生效"
    else
        warn "IPv6 可能被禁用, 请检查 net.ipv6.conf.all.disable_ipv6"
    fi
}

# ============== 更新系统内核 (BBR) ==============
update_kernel_bbr() {
    info "从 Debian 官方仓库更新内核以获取最新 BBR..."

    CURRENT_KERNEL=$(uname -r)
    info "当前运行内核: $CURRENT_KERNEL"

    # 获取 Debian 版本代号
    source /etc/os-release
    CODENAME="${VERSION_CODENAME:-trixie}"

    # ---------- 添加 Debian 官方 backports 源 (获取最新内核) ----------
    BACKPORTS_LIST="/etc/apt/sources.list.d/backports.list"
    BACKPORTS_ENTRY="deb http://deb.debian.org/debian ${CODENAME}-backports main"

    if ! grep -rqs "${CODENAME}-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        info "添加 Debian 官方 backports 源: ${CODENAME}-backports"
        echo "$BACKPORTS_ENTRY" > "$BACKPORTS_LIST"
    else
        info "Debian backports 源已存在"
    fi

    apt-get update -y

    # ---------- 检测架构并安装内核 ----------
    DEB_ARCH=$(dpkg --print-architecture)
    case "$DEB_ARCH" in
        amd64)  KERNEL_PKG="linux-image-amd64"  ;;
        arm64)  KERNEL_PKG="linux-image-arm64"  ;;
        i386)   KERNEL_PKG="linux-image-686"    ;;
        armhf)  KERNEL_PKG="linux-image-armmp"  ;;
        *)      KERNEL_PKG="linux-image-${DEB_ARCH}" ;;
    esac

    # 优先从 backports 安装最新内核
    info "尝试从 ${CODENAME}-backports 安装最新内核..."
    if apt-get install -y -t "${CODENAME}-backports" "$KERNEL_PKG" "linux-headers-${DEB_ARCH}" 2>/dev/null; then
        info "已从 backports 安装最新内核"
    else
        info "backports 无更新内核, 从 Debian 官方主仓库安装..."
        apt-get install -y "$KERNEL_PKG" "linux-headers-${DEB_ARCH}" 2>/dev/null || \
            warn "内核安装失败, 请手动运行: apt-get install $KERNEL_PKG"
    fi

    # ---------- 确保 BBR 参数生效 ----------
    enable_bbr

    # ---------- 对比内核版本 ----------
    NEW_KERNEL=$(dpkg -l | grep -E "^ii\s+linux-image-[0-9]" | awk '{print $3}' | sort -V | tail -1)
    info "当前运行内核: $CURRENT_KERNEL"
    info "已安装最新内核: ${NEW_KERNEL:-未知}"

    # 显示 BBR 版本信息
    BBR_INFO=$(modinfo tcp_bbr 2>/dev/null | grep -i 'description\|version' || echo "BBR 模块信息不可用")
    info "BBR 模块信息: $BBR_INFO"

    PARSED_VER=$(echo "$NEW_KERNEL" | sed -n 's/^\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')
    if [[ -n "$PARSED_VER" && "$CURRENT_KERNEL" != *"$PARSED_VER"* ]]; then
        warn "新内核需要重启后生效, 重启后将使用最新 BBR"
        read -rp "$(echo -e "${CYAN}是否立即重启? [y/N]: ${RESET}")" DO_REBOOT
        if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
            info "系统将在 3 秒后重启..."
            sleep 3
            reboot
        fi
    else
        info "当前已运行最新官方内核, BBR 为最新版本"
    fi
}

# ============== 卸载 BBR 优化 ==============
uninstall_bbr() {
    echo ""
    echo -e "${YELLOW}══════════ 卸载确认 ══════════${RESET}"
    read -rp "$(echo -e "${RED}确认清理 BBR 及网络优化参数? [y/N]: ${RESET}")" CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "已取消"
        return
    fi

    sed -i '/# BBR 拥塞控制/d'                  /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d'                /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d'       /etc/sysctl.conf
    sed -i '/# 网络缓冲区优化/d'                /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d'                     /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d'                     /etc/sysctl.conf
    sed -i '/net.core.rmem_default/d'                 /etc/sysctl.conf
    sed -i '/net.core.wmem_default/d'                 /etc/sysctl.conf
    sed -i '/net.core.netdev_max_backlog/d'           /etc/sysctl.conf
    sed -i '/net.core.somaxconn/d'                    /etc/sysctl.conf
    sed -i '/net.core.optmem_max/d'                   /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_rmem/d'                     /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_wmem/d'                     /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_syn_backlog/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_slow_start_after_idle/d'    /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_mtu_probing/d'              /etc/sysctl.conf
    sed -i '/net.ipv4.udp_mem/d'                      /etc/sysctl.conf
    sed -i '/# 中国跨境线路优化/d'                /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d'                 /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fin_timeout/d'              /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_time/d'           /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_intvl/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_probes/d'         /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_tw_buckets/d'           /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_syncookies/d'               /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_tw_reuse/d'                 /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_timestamps/d'               /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_sack/d'                     /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fack/d'                     /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_window_scaling/d'           /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_adv_win_scale/d'            /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_notsent_lowat/d'            /etc/sysctl.conf
    sed -i '/net.ipv4.ip_local_port_range/d'          /etc/sysctl.conf
    sed -i '/net.ipv4.ip_forward/d'                   /etc/sysctl.conf
    sed -i '/# UDP 优化/d'                          /etc/sysctl.conf
    sed -i '/# IPv6 双栈支持/d'                      /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.disable_ipv6/d'        /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.disable_ipv6/d'    /etc/sysctl.conf
    sed -i '/net.ipv6.conf.lo.disable_ipv6/d'         /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.forwarding/d'          /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.forwarding/d'      /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.accept_ra/d'           /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.accept_ra/d'       /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.router_solicitations/d' /etc/sysctl.conf
    sed -i '/net.ipv6.ip6frag_high_thresh/d'          /etc/sysctl.conf
    sed -i '/net.ipv6.ip6frag_low_thresh/d'           /etc/sysctl.conf
    sed -i '/net.ipv6.route.gc_timeout/d'             /etc/sysctl.conf
    sed -i '/net.ipv6.neigh.default.gc_stale_time/d'  /etc/sysctl.conf
    # 清理空行
    sed -i '/^$/N;/^\n$/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    info "BBR 及网络优化参数已清理"
    echo ""
}

# ============== 主流程 ==============
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}║  BBR 一键加速脚本 (Debian, 面向中国) ║${RESET}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${RESET}"
    echo ""

    check_root
    check_os

    echo -e "${CYAN}请选择操作:${RESET}"
    echo "  1) 启用 BBR + 网络优化 (IPv4+IPv6)"
    echo "  2) 更新内核到最新版 (获取最新 BBR)"
    echo "  3) 查看当前 BBR 状态"
    echo "  4) 卸载 BBR 及网络优化"
    read -rp "$(echo -e "${CYAN}请选择 [1/2/3/4, 默认 1]: ${RESET}")" ACTION
    ACTION=${ACTION:-1}

    case "$ACTION" in
        1)
            enable_bbr
            show_bbr_status
            ;;
        2)
            update_kernel_bbr
            ;;
        3)
            show_bbr_status
            ;;
        4)
            uninstall_bbr
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

main "$@"
