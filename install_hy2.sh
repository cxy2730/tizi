#!/bin/bash
#
# Hysteria 2 一键安装脚本 (Debian 13)
# 仓库: https://github.com/apernet/hysteria
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

check_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  HY_ARCH="amd64" ;;
        aarch64) HY_ARCH="arm64" ;;
        armv7l)  HY_ARCH="arm"   ;;
        i686)    HY_ARCH="386"   ;;
        *)       error "不支持的架构: $ARCH" ;;
    esac
    info "系统架构: $ARCH -> hysteria-linux-$HY_ARCH"
}

# ============== 检测 VPS IP 地址 ==============
detect_ip() {
    info "检测 VPS IP 地址..."

    # 检测 IPv4 (防止 set -e 下退出)
    IPV4=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || true)
    if [[ -z "$IPV4" ]]; then
        IPV4=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || true)
    fi
    if [[ -z "$IPV4" ]]; then
        IPV4=$(curl -s4 --max-time 5 api.ipify.org 2>/dev/null || true)
    fi

    # 检测 IPv6 (防止 set -e 下退出)
    IPV6=$(curl -s6 --max-time 5 ip.sb 2>/dev/null || true)
    if [[ -z "$IPV6" ]]; then
        IPV6=$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null || true)
    fi
    if [[ -z "$IPV6" ]]; then
        IPV6=$(curl -s6 --max-time 5 api6.ipify.org 2>/dev/null || true)
    fi

    echo ""
    if [[ -n "$IPV4" ]]; then
        info "IPv4 地址: $IPV4"
    else
        warn "未检测到 IPv4 地址 (仅 IPv6 网络)"
    fi

    if [[ -n "$IPV6" ]]; then
        info "IPv6 地址: $IPV6"
    else
        warn "未检测到 IPv6 地址 (仅 IPv4 网络)"
    fi

    if [[ -z "$IPV4" && -z "$IPV6" ]]; then
        warn "无法检测到任何公网 IP, 请确认网络连接"
    fi

    # 检测是否为双栈
    if [[ -n "$IPV4" && -n "$IPV6" ]]; then
        info "网络模式: 双栈 (IPv4 + IPv6)"
        STACK_MODE="dual"
    elif [[ -n "$IPV4" ]]; then
        info "网络模式: 仅 IPv4"
        STACK_MODE="v4only"
    else
        info "网络模式: 仅 IPv6"
        STACK_MODE="v6only"
    fi
    echo ""
}

# ============== 安装依赖 ==============
install_deps() {
    info "更新软件包索引并安装依赖..."
    apt-get update -y
    apt-get install -y curl wget openssl coreutils dnsutils
}

