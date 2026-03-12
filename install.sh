#!/bin/bash
#
# IP Hijack Agent/Server — Interactive Installer
# https://github.com/hivecassiny/ip-hijack-bin
#
set -e

REPO="hivecassiny/ip-hijack-bin"
BASE_URL="https://raw.githubusercontent.com/${REPO}/main/bin"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
AGENT_BIN="ip-hijack-agent"
SERVER_BIN="ip-hijack-server"
DATA_DIR="/var/lib/ip-hijack"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       IP Hijack Manager Installer        ║"
    echo "  ║                  v1.0.0                   ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
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
    read -r SERVER_ADDR
    if [ -z "$SERVER_ADDR" ]; then
        error "Server address is required"
        exit 1
    fi

    prompt "Username [admin]: "
    read -r AGENT_USER
    AGENT_USER="${AGENT_USER:-admin}"

    prompt "Enable compression? [Y/n]: "
    read -r COMP
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
        systemctl start ip-hijack-agent
        info "Service created and started"
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

# ─── Install Server ───────────────────────────────────────────────
install_server() {
    step "Installing Server (${PLATFORM})"

    if [ "$DETECTED_ARCH" = "mips" ] || [ "$DETECTED_ARCH" = "mipsle" ]; then
        error "Server binary is not available for ${PLATFORM} (SQLite limitation)"
        exit 1
    fi

    local url="${BASE_URL}/server-${PLATFORM}"
    download_bin "server-${PLATFORM}" "$url" "${INSTALL_DIR}/${SERVER_BIN}"

    prompt "TCP listen address [:9000]: "
    read -r TCP_ADDR
    TCP_ADDR="${TCP_ADDR:-:9000}"

    prompt "HTTP listen address [:8080]: "
    read -r HTTP_ADDR
    HTTP_ADDR="${HTTP_ADDR:-:8080}"

    prompt "Admin password [admin]: "
    read -r ADMIN_PASS
    ADMIN_PASS="${ADMIN_PASS:-admin}"

    prompt "Database path [/var/lib/ip-hijack/hijack.db]: "
    read -r DB_PATH
    DB_PATH="${DB_PATH:-/var/lib/ip-hijack/hijack.db}"

    mkdir -p "$(dirname "$DB_PATH")"

    if [ "$DETECTED_OS" = "linux" ] && command -v systemctl &>/dev/null; then
        step "Creating systemd service..."
        cat > "${SERVICE_DIR}/ip-hijack-server.service" <<UNIT
[Unit]
Description=IP Hijack Management Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${SERVER_BIN} -tcp ${TCP_ADDR} -http ${HTTP_ADDR} -db ${DB_PATH} -admin-pass ${ADMIN_PASS}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

        systemctl daemon-reload
        systemctl enable ip-hijack-server
        systemctl start ip-hijack-server
        info "Service created and started"
        echo ""
        echo -e "  ${DIM}Web UI:${RESET} http://<server-ip>${HTTP_ADDR}"
        echo -e "  ${DIM}Manage with:${RESET}"
        echo -e "    systemctl status  ip-hijack-server"
        echo -e "    systemctl restart ip-hijack-server"
        echo -e "    journalctl -u ip-hijack-server -f"
    else
        echo ""
        info "Run manually:"
        echo -e "    ${SERVER_BIN} -tcp ${TCP_ADDR} -http ${HTTP_ADDR} -db ${DB_PATH} -admin-pass ${ADMIN_PASS}"
    fi
}

