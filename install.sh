#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Shadowsocks-Rust 2022 Installer
# by CGQAQ
# ==============================================================================

# --- Global Constants ---------------------------------------------------------
SS_RUST_REPO="shadowsocks/shadowsocks-rust"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="shadowsocks-rust-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BINARY_NAMES=("ssserver" "sslocal" "ssmanager" "ssurl" "ssservice")
DEFAULT_PORT=8388
DEFAULT_CIPHER="2022-blake3-aes-256-gcm"
TEMP_DIR=""

# --- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Utility Functions --------------------------------------------------------

msg_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
msg_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
msg_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
msg_success() { echo -e "${GREEN}[OK]${NC} $*"; }
msg_step()    { echo -e "\n${BOLD}${CYAN}$*${NC}"; }

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "This script must be run as root. Try: sudo bash $0"
        exit 1
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

confirm() {
    local prompt="${1}" default="${2:-Y}"
    local yn
    if [[ "${default}" == "Y" ]]; then
        read -r -p "$(echo -e "${prompt} ${BOLD}[Y/n]${NC} > ")" yn
        yn="${yn:-Y}"
    else
        read -r -p "$(echo -e "${prompt} ${BOLD}[y/N]${NC} > ")" yn
        yn="${yn:-N}"
    fi
    [[ "${yn}" =~ ^[Yy] ]]
}

# --- ASCII Art Banner ---------------------------------------------------------

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
  ____  ____    ___           _        _ _
 / ___|/ ___|  |_ _|_ __  ___| |_ __ _| | | ___ _ __
 \___ \\___ \   | || '_ \/ __| __/ _` | | |/ _ \ '__|
  ___) |___) |  | || | | \__ \ || (_| | | |  __/ |
 |____/|____/  |___|_| |_|___/\__\__,_|_|_|\___|_|
BANNER
    echo -e "                                        by CGQAQ${NC}"
    echo ""
}

# --- Detection Functions ------------------------------------------------------

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *)
            msg_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac
}

detect_os() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        msg_error "This script only supports Linux."
        exit 1
    fi
}

detect_distro() {
    DISTRO_NAME="Unknown"
    DISTRO_FAMILY="unknown"

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO_NAME="${PRETTY_NAME:-${NAME:-Unknown}}"
        local id="${ID:-}"
        local id_like="${ID_LIKE:-}"

        case "${id}" in
            debian|ubuntu|linuxmint|pop|kali|raspbian)
                DISTRO_FAMILY="debian" ;;
            centos|rhel|fedora|rocky|alma|ol)
                DISTRO_FAMILY="rhel" ;;
            arch|manjaro|endeavouros)
                DISTRO_FAMILY="arch" ;;
            alpine)
                DISTRO_FAMILY="alpine" ;;
            *)
                if [[ "${id_like}" == *"debian"* ]]; then
                    DISTRO_FAMILY="debian"
                elif [[ "${id_like}" == *"rhel"* || "${id_like}" == *"fedora"* || "${id_like}" == *"centos"* ]]; then
                    DISTRO_FAMILY="rhel"
                elif [[ "${id_like}" == *"arch"* ]]; then
                    DISTRO_FAMILY="arch"
                fi
                ;;
        esac
    elif [[ -f /etc/debian_version ]]; then
        DISTRO_FAMILY="debian"
        DISTRO_NAME="Debian"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO_FAMILY="rhel"
        DISTRO_NAME="RHEL-based"
    elif [[ -f /etc/arch-release ]]; then
        DISTRO_FAMILY="arch"
        DISTRO_NAME="Arch Linux"
    fi
}

detect_libc() {
    if [[ -f /lib/ld-musl-x86_64.so.1 ]] || [[ -f /lib/ld-musl-aarch64.so.1 ]] || (ldd --version 2>&1 | grep -qi musl); then
        LIBC="musl"
    else
        LIBC="gnu"
    fi
}

# --- Dependency Installation --------------------------------------------------