# ============== 安装 Hysteria 2 ==============
install_hysteria() {
    info "使用官方脚本安装 Hysteria 2..."
    bash <(curl -fsSL https://get.hy2.sh/)
    if ! command -v hysteria &>/dev/null; then
        error "Hysteria 2 安装失败"
    fi
    info "Hysteria 2 安装成功: $(hysteria version 2>/dev/null || echo '已安装')"
}

# ============== 生成随机密码 ==============
generate_password() {
    openssl rand -base64 16 | tr -d '=/+'
}

# ============== 配置 ==============
configure_hysteria() {
    CONFIG_DIR="/etc/hysteria"
    CONFIG_FILE="$CONFIG_DIR/config.yaml"
    mkdir -p "$CONFIG_DIR"

    echo ""
    echo -e "${CYAN}========== Hysteria 2 配置 ==========${RESET}"
    echo ""

    # ---------- 监听端口 ----------
    echo -e "${CYAN}端口建议 (面向中国优化):${RESET}"
    echo "  443  - HTTPS 默认端口, 伪装性最强 (推荐)"
    echo "  8443 - 备用 HTTPS 端口"
    echo "  80   - HTTP 端口 (部分运营商不封)"
    echo "  避免使用常见代理端口: 1080, 8080, 10808 等"
    read -rp "$(echo -e "${CYAN}监听端口 [默认 443]: ${RESET}")" PORT
    PORT=${PORT:-443}

    # 检查端口是否被占用
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || ss -ulnp 2>/dev/null | grep -q ":${PORT} "; then
        OCCUPIED_BY=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | awk '{print $NF}' | head -1)
        warn "端口 $PORT 已被占用: $OCCUPIED_BY"
        read -rp "$(echo -e "${YELLOW}是否继续? 可能需要先停止占用该端口的服务 [y/N]: ${RESET}")" CONTINUE_PORT
        if [[ ! "$CONTINUE_PORT" =~ ^[Yy]$ ]]; then
            error "已取消, 请释放端口 $PORT 后重新运行"
        fi
    fi

    # ---------- 监听地址 (双栈支持) ----------
    echo ""
    if [[ "$STACK_MODE" == "dual" ]]; then
        echo -e "${GREEN}检测到双栈网络 (IPv4: $IPV4 / IPv6: $IPV6)${RESET}"
        echo -e "${CYAN}选择监听模式:${RESET}"
        echo "  1) 双栈监听 - IPv4 + IPv6 (推荐)"
        echo "  2) 仅 IPv4"
        echo "  3) 仅 IPv6"
        read -rp "$(echo -e "${CYAN}请选择 [1/2/3, 默认 1]: ${RESET}")" LISTEN_MODE
        LISTEN_MODE=${LISTEN_MODE:-1}
    elif [[ "$STACK_MODE" == "v6only" ]]; then
        echo -e "${YELLOW}仅检测到 IPv6, 将监听 IPv6${RESET}"
        LISTEN_MODE=3
    else
        echo -e "${YELLOW}仅检测到 IPv4, 将监听 IPv4${RESET}"
        LISTEN_MODE=2
    fi

    case "$LISTEN_MODE" in
        1) LISTEN_ADDR=":$PORT" ;;
        2) LISTEN_ADDR="0.0.0.0:$PORT" ;;
        3) LISTEN_ADDR="[::]:$PORT" ;;
        *) LISTEN_ADDR=":$PORT" ;;
    esac
    info "监听地址: $LISTEN_ADDR"

    # ---------- TLS 方式 ----------
    echo ""
    echo -e "${CYAN}选择 TLS 证书方式:${RESET}"
    echo "  1) ACME 自动申请 (需要域名已解析到本机)"
    echo "  2) 自签证书 (无需域名，适合测试)"
    echo "  3) 自定义证书路径"
    read -rp "$(echo -e "${CYAN}请选择 [1/2/3, 默认 1]: ${RESET}")" TLS_MODE
    TLS_MODE=${TLS_MODE:-1}

    case "$TLS_MODE" in
        1)
            read -rp "$(echo -e "${CYAN}请输入域名: ${RESET}")" DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                error "ACME 模式必须提供域名"
            fi

            # 检查域名 DNS 解析
            info "检查域名 DNS 解析..."
            DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | tail -1 || true)
            DOMAIN_IP6=$(dig +short "$DOMAIN" AAAA 2>/dev/null | tail -1 || true)
            DNS_MATCH=false
            if [[ -n "$IPV4" && "$DOMAIN_IP" == "$IPV4" ]]; then
                info "域名 A 记录 ($DOMAIN_IP) → 匹配本机 IPv4"
                DNS_MATCH=true
            fi
            if [[ -n "$IPV6" && "$DOMAIN_IP6" == "$IPV6" ]]; then
                info "域名 AAAA 记录 ($DOMAIN_IP6) → 匹配本机 IPv6"
                DNS_MATCH=true
            fi
            if [[ "$DNS_MATCH" == false ]]; then
                warn "域名 $DOMAIN 未解析到本机 IP"
                warn "本机 IPv4: ${IPV4:-无}  IPv6: ${IPV6:-无}"
                warn "DNS A: ${DOMAIN_IP:-无}  AAAA: ${DOMAIN_IP6:-无}"
                read -rp "$(echo -e "${YELLOW}DNS 未匹配, ACME 可能失败, 是否继续? [y/N]: ${RESET}")" DNS_CONTINUE
                if [[ ! "$DNS_CONTINUE" =~ ^[Yy]$ ]]; then
                    error "请先将域名解析到本机 IP 后重试"
                fi
            fi

            read -rp "$(echo -e "${CYAN}邮箱 (用于 ACME, 可选): ${RESET}")" EMAIL
            TLS_CONFIG=$(cat <<EOF
acme:
  domains:
    - $DOMAIN
  email: ${EMAIL:-admin@$DOMAIN}
EOF
            )
            SERVER_ADDR="$DOMAIN"
            ;;
        2)
            info "生成自签证书..."
            CERT_DIR="$CONFIG_DIR/certs"
            mkdir -p "$CERT_DIR"
            openssl ecparam -genkey -name prime256v1 -out "$CERT_DIR/key.pem" 2>/dev/null
            openssl req -new -x509 -days 3650 -key "$CERT_DIR/key.pem" \
                -out "$CERT_DIR/cert.pem" -subj "/CN=hysteria-server" 2>/dev/null
            TLS_CONFIG=$(cat <<EOF
tls:
  cert: $CERT_DIR/cert.pem
  key: $CERT_DIR/key.pem
EOF
            )
            SERVER_ADDR=${IPV4:-${IPV6:-YOUR_SERVER_IP}}
            info "自签证书已生成"
            ;;
        3)
            read -rp "$(echo -e "${CYAN}证书文件路径: ${RESET}")" CERT_PATH
            read -rp "$(echo -e "${CYAN}私钥文件路径: ${RESET}")" KEY_PATH
            if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
                error "证书或私钥文件不存在"
            fi
            TLS_CONFIG=$(cat <<EOF
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
EOF
            )
            SERVER_ADDR=${IPV4:-${IPV6:-YOUR_SERVER_IP}}
            ;;
        *)
            error "无效选择"
            ;;
    esac

    # ---------- 认证密码 ----------
    DEFAULT_PWD=$(generate_password)
    read -rp "$(echo -e "${CYAN}认证密码 [默认随机: $DEFAULT_PWD]: ${RESET}")" AUTH_PWD
    AUTH_PWD=${AUTH_PWD:-$DEFAULT_PWD}

    # ---------- 伪装 (中国优化) ----------
    echo ""
    echo -e "${CYAN}伪装网站建议 (应选择中国可正常访问且支持 HTTPS 的网站):${RESET}"
    echo "  1) https://www.microsoft.com  (微软官网, 推荐)"
    echo "  2) https://www.apple.com      (Apple 官网)"
    echo "  3) https://www.samsung.com    (三星官网)"
    echo "  4) 自定义 URL"
    read -rp "$(echo -e "${CYAN}请选择 [1/2/3/4, 默认 1]: ${RESET}")" MASQ_CHOICE
    MASQ_CHOICE=${MASQ_CHOICE:-1}
    case "$MASQ_CHOICE" in
        1) MASQ_URL="https://www.microsoft.com" ;;
        2) MASQ_URL="https://www.apple.com" ;;
        3) MASQ_URL="https://www.samsung.com" ;;
        4) read -rp "$(echo -e "${CYAN}请输入伪装 URL: ${RESET}")" MASQ_URL ;;
        *) MASQ_URL="https://www.microsoft.com" ;;
    esac

    # ---------- 写入配置文件 (中国优化) ----------
    cat > "$CONFIG_FILE" <<EOF
