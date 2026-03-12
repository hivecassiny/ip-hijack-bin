#!/bin/bash
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

VERSION="1.0.0"
BUILD="2026-03-12.9"

BASE_URL="https://raw.githubusercontent.com/${REPO}/main/bin/v${VERSION}"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║        IP Hijack Agent Installer         ║"
    echo "  ║               v${VERSION}                    ║"
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
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url" || { error "Download failed"; exit 1; }
    elif command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "$dest" "$url" || { error "Download failed"; exit 1; }
    else
        error "Neither curl nor wget found. Please install one."
        exit 1
    fi
    chmod +x "$dest"
    info "Installed to ${dest}"
}

# ─── Install Agent ────────────────────────────────────────────────
install_agent() {
    step "Installing Agent (${PLATFORM})"

    local url="${BASE_URL}/agent-${PLATFORM}"
    download_bin "agent-${PLATFORM}" "$url" "${INSTALL_DIR}/${AGENT_BIN}"

    mkdir -p "$DATA_DIR"

    echo ""
    prompt "Server address (e.g. 1.2.3.4:9000): "
    read -r SERVER_ADDR < /dev/tty
    if [ -z "$SERVER_ADDR" ]; then
        error "Server address is required"
        exit 1
    fi

    prompt "Username [admin]: "
    read -r AGENT_USER < /dev/tty
    AGENT_USER="${AGENT_USER:-admin}"

    prompt "Enable compression? [Y/n]: "
    read -r COMP < /dev/tty
    COMP="${COMP:-Y}"
    local compress_flag="-compress=true"
    if [[ "$COMP" =~ ^[nN] ]]; then
        compress_flag="-compress=false"
    fi

    if [ "$DETECTED_OS" = "linux" ] && command -v systemctl &>/dev/null; then
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
        if systemctl is-active ip-hijack-agent &>/dev/null; then
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

    if [ "$DETECTED_OS" = "linux" ] && command -v systemctl &>/dev/null; then
        if systemctl is-active ip-hijack-agent &>/dev/null; then
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
    if [[ "$RM_DATA" =~ ^[yY] ]]; then
        rm -rf "$DATA_DIR"
        info "Removed ${DATA_DIR}"
    else
        warn "Data preserved in ${DATA_DIR}"
    fi

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
    if [ "$DETECTED_OS" = "linux" ] && systemctl is-active ip-hijack-agent &>/dev/null; then
        was_running=true
        step "Stopping agent..."
        systemctl stop ip-hijack-agent
    fi

    mv -f "$tmp_bin" "${INSTALL_DIR}/${AGENT_BIN}"
    chmod +x "${INSTALL_DIR}/${AGENT_BIN}"
    info "Binary replaced"

    if [ "$was_running" = true ]; then
        systemctl start ip-hijack-agent
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

    if [ "$DETECTED_OS" = "linux" ] && command -v systemctl &>/dev/null; then
        echo ""
        if systemctl is-active ip-hijack-agent &>/dev/null; then
            echo -e "  ip-hijack-agent: ${GREEN}running${RESET}"
        elif [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then
            echo -e "  ip-hijack-agent: ${YELLOW}stopped${RESET}"
        else
            echo -e "  ip-hijack-agent: ${DIM}not configured${RESET}"
        fi
    fi

    echo ""
    echo -e "  Platform: ${BOLD}${PLATFORM}${RESET}"

    if [ -f "${DATA_DIR}/uuid" ]; then
        echo -e "  Agent UUID: $(cat ${DATA_DIR}/uuid)"
    fi
}

# ─── Service Control ──────────────────────────────────────────────
svc_start() {
    if ! command -v systemctl &>/dev/null; then error "systemd not available"; exit 1; fi
    if ! [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then error "Service not installed"; exit 1; fi
    systemctl start ip-hijack-agent && info "ip-hijack-agent started" || error "Failed to start"
}

svc_stop() {
    if ! command -v systemctl &>/dev/null; then error "systemd not available"; exit 1; fi
    systemctl stop ip-hijack-agent && info "ip-hijack-agent stopped" || error "Failed to stop"
}

svc_restart() {
    if ! command -v systemctl &>/dev/null; then error "systemd not available"; exit 1; fi
    if ! [ -f "${SERVICE_DIR}/ip-hijack-agent.service" ]; then error "Service not installed"; exit 1; fi
    systemctl restart ip-hijack-agent && info "ip-hijack-agent restarted" || error "Failed to restart"
}

svc_logs() {
    if ! command -v journalctl &>/dev/null; then error "journalctl not available"; exit 1; fi
    journalctl -u ip-hijack-agent -f --no-pager -n 50
}

# ─── Main Menu ────────────────────────────────────────────────────
main_menu() {
    print_banner
    detect_arch
    info "Detected platform: ${BOLD}${PLATFORM}${RESET}"
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
    start)      check_root; svc_start ;;
    stop)       check_root; svc_stop ;;
    restart)    check_root; svc_restart ;;
    logs)       svc_logs ;;
    status)     detect_arch; show_status ;;
    *)          main_menu ;;
esac