# ─── Uninstall ────────────────────────────────────────────────────
uninstall() {
    step "Uninstalling IP Hijack..."

    if [ "$DETECTED_OS" = "linux" ] && command -v systemctl &>/dev/null; then
        for svc in ip-hijack-agent ip-hijack-server; do
            if systemctl is-active "$svc" &>/dev/null; then
                systemctl stop "$svc"
                info "Stopped ${svc}"
            fi
            if [ -f "${SERVICE_DIR}/${svc}.service" ]; then
                systemctl disable "$svc" 2>/dev/null || true
                rm -f "${SERVICE_DIR}/${svc}.service"
                info "Removed ${svc} service"
            fi
        done
        systemctl daemon-reload
    fi

    for f in "${INSTALL_DIR}/${AGENT_BIN}" "${INSTALL_DIR}/${SERVER_BIN}"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            info "Removed ${f}"
        fi
    done

    echo ""
    prompt "Also remove data (UUID, database) in ${DATA_DIR}? [y/N]: "
    read -r RM_DATA
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
    step "Updating binaries..."

    local updated=0
    if [ -f "${INSTALL_DIR}/${AGENT_BIN}" ]; then
        download_bin "agent-${PLATFORM}" "${BASE_URL}/agent-${PLATFORM}" "${INSTALL_DIR}/${AGENT_BIN}"
        if [ "$DETECTED_OS" = "linux" ] && systemctl is-active ip-hijack-agent &>/dev/null; then
            systemctl restart ip-hijack-agent
            info "Restarted ip-hijack-agent"
        fi
        updated=1
    fi

    if [ -f "${INSTALL_DIR}/${SERVER_BIN}" ]; then
        download_bin "server-${PLATFORM}" "${BASE_URL}/server-${PLATFORM}" "${INSTALL_DIR}/${SERVER_BIN}"
        if [ "$DETECTED_OS" = "linux" ] && systemctl is-active ip-hijack-server &>/dev/null; then
            systemctl restart ip-hijack-server
            info "Restarted ip-hijack-server"
        fi
        updated=1
    fi

    if [ "$updated" -eq 0 ]; then
        warn "No installed components found. Run install first."
    fi
}

# ─── Status ───────────────────────────────────────────────────────
show_status() {
    step "Component Status"
    echo ""

    if [ -f "${INSTALL_DIR}/${AGENT_BIN}" ]; then
        echo -e "  Agent binary:  ${GREEN}installed${RESET}  (${INSTALL_DIR}/${AGENT_BIN})"
    else
        echo -e "  Agent binary:  ${DIM}not installed${RESET}"
    fi

    if [ -f "${INSTALL_DIR}/${SERVER_BIN}" ]; then
        echo -e "  Server binary: ${GREEN}installed${RESET}  (${INSTALL_DIR}/${SERVER_BIN})"
    else
        echo -e "  Server binary: ${DIM}not installed${RESET}"
    fi

    if [ "$DETECTED_OS" = "linux" ] && command -v systemctl &>/dev/null; then
        echo ""
        for svc in ip-hijack-agent ip-hijack-server; do
            if systemctl is-active "$svc" &>/dev/null; then
                echo -e "  ${svc}: ${GREEN}running${RESET}"
            elif [ -f "${SERVICE_DIR}/${svc}.service" ]; then
                echo -e "  ${svc}: ${YELLOW}stopped${RESET}"
            else
                echo -e "  ${svc}: ${DIM}not configured${RESET}"
            fi
        done
    fi

    echo ""
    echo -e "  Platform: ${BOLD}${PLATFORM}${RESET}"

    if [ -f "${DATA_DIR}/uuid" ]; then
        echo -e "  Agent UUID: $(cat ${DATA_DIR}/uuid)"
    fi
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
    echo -e "    ${CYAN}2)${RESET}  Install Server"
    echo -e "    ${CYAN}3)${RESET}  Install Both (Agent + Server)"
    echo -e "    ${CYAN}4)${RESET}  Update installed components"
    echo -e "    ${CYAN}5)${RESET}  Uninstall"
    echo -e "    ${CYAN}6)${RESET}  Show Status"
    echo -e "    ${CYAN}0)${RESET}  Exit"
    echo ""
    prompt "Enter choice [1-6, 0]: "
    read -r choice

    case "$choice" in
        1) check_root; install_agent ;;
        2) check_root; install_server ;;
        3) check_root; install_agent; install_server ;;
        4) check_root; update ;;
        5) check_root; uninstall ;;
        6) show_status ;;
        0) echo "  Bye."; exit 0 ;;
        *) error "Invalid choice"; exit 1 ;;
    esac

    echo ""
    info "Done!"
    echo ""
}

# Allow direct actions: ./install.sh install-agent, ./install.sh uninstall, etc.
case "${1:-}" in
    install-agent)  check_root; detect_arch; install_agent ;;
    install-server) check_root; detect_arch; install_server ;;
    update)         check_root; detect_arch; update ;;
    uninstall)      check_root; detect_arch; uninstall ;;
    status)         detect_arch; show_status ;;
    *)              main_menu ;;
esac