listen: $LISTEN_ADDR

$TLS_CONFIG

auth:
  type: password
  password: $AUTH_PWD

# QUIC 优化 (面向中国高延迟高丢包线路)
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
EOF

    chmod 777 "$CONFIG_FILE"
    info "配置文件已写入: $CONFIG_FILE"
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

# UDP 优化 (Hysteria 2 QUIC 传输)
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

# ============== 防火墙 ==============
configure_firewall() {
    if command -v ufw &>/dev/null; then
        info "配置 UFW 防火墙..."
        ufw allow "$PORT"/tcp  >/dev/null 2>&1 || true
        ufw allow "$PORT"/udp  >/dev/null 2>&1 || true
        ufw reload             >/dev/null 2>&1 || true
    elif command -v iptables &>/dev/null; then
        info "配置 iptables 防火墙..."
        # IPv4 规则
        if [[ "$LISTEN_MODE" != "3" ]]; then
            iptables  -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
            iptables  -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        fi
        # IPv6 规则
        if [[ "$LISTEN_MODE" != "2" ]]; then
            ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        fi
    fi

    case "$LISTEN_MODE" in
        1) info "防火墙已放行端口 $PORT (IPv4+IPv6, TCP+UDP)" ;;
        2) info "防火墙已放行端口 $PORT (IPv4, TCP+UDP)" ;;
        3) info "防火墙已放行端口 $PORT (IPv6, TCP+UDP)" ;;
    esac

    # ACME 需要端口 80 进行 HTTP-01 验证
    if [[ "$TLS_MODE" == "1" && "$PORT" != "80" ]]; then
        info "放行端口 80 (ACME HTTP-01 证书验证所需)..."
        if command -v ufw &>/dev/null; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
        elif command -v iptables &>/dev/null; then
            iptables  -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        fi
    fi
}

