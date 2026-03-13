#!/bin/sh
#
# IP Hijack Agent — Interactive Installer
# https://github.com/hivecassiny/ip-hijack-bin
#
set -e

REPO="hivecassiny/ip-hijack-bin"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
AGENT_BIN="ip-hijack-agent"
DATA_DIR="/var/lib/ip-hijack"

VERSION="1.0.3"
BUILD="2026-03-13"

BASE_URL="https://raw.githubusercontent.com/${REPO}/main/bin/v${VERSION}"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

IS_OPENWRT=false

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║        IP Hijack Agent Installer         ║"
    echo "  ║               v${VERSION}                      ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${DIM}build ${BUILD}${RESET}"
}

info()    { echo -e "  ${GREEN}[✓]${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${RESET} $1"; }
error()   { echo -e "  ${RED}[✗]${RESET} $1"; }
step()    { echo -e "\n  ${CYAN}${BOLD}▸ $1${RESET}"; }
prompt()  { echo -en "  ${BOLD}$1${RESET}"; }

# ─── Detect Architecture ─────────────────────────────────────────
detect_arch() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$arch" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)   arch="arm64" ;;
        armv7l|armhf)    arch="arm"   ;;
        mips)            arch="mips"  ;;
        mipsel|mipsle)   arch="mipsle";;
        *)               error "Unsupported architecture: $arch"; exit 1 ;;
    esac

    case "$os" in
        linux)  ;;
        darwin) ;;
        *)      error "Unsupported OS: $os"; exit 1 ;;
    esac

    DETECTED_OS="$os"
    DETECTED_ARCH="$arch"
    PLATFORM="${os}-${arch}"

    # Detect OpenWrt
    if [ -f /etc/openwrt_release ]; then
        IS_OPENWRT=true
    fi
}

# ─── Check Root ───────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# ─── Download Binary ─────────────────────────────────────────────
download_bin() {
    local name="$1" url="$2" dest="$3"
    step "Downloading ${name}..."
    if command -v wget >/dev/null 2>&1; then
        # BusyBox wget (OpenWrt) does not support --show-progress
        if wget --help 2>&1 | grep -q 'show-progress'; then
            wget -q --show-progress -O "$dest" "$url" || { error "Download failed"; exit 1; }
        else
            wget -O "$dest" "$url" || { error "Download failed"; exit 1; }
        fi
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$dest" "$url" || { error "Download failed"; exit 1; }
    else
        error "Neither curl nor wget found. Please install one."
        exit 1
    fi
    chmod +x "$dest"
    info "Installed to ${dest}"
}

# ─── Check & Install Dependencies ─────────────────────────────────
setup_dependencies() {
    if [ "$DETECTED_OS" != "linux" ]; then
        warn "Dependency check skipped (non-Linux)"
        return
    fi

    step "Checking dependencies..."

    # Detect package manager
    local PKG=""
    if command -v apt-get >/dev/null 2>&1; then
        PKG="apt"
    elif command -v yum >/dev/null 2>&1; then
        PKG="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PKG="dnf"
    elif command -v opkg >/dev/null 2>&1; then
        PKG="opkg"
    elif command -v apk >/dev/null 2>&1; then
        PKG="apk"
    fi

    # 1) iptables
    if command -v iptables >/dev/null 2>&1; then
        info "iptables: $(iptables -V 2>/dev/null || echo 'installed')"
    else
        warn "iptables not found, installing..."
        case "$PKG" in
            apt)  apt-get update -qq && apt-get install -y -qq iptables ;;
            yum)  yum install -y iptables ;;
            dnf)  dnf install -y iptables ;;
            opkg) opkg update && opkg install iptables ;;
            apk)  apk add iptables ;;
            *)    error "Cannot auto-install iptables. Please install it manually."; return ;;
        esac
        if command -v iptables >/dev/null 2>&1; then
            info "iptables installed"
        else
            error "iptables installation failed. Please install manually."
        fi
    fi

    # 2) conntrack
    if command -v conntrack >/dev/null 2>&1; then
        info "conntrack: installed"
    else
        warn "conntrack not found, installing..."
        case "$PKG" in
            apt)  apt-get install -y -qq conntrack ;;
            yum)  yum install -y conntrack-tools ;;
            dnf)  dnf install -y conntrack-tools ;;
            opkg) opkg install conntrack ;;
            apk)  apk add conntrack-tools ;;
            *)    warn "Cannot auto-install conntrack. Connection tracking may be limited." ;;
        esac
        if command -v conntrack >/dev/null 2>&1; then
            info "conntrack installed"
        else
            warn "conntrack not available. Agent will fall back to netstat for connection listing."
        fi
    fi

    # 3) ip_forward
    local fwd
    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$fwd" = "1" ]; then
        info "ip_forward: enabled"
    else
        warn "ip_forward is disabled, enabling..."
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1 || true
        fi
        fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
        if [ "$fwd" = "1" ]; then
            info "ip_forward enabled (persistent)"
        else
            error "Failed to enable ip_forward. Please run: echo 1 > /proc/sys/net/ipv4/ip_forward"
        fi
    fi

    echo ""
}