install_dependencies() {
    msg_info "Installing dependencies..."

    local to_install=()
    local pkg_curl pkg_tar pkg_xz pkg_openssl pkg_qrencode

    case "${DISTRO_FAMILY}" in
        debian)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz-utils" pkg_openssl="openssl" pkg_qrencode="qrencode"
            ;;
        rhel)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="qrencode"
            ;;
        arch)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="qrencode"
            ;;
        alpine)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="libqrencode-tools"
            ;;
        *)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="qrencode"
            ;;
    esac

    command_exists curl    || to_install+=("${pkg_curl}")
    command_exists tar     || to_install+=("${pkg_tar}")
    command_exists xz      || to_install+=("${pkg_xz}")
    command_exists openssl || to_install+=("${pkg_openssl}")
    command_exists qrencode || to_install+=("${pkg_qrencode}")

    if [[ ${#to_install[@]} -eq 0 ]]; then
        msg_success "All dependencies are already installed."
        return
    fi

    msg_info "Installing: ${to_install[*]}"

    case "${DISTRO_FAMILY}" in
        debian)
            apt-get update -qq
            apt-get install -y -qq "${to_install[@]}"
            ;;
        rhel)
            if command_exists dnf; then
                dnf install -y -q "${to_install[@]}"
            else
                yum install -y -q "${to_install[@]}"
            fi
            ;;
        arch)
            pacman -Sy --noconfirm --needed "${to_install[@]}"
            ;;
        alpine)
            apk add --quiet "${to_install[@]}"
            ;;
        *)
            msg_warn "Unknown distro family. Attempting to install with apt-get..."
            apt-get update -qq && apt-get install -y -qq "${to_install[@]}" || {
                msg_error "Could not install dependencies automatically."
                msg_error "Please install manually: curl tar xz openssl qrencode"
                exit 1
            }
            ;;
    esac

    msg_success "Dependencies installed."
}

# --- Download and Install -----------------------------------------------------

get_latest_version() {
    msg_info "Fetching latest shadowsocks-rust release..."
    local api_url="https://api.github.com/repos/${SS_RUST_REPO}/releases/latest"
    local response
    response="$(curl -sL "${api_url}")"

    LATEST_VERSION="$(echo "${response}" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')"

    if [[ -z "${LATEST_VERSION}" ]]; then
        msg_error "Failed to fetch latest version from GitHub API."
        msg_error "You may be rate-limited. Try again later."
        exit 1
    fi

    msg_success "Latest version: ${LATEST_VERSION}"
}

download_and_install() {
    local version="${LATEST_VERSION}"
    local version_num="${version#v}"
    local archive_name="shadowsocks-${version_num}.${ARCH}-unknown-linux-${LIBC}.tar.xz"
    local download_url="https://github.com/${SS_RUST_REPO}/releases/download/${version}/${archive_name}"
    local checksum_url="${download_url}.sha256"

    TEMP_DIR="$(mktemp -d)"

    msg_info "Downloading ${archive_name}..."

    local attempt
    for attempt in 1 2 3; do
        if curl -fSL --progress-bar -o "${TEMP_DIR}/${archive_name}" "${download_url}"; then
            break
        fi
        if [[ "${attempt}" -eq 3 ]]; then
            msg_error "Download failed after 3 attempts."
            exit 1
        fi
        msg_warn "Download failed. Retrying (${attempt}/3)..."
        sleep 2
    done

    # Try to verify checksum
    if curl -fsSL -o "${TEMP_DIR}/${archive_name}.sha256" "${checksum_url}" 2>/dev/null; then
        msg_info "Verifying checksum..."
        cd "${TEMP_DIR}"
        if sha256sum -c "${archive_name}.sha256" &>/dev/null || shasum -a 256 -c "${archive_name}.sha256" &>/dev/null; then
            msg_success "Checksum verified."
        else
            msg_error "Checksum verification failed!"
            exit 1
        fi
        cd - &>/dev/null
    else
        msg_warn "Checksum file not available. Skipping verification."
    fi

    msg_info "Extracting binaries..."
    tar -xJf "${TEMP_DIR}/${archive_name}" -C "${TEMP_DIR}/"

    msg_info "Installing binaries to ${INSTALL_DIR}..."
    for bin in "${BINARY_NAMES[@]}"; do
        if [[ -f "${TEMP_DIR}/${bin}" ]]; then
            install -m 755 "${TEMP_DIR}/${bin}" "${INSTALL_DIR}/${bin}"
        fi
    done

    # Verify
    if command_exists ssserver; then
        local installed_ver
        installed_ver="$(ssserver --version 2>&1 | head -1)"
        msg_success "Installed: ${installed_ver}"
    else
        msg_error "Installation failed — ssserver not found in PATH."
        exit 1
    fi
}