# ============== 启动服务 ==============
start_service() {
    info "启用并启动 Hysteria 服务..."
    systemctl enable --now hysteria-server.service || true
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        info "Hysteria 2 服务启动成功!"
    else
        warn "服务可能未成功启动, 请检查日志:"
        echo "  journalctl --no-pager -e -u hysteria-server.service"
    fi
}

# ============== 打印客户端信息 ==============
print_client_info() {
    echo ""
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}  Hysteria 2 安装完成!${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo ""
    echo -e "${CYAN}服务器地址:${RESET} $SERVER_ADDR"
    if [[ -n "$IPV4" ]]; then
        echo -e "${CYAN}IPv4:${RESET}       $IPV4"
    fi
    if [[ -n "$IPV6" ]]; then
        echo -e "${CYAN}IPv6:${RESET}       $IPV6"
    fi
    echo -e "${CYAN}网络栈:${RESET}     ${STACK_MODE:-未知}"
    echo -e "${CYAN}端口:${RESET}       $PORT"
    echo -e "${CYAN}密码:${RESET}       $AUTH_PWD"
    echo -e "${CYAN}协议:${RESET}       hysteria2"
    echo ""

    # 生成分享链接 (IPv4)
    if [[ -n "$IPV4" ]]; then
        if [[ "$TLS_MODE" == "2" ]]; then
            SHARE_LINK_V4="hysteria2://${AUTH_PWD}@${IPV4}:${PORT}?insecure=1#Hysteria2-IPv4"
        else
            SHARE_LINK_V4="hysteria2://${AUTH_PWD}@${SERVER_ADDR}:${PORT}#Hysteria2-IPv4"
        fi
        echo -e "${CYAN}分享链接 (IPv4):${RESET}"
        echo -e "${YELLOW}$SHARE_LINK_V4${RESET}"
    fi

    # 生成分享链接 (IPv6)
    if [[ -n "$IPV6" ]]; then
        if [[ "$TLS_MODE" == "2" ]]; then
            SHARE_LINK_V6="hysteria2://${AUTH_PWD}@[${IPV6}]:${PORT}?insecure=1#Hysteria2-IPv6"
        elif [[ "$TLS_MODE" == "1" ]]; then
            SHARE_LINK_V6="hysteria2://${AUTH_PWD}@${SERVER_ADDR}:${PORT}#Hysteria2-IPv6"
        else
            SHARE_LINK_V6="hysteria2://${AUTH_PWD}@[${IPV6}]:${PORT}#Hysteria2-IPv6"
        fi
        echo -e "${CYAN}分享链接 (IPv6):${RESET}"
        echo -e "${YELLOW}$SHARE_LINK_V6${RESET}"
    fi
    echo ""
    echo -e "${GREEN}--- 中国优化已启用 ---${RESET}"
    echo -e "${CYAN}QUIC:${RESET}       收发窗口 16/32MB, 保活 10s"
    echo -e "${CYAN}内核:${RESET}       BBR + 128MB 缓冲区 + TCP Fast Open"
    echo -e "${CYAN}伪装:${RESET}       $MASQ_URL"
    echo ""
    echo -e "${CYAN}客户端建议 (面向中国):${RESET}"
    echo "  - 推荐使用 sing-box 或 Clash.Meta 客户端"
    echo "  - 客户端可设置 bandwidth 上下行以启用 Brutal 模式加速"
    echo "  - 如遇连接不稳定, 可尝试更换端口 (443/8443/80)"
    echo ""
    echo -e "${CYAN}常用命令:${RESET}"
    echo "  查看状态: systemctl status hysteria-server"
    echo "  重启服务: systemctl restart hysteria-server"
    echo "  查看日志: journalctl --no-pager -e -u hysteria-server.service"
    echo "  编辑配置: nano /etc/hysteria/config.yaml"
    echo "  卸载:     bash <(curl -fsSL https://get.hy2.sh/) --remove"
    echo ""
}