# ─── Install Agent ────────────────────────────────────────────────
install_agent() {
    step "Installing Agent (${PLATFORM})"
    setup_dependencies

    mkdir -p "$INSTALL_DIR"
    local url="${BASE_URL}/agent-${PLATFORM}"
    download_bin "agent-${PLATFORM}" "$url" "${INSTALL_DIR}/${AGENT_BIN}"

    mkdir -p "$DATA_DIR"

    echo ""
    local DEFAULT_SERVER="ipagent.hivempos.com:9000"
    echo -e "  ${DIM}Press Enter to use default: ${DEFAULT_SERVER}${RESET}"
    prompt "Server address [${DEFAULT_SERVER}]: "
    read -r SERVER_ADDR < /dev/tty
    SERVER_ADDR="${SERVER_ADDR:-$DEFAULT_SERVER}"
    info "Server: ${SERVER_ADDR}"

    echo -e "  ${DIM}Display label shown in dashboard (not a login account)${RESET}"
    prompt "Username [admin]: "
    read -r AGENT_USER < /dev/tty
    AGENT_USER="${AGENT_USER:-admin}"

    prompt "Enable compression? [Y/n]: "
    read -r COMP < /dev/tty
    COMP="${COMP:-Y}"
    local compress_flag="-compress=true"
    case "$COMP" in
        [nN]*) compress_flag="-compress=false" ;;
    esac

    if [ "$IS_OPENWRT" = true ]; then
        # ── OpenWrt: create procd init.d service ──
        step "Creating OpenWrt procd service..."
        cat > "/etc/init.d/ip-hijack-agent" <<INITD
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=01