# --- Interactive Configuration ------------------------------------------------

prompt_cipher() {
    msg_step "[Step 2/9] Select Encryption Cipher"
    echo ""
    echo "  1) 2022-blake3-aes-128-gcm     (16-byte key, fast on AES-NI hardware)"
    echo "  2) 2022-blake3-aes-256-gcm     (32-byte key, recommended)"
    echo "  3) 2022-blake3-chacha20-poly1305 (32-byte key, fast on ARM/mobile)"
    echo ""

    local choice
    read -r -p "$(echo -e "Select cipher ${BOLD}[default: 2]${NC} > ")" choice
    choice="${choice:-2}"

    case "${choice}" in
        1) CIPHER="2022-blake3-aes-128-gcm"; KEY_BYTES=16 ;;
        2) CIPHER="2022-blake3-aes-256-gcm"; KEY_BYTES=32 ;;
        3) CIPHER="2022-blake3-chacha20-poly1305"; KEY_BYTES=32 ;;
        *)
            msg_warn "Invalid choice, using default."
            CIPHER="${DEFAULT_CIPHER}"; KEY_BYTES=32
            ;;
    esac

    msg_success "Cipher: ${CIPHER}"
}

prompt_port() {
    msg_step "[Step 3/9] Configure Server Port"
    echo ""

    local port
    while true; do
        read -r -p "$(echo -e "Port ${BOLD}[${DEFAULT_PORT}]${NC} > ")" port
        port="${port:-${DEFAULT_PORT}}"

        if ! [[ "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
            msg_error "Invalid port. Must be 1-65535."
            continue
        fi

        if ss -tlnp 2>/dev/null | grep -q ":${port} " 2>/dev/null; then
            msg_warn "Port ${port} is already in use. Choose another."
            continue
        fi

        break
    done

    SERVER_PORT="${port}"
    msg_success "Port: ${SERVER_PORT}"
}

generate_psk() {
    PSK="$(openssl rand -base64 "${KEY_BYTES}")"
}

confirm_settings() {
    msg_step "[Step 4/9] Confirm Settings"
    echo ""
    echo -e "  Cipher : ${BOLD}${CIPHER}${NC}"
    echo -e "  Port   : ${BOLD}${SERVER_PORT}${NC}"
    echo -e "  Bind   : ${BOLD}0.0.0.0${NC} (all interfaces)"
    echo ""

    if ! confirm "Proceed with these settings?"; then
        msg_error "Aborted by user."
        exit 0
    fi
}

create_config() {
    msg_step "[Step 6/9] Generating Configuration"

    generate_psk

    mkdir -p "${CONFIG_DIR}"

    cat > "${CONFIG_FILE}" << EOF
{
    "server": "0.0.0.0",
    "server_port": ${SERVER_PORT},
    "password": "${PSK}",
    "method": "${CIPHER}",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF

    chmod 600 "${CONFIG_FILE}"
    msg_success "Config written to ${CONFIG_FILE}"
}

# --- Systemd Service ----------------------------------------------------------

setup_systemd() {
    msg_step "[Step 7/9] Setting Up Systemd Service"

    if ! pidof systemd &>/dev/null && ! systemctl --version &>/dev/null 2>&1; then
        msg_warn "systemd not detected. Skipping service setup."
        msg_info "You can start manually: ssserver -c ${CONFIG_FILE}"
        return
    fi

    cat > "${SERVICE_FILE}" << 'EOF'
[Unit]
Description=Shadowsocks-Rust Server (SS2022)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=51200
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" --quiet
    systemctl restart "${SERVICE_NAME}"

    sleep 1

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        msg_success "Service ${SERVICE_NAME} is running."
    else
        msg_error "Service failed to start. Check: journalctl -u ${SERVICE_NAME}"
        exit 1
    fi
}

# --- Firewall -----------------------------------------------------------------

configure_firewall() {
    msg_step "[Step 8/9] Firewall Configuration"
    echo ""

    if ! confirm "Configure firewall to open port ${SERVER_PORT}?"; then
        msg_warn "Skipping firewall configuration."
        return
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -q "active"; then
        msg_info "Configuring ufw..."
        ufw allow "${SERVER_PORT}/tcp" &>/dev/null
        ufw allow "${SERVER_PORT}/udp" &>/dev/null
        msg_success "ufw: opened port ${SERVER_PORT} (TCP+UDP)"

    elif command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        msg_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port="${SERVER_PORT}/tcp" &>/dev/null
        firewall-cmd --permanent --add-port="${SERVER_PORT}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
        msg_success "firewalld: opened port ${SERVER_PORT} (TCP+UDP)"

    elif command_exists iptables; then
        msg_info "Configuring iptables..."
        iptables -I INPUT -p tcp --dport "${SERVER_PORT}" -j ACCEPT
        iptables -I INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT
        msg_success "iptables: opened port ${SERVER_PORT} (TCP+UDP)"
        msg_warn "iptables rules are not persistent across reboots. Install iptables-persistent to save them."

    else
        msg_warn "No supported firewall detected. Make sure port ${SERVER_PORT} is open."
    fi
}

# --- SS URI and Summary -------------------------------------------------------

get_public_ip() {
    SERVER_IP="$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -s4 --max-time 5 https://icanhazip.com 2>/dev/null \
        || curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
        || echo "YOUR_SERVER_IP")"
    SERVER_IP="$(echo "${SERVER_IP}" | tr -d '[:space:]')"
}

generate_ss_uri() {
    # SIP002 format: ss://base64(method:password)@host:port
    local userinfo
    userinfo="$(echo -n "${CIPHER}:${PSK}" | base64 | tr -d '\n')"
    SS_URI="ss://${userinfo}@${SERVER_IP}:${SERVER_PORT}"
}

show_connection_info() {
    get_public_ip
    generate_ss_uri

    msg_step "[Step 9/9] Connection Information"
    echo ""
    echo -e "  ${BOLD}Server IP${NC}  : ${SERVER_IP}"
    echo -e "  ${BOLD}Port${NC}       : ${SERVER_PORT}"
    echo -e "  ${BOLD}Cipher${NC}     : ${CIPHER}"
    echo -e "  ${BOLD}Password${NC}   : ${PSK}"
    echo ""
    echo -e "  ${BOLD}SS URI${NC}:"
    echo -e "  ${GREEN}${SS_URI}${NC}"
    echo ""

    if command_exists qrencode; then
        echo -e "  ${BOLD}QR Code${NC} (scan with your SS client):"
        echo ""
        qrencode -t ansiutf8 "${SS_URI}"
        echo ""
    else
        msg_warn "Install qrencode for QR code display."
    fi

    echo -e "${BOLD}Management commands:${NC}"
    echo "  systemctl status  ${SERVICE_NAME}"
    echo "  systemctl restart ${SERVICE_NAME}"
    echo "  systemctl stop    ${SERVICE_NAME}"
    echo "  journalctl -u     ${SERVICE_NAME} -f"
    echo ""
}

# --- Show existing config info ------------------------------------------------

show_existing_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return 1
    fi

    local password method port
    password="$(grep '"password"' "${CONFIG_FILE}" | sed 's/.*"password": *"//;s/".*//')"
    method="$(grep '"method"' "${CONFIG_FILE}" | sed 's/.*"method": *"//;s/".*//')"
    port="$(grep '"server_port"' "${CONFIG_FILE}" | sed 's/.*"server_port": *//;s/[^0-9].*//')"

    if [[ -z "${password}" || -z "${method}" || -z "${port}" ]]; then
        return 1
    fi

    # Set globals for URI generation
    PSK="${password}"
    CIPHER="${method}"
    SERVER_PORT="${port}"

    get_public_ip
    generate_ss_uri

    echo -e "\n${BOLD}Current Shadowsocks 2022 Configuration:${NC}\n"
    echo -e "  ${BOLD}Server IP${NC}  : ${SERVER_IP}"
    echo -e "  ${BOLD}Port${NC}       : ${SERVER_PORT}"
    echo -e "  ${BOLD}Cipher${NC}     : ${CIPHER}"
    echo -e "  ${BOLD}Password${NC}   : ${PSK}"
    echo ""
    echo -e "  ${BOLD}SS URI${NC}:"
    echo -e "  ${GREEN}${SS_URI}${NC}"
    echo ""

    if command_exists qrencode; then
        echo -e "  ${BOLD}QR Code${NC} (scan with your SS client):"
        echo ""
        qrencode -t ansiutf8 "${SS_URI}"
        echo ""
    fi

    # Show service status
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "  Service: ${GREEN}running${NC}"
    else
        echo -e "  Service: ${RED}stopped${NC}"
    fi
    echo ""
    return 0
}

# --- Uninstall ----------------------------------------------------------------

uninstall() {
    msg_step "Uninstalling Shadowsocks-Rust..."

    # Read port from config before removing, for firewall cleanup
    local port=""
    if [[ -f "${CONFIG_FILE}" ]]; then
        port="$(grep '"server_port"' "${CONFIG_FILE}" | sed 's/.*"server_port": *//;s/[^0-9].*//')"
    fi

    # Stop and disable service
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}"
        msg_info "Service stopped."
    fi
    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl disable "${SERVICE_NAME}" --quiet
    fi
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null

    # Remove binaries
    for bin in "${BINARY_NAMES[@]}"; do
        rm -f "${INSTALL_DIR}/${bin}"
    done
    msg_info "Binaries removed."

    # Remove config
    if [[ -d "${CONFIG_DIR}" ]]; then
        if confirm "Remove configuration directory (${CONFIG_DIR})?"; then
            rm -rf "${CONFIG_DIR}"
            msg_info "Configuration removed."
        else
            msg_info "Configuration kept at ${CONFIG_DIR}."
        fi
    fi

    # Revert firewall
    if [[ -n "${port}" ]]; then
        if command_exists ufw && ufw status 2>/dev/null | grep -q "active"; then
            ufw delete allow "${port}/tcp" &>/dev/null || true
            ufw delete allow "${port}/udp" &>/dev/null || true
            msg_info "ufw: closed port ${port}."
        elif command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --remove-port="${port}/tcp" &>/dev/null || true
            firewall-cmd --permanent --remove-port="${port}/udp" &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
            msg_info "firewalld: closed port ${port}."
        fi
    fi

    msg_success "Shadowsocks-Rust has been uninstalled."
}