# ============== 查看订阅链接 ==============
show_subscription() {
    CONFIG_FILE="/etc/hysteria/config.yaml"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "未找到配置文件 $CONFIG_FILE, 请先安装 Hysteria 2"
    fi

    info "读取现有配置..."

    # 从配置文件提取信息
    SUB_PORT=$(grep -E '^listen:' "$CONFIG_FILE" | sed 's/listen:\s*//' | grep -oE '[0-9]+' | tail -1)
    SUB_PWD=$(grep -E '^\s+password:' "$CONFIG_FILE" | sed 's/.*password:\s*//' | head -1)
    SUB_MASQ=$(grep -E '^\s+url:' "$CONFIG_FILE" | sed 's/.*url:\s*//' | head -1)

    if [[ -z "$SUB_PORT" || -z "$SUB_PWD" ]]; then
        error "无法从配置文件中解析端口或密码"
    fi

    # 判断 TLS 模式
    if grep -q '^acme:' "$CONFIG_FILE"; then
        SUB_TLS="acme"
        SUB_DOMAIN=$(grep -A2 'domains:' "$CONFIG_FILE" | grep -E '^\s+-' | sed 's/.*-\s*//' | head -1)
    elif grep -q 'cert:.*certs/cert.pem' "$CONFIG_FILE"; then
        SUB_TLS="selfsigned"
    else
        SUB_TLS="custom"
    fi

    # 检测当前 IP
    info "检测 VPS IP 地址..."
    SUB_V4=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || true)
    if [[ -z "$SUB_V4" ]]; then
        SUB_V4=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || true)
    fi
    SUB_V6=$(curl -s6 --max-time 5 ip.sb 2>/dev/null || true)
    if [[ -z "$SUB_V6" ]]; then
        SUB_V6=$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null || true)
    fi

    # 显示信息
    echo ""
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}  Hysteria 2 订阅信息${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo ""
    if [[ -n "$SUB_V4" ]]; then
        echo -e "${CYAN}IPv4:${RESET}       $SUB_V4"
    fi
    if [[ -n "$SUB_V6" ]]; then
        echo -e "${CYAN}IPv6:${RESET}       $SUB_V6"
    fi
    if [[ "$SUB_TLS" == "acme" && -n "$SUB_DOMAIN" ]]; then
        echo -e "${CYAN}域名:${RESET}       $SUB_DOMAIN"
    fi
    echo -e "${CYAN}端口:${RESET}       $SUB_PORT"
    echo -e "${CYAN}密码:${RESET}       $SUB_PWD"
    echo -e "${CYAN}协议:${RESET}       hysteria2"
    echo -e "${CYAN}伪装:${RESET}       ${SUB_MASQ:-无}"
    echo ""

    LINK_V4=""
    LINK_V6=""

    # 生成 IPv4 分享链接
    if [[ -n "$SUB_V4" ]]; then
        if [[ "$SUB_TLS" == "selfsigned" ]]; then
            LINK_V4="hysteria2://${SUB_PWD}@${SUB_V4}:${SUB_PORT}?insecure=1#Hysteria2-IPv4"
        elif [[ "$SUB_TLS" == "acme" && -n "$SUB_DOMAIN" ]]; then
            LINK_V4="hysteria2://${SUB_PWD}@${SUB_DOMAIN}:${SUB_PORT}#Hysteria2-IPv4"
        else
            LINK_V4="hysteria2://${SUB_PWD}@${SUB_V4}:${SUB_PORT}#Hysteria2-IPv4"
        fi
        echo -e "${CYAN}分享链接 (IPv4):${RESET}"
        echo -e "${YELLOW}$LINK_V4${RESET}"
        echo ""
    fi

    # 生成 IPv6 分享链接
    if [[ -n "$SUB_V6" ]]; then
        if [[ "$SUB_TLS" == "selfsigned" ]]; then
            LINK_V6="hysteria2://${SUB_PWD}@[${SUB_V6}]:${SUB_PORT}?insecure=1#Hysteria2-IPv6"
        elif [[ "$SUB_TLS" == "acme" && -n "$SUB_DOMAIN" ]]; then
            LINK_V6="hysteria2://${SUB_PWD}@${SUB_DOMAIN}:${SUB_PORT}#Hysteria2-IPv6"
        else
            LINK_V6="hysteria2://${SUB_PWD}@[${SUB_V6}]:${SUB_PORT}#Hysteria2-IPv6"
        fi
        echo -e "${CYAN}分享链接 (IPv6):${RESET}"
        echo -e "${YELLOW}$LINK_V6${RESET}"
        echo ""
    fi

    if [[ -z "$SUB_V4" && -z "$SUB_V6" ]]; then
        warn "未检测到公网 IP, 无法生成分享链接"
    fi

    echo ""

    # 服务状态
    echo -e "${CYAN}服务状态:${RESET}"
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
        echo -e "  ${GREEN}● 运行中${RESET}"
    else
        echo -e "  ${RED}● 未运行${RESET}"
    fi
    echo -e "${CYAN}Hysteria 版本:${RESET} $(hysteria version 2>/dev/null || echo '未知')"
    echo ""
}