start_service() {
    procd_open_instance
    procd_set_param command ${INSTALL_DIR}/${AGENT_BIN} -server ${SERVER_ADDR} -user ${AGENT_USER} ${compress_flag}
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITD
        chmod +x /etc/init.d/ip-hijack-agent
        /etc/init.d/ip-hijack-agent enable
        /etc/init.d/ip-hijack-agent start || true
        sleep 1
        info "Service created and enabled on boot"
        echo ""
        echo -e "  ${DIM}Manage with:${RESET}"
        echo -e "    /etc/init.d/ip-hijack-agent start"
        echo -e "    /etc/init.d/ip-hijack-agent stop"
        echo -e "    /etc/init.d/ip-hijack-agent restart"
        echo -e "    logread -e ip-hijack"

    elif [ "$DETECTED_OS" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
        # ── systemd service ──
        step "Creating systemd service..."
        cat > "${SERVICE_DIR}/ip-hijack-agent.service" <<UNIT
[Unit]
Description=IP Hijack Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${AGENT_BIN} -server ${SERVER_ADDR} -user ${AGENT_USER} ${compress_flag}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

        systemctl daemon-reload
        systemctl enable ip-hijack-agent
        systemctl start ip-hijack-agent || true
        sleep 1
        if systemctl is-active ip-hijack-agent >/dev/null 2>&1; then
            info "Service created and started"
        else
            warn "Service created but failed to start. Recent logs:"
            echo ""
            journalctl -u ip-hijack-agent --no-pager -n 10 2>/dev/null || systemctl status ip-hijack-agent --no-pager 2>/dev/null || true
        fi
        echo ""
        echo -e "  ${DIM}Manage with:${RESET}"
        echo -e "    systemctl status  ip-hijack-agent"
        echo -e "    systemctl restart ip-hijack-agent"
        echo -e "    journalctl -u ip-hijack-agent -f"
    else
        echo ""
        info "Run manually:"
        echo -e "    ${AGENT_BIN} -server ${SERVER_ADDR} -user ${AGENT_USER} ${compress_flag}"
    fi
}

# ─── Uninstall ────────────────────────────────────────────────────
uninstall() {
    step "Uninstalling IP Hijack Agent..."

    if [ "$IS_OPENWRT" = true ]; then
        # ── OpenWrt: stop and remove init.d service ──
        if [ -f /etc/init.d/ip-hijack-agent ]; then
            /etc/init.d/ip-hijack-agent stop 2>/dev/null || true
            /etc/init.d/ip-hijack-agent disable 2>/dev/null || true
            rm -f /etc/init.d/ip-hijack-agent
            info "Stopped and removed OpenWrt service"
        fi
    elif [ "$DETECTED_OS" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
        # ── systemd ──
        if systemctl is-active ip-hijack-agent >/dev/null 2>&1; then
            systemctl stop ip-hijack-agent
            info "Stopped ip-hijack-agent"
        fi
        if [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then
            systemctl disable ip-hijack-agent 2>/dev/null || true
            rm -f "${SERVICE_DIR}/ip-hijack-agent.service"
            info "Removed ip-hijack-agent service"
        fi
        systemctl daemon-reload
    fi

    if [ -f "${INSTALL_DIR}/${AGENT_BIN}" ]; then
        rm -f "${INSTALL_DIR}/${AGENT_BIN}"
        info "Removed ${INSTALL_DIR}/${AGENT_BIN}"
    fi

    echo ""
    prompt "Also remove data (UUID) in ${DATA_DIR}? [y/N]: "
    read -r RM_DATA < /dev/tty
    case "$RM_DATA" in
        [yY]*) rm -rf "$DATA_DIR"; info "Removed ${DATA_DIR}" ;;
        *)     warn "Data preserved in ${DATA_DIR}" ;;
    esac

    info "Uninstall complete"
}

# ─── Update ───────────────────────────────────────────────────────
update() {
    step "Updating Agent..."

    if [ ! -f "${INSTALL_DIR}/${AGENT_BIN}" ]; then
        warn "Agent is not installed. Run install first."
        return
    fi

    local tmp_bin="${INSTALL_DIR}/${AGENT_BIN}.new"
    download_bin "agent-${PLATFORM}" "${BASE_URL}/agent-${PLATFORM}" "$tmp_bin"

    local was_running=false
    if [ "$IS_OPENWRT" = true ]; then
        if [ -f /etc/init.d/ip-hijack-agent ]; then
            /etc/init.d/ip-hijack-agent stop 2>/dev/null && was_running=true || true
        fi
    elif [ "$DETECTED_OS" = "linux" ] && systemctl is-active ip-hijack-agent >/dev/null 2>&1; then
        was_running=true
        step "Stopping agent..."
        systemctl stop ip-hijack-agent
    fi

    mv -f "$tmp_bin" "${INSTALL_DIR}/${AGENT_BIN}"
    chmod +x "${INSTALL_DIR}/${AGENT_BIN}"
    info "Binary replaced"

    if [ "$was_running" = true ]; then
        if [ "$IS_OPENWRT" = true ]; then
            /etc/init.d/ip-hijack-agent start
        else
            systemctl start ip-hijack-agent
        fi
        info "Agent restarted"
    fi
}

# ─── Status ───────────────────────────────────────────────────────
show_status() {
    step "Agent Status"
    echo ""

    if [ -f "${INSTALL_DIR}/${AGENT_BIN}" ]; then
        echo -e "  Agent binary:  ${GREEN}installed${RESET}  (${INSTALL_DIR}/${AGENT_BIN})"
    else
        echo -e "  Agent binary:  ${DIM}not installed${RESET}"
    fi

    if [ "$IS_OPENWRT" = true ]; then
        echo ""
        if [ -f /etc/init.d/ip-hijack-agent ]; then
            if /etc/init.d/ip-hijack-agent status >/dev/null 2>&1; then
                echo -e "  ip-hijack-agent: ${GREEN}running${RESET}"
            else
                echo -e "  ip-hijack-agent: ${YELLOW}stopped${RESET}"
            fi
        else
            echo -e "  ip-hijack-agent: ${DIM}not configured${RESET}"
        fi
    elif [ "$DETECTED_OS" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
        echo ""
        if systemctl is-active ip-hijack-agent >/dev/null 2>&1; then
            echo -e "  ip-hijack-agent: ${GREEN}running${RESET}"
        elif [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then
            echo -e "  ip-hijack-agent: ${YELLOW}stopped${RESET}"
        else
            echo -e "  ip-hijack-agent: ${DIM}not configured${RESET}"
        fi
    fi

    echo ""
    echo -e "  Platform: ${BOLD}${PLATFORM}${RESET}"
    if [ "$IS_OPENWRT" = true ]; then
        echo -e "  System:   ${BOLD}OpenWrt${RESET}"
    fi

    if [ -f "${DATA_DIR}/uuid" ]; then
        echo -e "  Agent UUID: $(cat ${DATA_DIR}/uuid)"
    fi
}

# ─── Service Control ──────────────────────────────────────────────
svc_start() {
    if [ "$IS_OPENWRT" = true ]; then
        if [ ! -f /etc/init.d/ip-hijack-agent ]; then error "Service not installed"; exit 1; fi
        /etc/init.d/ip-hijack-agent start && info "ip-hijack-agent started" || error "Failed to start"
    else
        if ! command -v systemctl >/dev/null 2>&1; then error "systemd not available"; exit 1; fi
        if ! [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then error "Service not installed"; exit 1; fi
        systemctl start ip-hijack-agent && info "ip-hijack-agent started" || error "Failed to start"
    fi
}

svc_stop() {
    if [ "$IS_OPENWRT" = true ]; then
        if [ ! -f /etc/init.d/ip-hijack-agent ]; then error "Service not installed"; exit 1; fi
        /etc/init.d/ip-hijack-agent stop && info "ip-hijack-agent stopped" || error "Failed to stop"
    else
        if ! command -v systemctl >/dev/null 2>&1; then error "systemd not available"; exit 1; fi
        systemctl stop ip-hijack-agent && info "ip-hijack-agent stopped" || error "Failed to stop"
    fi
}

svc_restart() {
    if [ "$IS_OPENWRT" = true ]; then
        if [ ! -f /etc/init.d/ip-hijack-agent ]; then error "Service not installed"; exit 1; fi
        /etc/init.d/ip-hijack-agent restart && info "ip-hijack-agent restarted" || error "Failed to restart"
    else
        if ! command -v systemctl >/dev/null 2>&1; then error "systemd not available"; exit 1; fi
        if ! [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then error "Service not installed"; exit 1; fi
        systemctl restart ip-hijack-agent && info "ip-hijack-agent restarted" || error "Failed to restart"
    fi
}

svc_logs() {
    if [ "$IS_OPENWRT" = true ]; then
        if command -v logread >/dev/null 2>&1; then
            logread -f -e ip-hijack
        else
            error "logread not available"; exit 1
        fi
    else
        if ! command -v journalctl >/dev/null 2>&1; then error "journalctl not available"; exit 1; fi
        journalctl -u ip-hijack-agent -f --no-pager -n 50
    fi
}

# ─── Main Menu ────────────────────────────────────────────────────
main_menu() {
    print_banner
    detect_arch
    info "Detected platform: ${BOLD}${PLATFORM}${RESET}"
    if [ "$IS_OPENWRT" = true ]; then
        info "Detected system:   ${BOLD}OpenWrt${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}Select an option:${RESET}"
    echo ""
    echo -e "    ${CYAN}1)${RESET}  Install Agent"
    echo -e "    ${CYAN}2)${RESET}  Update Agent"
    echo -e "    ${CYAN}3)${RESET}  Uninstall Agent"
    echo -e "    ${DIM}────────────────────${RESET}"
    echo -e "    ${CYAN}4)${RESET}  Start Agent"
    echo -e "    ${CYAN}5)${RESET}  Stop Agent"
    echo -e "    ${CYAN}6)${RESET}  Restart Agent"
    echo -e "    ${CYAN}7)${RESET}  View Logs"
    echo -e "    ${DIM}────────────────────${RESET}"
    echo -e "    ${CYAN}8)${RESET}  Show Status"
    echo -e "    ${CYAN}0)${RESET}  Exit"
    echo ""
    prompt "Enter choice [0-8]: "
    read -r choice < /dev/tty

    case "$choice" in
        1) check_root; install_agent ;;
        2) check_root; update ;;
        3) check_root; uninstall ;;
        4) check_root; svc_start ;;
        5) check_root; svc_stop ;;
        6) check_root; svc_restart ;;
        7) svc_logs ;;
        8) show_status ;;
        0) echo "  Bye."; exit 0 ;;
        *) error "Invalid choice"; exit 1 ;;
    esac

    echo ""
    info "Done!"
    echo ""
}

case "${1:-}" in
    install)    check_root; detect_arch; install_agent ;;
    update)     check_root; detect_arch; update ;;
    uninstall)  check_root; detect_arch; uninstall ;;
    start)      detect_arch; check_root; svc_start ;;
    stop)       detect_arch; check_root; svc_stop ;;
    restart)    detect_arch; check_root; svc_restart ;;
    logs)       detect_arch; svc_logs ;;
    status)     detect_arch; show_status ;;
    *)          main_menu ;;
esac