# --- Install Flow (Wizard) ----------------------------------------------------

install_flow() {
    msg_step "[Step 1/9] System Detection"
    echo ""
    echo -e "  Distro : ${BOLD}${DISTRO_NAME}${NC} (${DISTRO_FAMILY})"
    echo -e "  Arch   : ${BOLD}${ARCH}${NC}"
    echo -e "  Libc   : ${BOLD}${LIBC}${NC}"
    echo ""

    if ! confirm "Continue with installation?"; then
        msg_error "Aborted by user."
        exit 0
    fi

    prompt_cipher
    prompt_port
    confirm_settings

    msg_step "[Step 5/9] Downloading & Installing"
    get_latest_version
    download_and_install

    create_config
    setup_systemd
    configure_firewall
    show_connection_info

    msg_success "Installation complete!"
}

# --- Main Menu ----------------------------------------------------------------

main() {
    check_root
    detect_os
    detect_arch
    detect_distro
    detect_libc

    show_banner
    install_dependencies

    local is_installed=false
    if command_exists ssserver && [[ -f "${CONFIG_FILE}" ]]; then
        is_installed=true
    fi

    if [[ "${is_installed}" == true ]]; then
        show_existing_config || true

        echo -e "${BOLD}Menu:${NC}"
        echo "  1) Reinstall / Reconfigure"
        echo "  2) Uninstall Shadowsocks 2022"
        echo "  3) Exit"
        echo ""

        local choice
        read -r -p "$(echo -e "Select option ${BOLD}[default: 3]${NC} > ")" choice
        choice="${choice:-3}"

        case "${choice}" in
            1)
                install_flow
                ;;
            2)
                if confirm "Are you sure you want to uninstall?"; then
                    uninstall
                fi
                ;;
            3)
                msg_info "Goodbye!"
                exit 0
                ;;
            *)
                msg_error "Invalid option."
                exit 1
                ;;
        esac
    else
        echo -e "${BOLD}Menu:${NC}"
        echo "  1) Install Shadowsocks 2022"
        echo "  2) Exit"
        echo ""

        local choice
        read -r -p "$(echo -e "Select option ${BOLD}[default: 1]${NC} > ")" choice
        choice="${choice:-1}"

        case "${choice}" in
            1)
                install_flow
                ;;
            2)
                msg_info "Goodbye!"
                exit 0
                ;;
            *)
                msg_error "Invalid option."
                exit 1
                ;;
        esac
    fi
}

main "$@"