# ============== 更新 Hysteria 2 ==============
update_hysteria() {
    info "更新 Hysteria 2 到最新版本..."
    bash <(curl -fsSL https://get.hy2.sh/)
    info "Hysteria 2 当前版本: $(hysteria version 2>/dev/null || echo '未知')"
    info "重启 Hysteria 服务以应用新版本..."
    systemctl restart hysteria-server.service 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        info "Hysteria 2 更新并重启成功!"
    else
        warn "服务重启可能失败, 请检查日志:"
        echo "  journalctl --no-pager -e -u hysteria-server.service"
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

# ============== 卸载 ==============
uninstall_all() {
    echo ""
    echo -e "${YELLOW}══════════ 卸载确认 ══════════${RESET}"
    read -rp "$(echo -e "${RED}确认卸载 Hysteria 2 并清理配置? [y/N]: ${RESET}")" CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "已取消卸载"
        return
    fi

    # 停止并禁用服务
    info "停止 Hysteria 服务..."
    systemctl stop hysteria-server.service    2>/dev/null || true
    systemctl disable hysteria-server.service 2>/dev/null || true

    # 调用官方卸载脚本
    info "调用官方卸载脚本..."
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true

    # 清理配置文件
    read -rp "$(echo -e "${CYAN}是否删除配置文件 /etc/hysteria/ ? [y/N]: ${RESET}")" DEL_CONF
    if [[ "$DEL_CONF" =~ ^[Yy]$ ]]; then
        rm -rf /etc/hysteria/
        info "配置文件已删除"
    else
        info "保留配置文件: /etc/hysteria/"
    fi

    # 可选: 清理 BBR 参数
    read -rp "$(echo -e "${CYAN}是否清理 BBR 及网络优化参数? [y/N]: ${RESET}")" DEL_BBR
    if [[ "$DEL_BBR" =~ ^[Yy]$ ]]; then
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
    fi

    echo ""
    info "Hysteria 2 卸载完成!"
    echo ""
}

# ============== 主流程 ==============
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}║  Hysteria 2 一键安装脚本 (Debian 13) ║${RESET}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${RESET}"
    echo ""

    check_root
    check_os

    echo -e "${CYAN}请选择操作:${RESET}"
    echo "  1) 全新安装 Hysteria 2 + BBR"
    echo "  2) 更新 Hysteria 2 到最新版本"
    echo "  3) 更新系统内核 (BBR 最新版)"
    echo "  4) 同时更新 Hysteria 2 + 内核 BBR"
    echo "  5) 查看订阅链接 (IPv4 + IPv6)"
    echo "  6) 卸载 Hysteria 2"
    read -rp "$(echo -e "${CYAN}请选择 [1/2/3/4/5/6, 默认 1]: ${RESET}")" ACTION
    ACTION=${ACTION:-1}

    case "$ACTION" in
        1)
            check_arch
            detect_ip
            install_deps
            install_hysteria
            configure_hysteria
            enable_bbr
            configure_firewall
            start_service
            print_client_info
            ;;
        2)
            update_hysteria
            ;;
        3)
            update_kernel_bbr
            ;;
        4)
            update_hysteria
            update_kernel_bbr
            ;;
        5)
            show_subscription
            ;;
        6)
            uninstall_all
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

main "$@"
