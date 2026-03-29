#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Common Proxy Manager (CPM)
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
SCRIPT_VERSION="2.0.1"
DEFAULT_CIPHER="2022-blake3-aes-256-gcm"
TEMP_DIR=""

# --- Xray / VLESS+Reality Constants ------------------------------------------
XRAY_REPO="XTLS/Xray-core"
XRAY_INSTALL_DIR="/usr/local/bin"
XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_SERVICE_NAME="xray-server"
XRAY_SERVICE_FILE="/etc/systemd/system/${XRAY_SERVICE_NAME}.service"
XRAY_BINARY_NAME="xray"
XRAY_DEFAULT_PORT=443
XRAY_DEFAULT_DEST="www.microsoft.com:443"
PROTOCOL=""  # "ss2022" or "vless-reality"

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
   ____                                        ____
  / ___|___  _ __ ___  _ __ ___   ___  _ __   |  _ \ _ __ _____  ___   _
 | |   / _ \| '_ ` _ \| '_ ` _ \ / _ \| '_ \  | |_) | '__/ _ \ \/ / | | |
 | |__| (_) | | | | | | | | | | | (_) | | | | |  __/| | | (_) >  <| |_| |
  \____\___/|_| |_| |_|_| |_| |_|\___/|_| |_| |_|   |_|  \___/_/\_\\__, |
  __  __                                                             |___/
 |  \/  | __ _ _ __   __ _  __ _  ___ _ __
 | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 | |  | | (_| | | | | (_| | (_| |  __/ |
 |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|
                            |___/
BANNER
    echo -e "                                        by CGQAQ"
    echo -e "                                        v${SCRIPT_VERSION}${NC}"
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

# --- Protocol Detection Helpers -----------------------------------------------

is_ss_installed() {
    command_exists ssserver && [[ -f "${CONFIG_FILE}" ]]
}

is_xray_installed() {
    command_exists xray && [[ -f "${XRAY_CONFIG_FILE}" ]]
}

get_xray_arch_suffix() {
    case "${ARCH}" in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
    esac
}

# --- Dependency Installation --------------------------------------------------

install_dependencies() {
    msg_info "Installing dependencies..."

    local to_install=()
    local pkg_curl pkg_tar pkg_xz pkg_openssl pkg_qrencode pkg_unzip

    case "${DISTRO_FAMILY}" in
        debian)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz-utils" pkg_openssl="openssl" pkg_qrencode="qrencode" pkg_unzip="unzip"
            ;;
        rhel)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="qrencode" pkg_unzip="unzip"
            ;;
        arch)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="qrencode" pkg_unzip="unzip"
            ;;
        alpine)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="libqrencode-tools" pkg_unzip="unzip"
            ;;
        *)
            pkg_curl="curl" pkg_tar="tar" pkg_xz="xz" pkg_openssl="openssl" pkg_qrencode="qrencode" pkg_unzip="unzip"
            ;;
    esac

    command_exists curl    || to_install+=("${pkg_curl}")
    command_exists tar     || to_install+=("${pkg_tar}")
    command_exists xz      || to_install+=("${pkg_xz}")
    command_exists openssl || to_install+=("${pkg_openssl}")
    command_exists qrencode || to_install+=("${pkg_qrencode}")
    command_exists unzip   || to_install+=("${pkg_unzip}")

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
    local archive_name="shadowsocks-${version}.${ARCH}-unknown-linux-${LIBC}.tar.xz"
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
    msg_step "[Step 2/10] Select Encryption Cipher"
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
    msg_step "[Step 3/10] Configure Server Port"
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
    msg_step "[Step 4/10] Confirm Settings"
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
    msg_step "[Step 6/10] Generating Configuration"

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

    chmod 644 "${CONFIG_FILE}"
    msg_success "Config written to ${CONFIG_FILE}"
}

# --- Systemd Service ----------------------------------------------------------

setup_systemd() {
    msg_step "[Step 7/10] Setting Up Systemd Service"

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
ConfigurationDirectory=shadowsocks-rust
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
    local port="${1:-${SERVER_PORT}}"
    msg_step "[Step 8/10] Firewall Configuration"
    echo ""

    if ! confirm "Configure firewall to open port ${port}?"; then
        msg_warn "Skipping firewall configuration."
        return
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -q "active"; then
        msg_info "Configuring ufw..."
        ufw allow "${port}/tcp" &>/dev/null
        ufw allow "${port}/udp" &>/dev/null
        msg_success "ufw: opened port ${port} (TCP+UDP)"

    elif command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        msg_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null
        firewall-cmd --permanent --add-port="${port}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
        msg_success "firewalld: opened port ${port} (TCP+UDP)"

    elif command_exists iptables; then
        msg_info "Configuring iptables..."
        iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT
        iptables -I INPUT -p udp --dport "${port}" -j ACCEPT
        msg_success "iptables: opened port ${port} (TCP+UDP)"
        msg_warn "iptables rules are not persistent across reboots. Install iptables-persistent to save them."

    else
        msg_warn "No supported firewall detected. Make sure port ${port} is open."
    fi
}

# --- VLESS+Reality Functions ---------------------------------------------------

get_latest_xray_version() {
    msg_info "Fetching latest Xray-core release..."
    local api_url="https://api.github.com/repos/${XRAY_REPO}/releases/latest"
    local response
    response="$(curl -sL "${api_url}")"

    XRAY_LATEST_VERSION="$(echo "${response}" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')"

    if [[ -z "${XRAY_LATEST_VERSION}" ]]; then
        msg_error "Failed to fetch latest Xray version from GitHub API."
        msg_error "You may be rate-limited. Try again later."
        exit 1
    fi

    msg_success "Latest Xray version: ${XRAY_LATEST_VERSION}"
}

download_and_install_xray() {
    local version="${XRAY_LATEST_VERSION}"
    local arch_suffix
    arch_suffix="$(get_xray_arch_suffix)"
    local archive_name="Xray-linux-${arch_suffix}.zip"
    local download_url="https://github.com/${XRAY_REPO}/releases/download/${version}/${archive_name}"
    local dgst_url="${download_url}.dgst"

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

    # Try to verify checksum from .dgst file
    if curl -fsSL -o "${TEMP_DIR}/${archive_name}.dgst" "${dgst_url}" 2>/dev/null; then
        msg_info "Verifying checksum..."
        local expected_hash
        expected_hash="$(grep 'SHA2-256' "${TEMP_DIR}/${archive_name}.dgst" | head -1 | awk -F'= ' '{print $2}' | tr -d '[:space:]')"
        if [[ -n "${expected_hash}" ]]; then
            local actual_hash
            actual_hash="$(sha256sum "${TEMP_DIR}/${archive_name}" 2>/dev/null | awk '{print $1}' || shasum -a 256 "${TEMP_DIR}/${archive_name}" | awk '{print $1}')"
            if [[ "${actual_hash}" == "${expected_hash}" ]]; then
                msg_success "Checksum verified."
            else
                msg_error "Checksum verification failed!"
                exit 1
            fi
        else
            msg_warn "Could not parse checksum. Skipping verification."
        fi
    else
        msg_warn "Checksum file not available. Skipping verification."
    fi

    msg_info "Extracting Xray binary..."
    unzip -o -q "${TEMP_DIR}/${archive_name}" -d "${TEMP_DIR}/xray"

    msg_info "Installing Xray to ${XRAY_INSTALL_DIR}..."
    install -m 755 "${TEMP_DIR}/xray/xray" "${XRAY_INSTALL_DIR}/${XRAY_BINARY_NAME}"

    # Verify
    if command_exists xray; then
        local installed_ver
        installed_ver="$(xray version 2>&1 | head -1)"
        msg_success "Installed: ${installed_ver}"
    else
        msg_error "Installation failed — xray not found in PATH."
        exit 1
    fi
}

prompt_vless_port() {
    msg_step "[Step 2/10] Configure VLESS+Reality Port"
    echo ""

    local port
    while true; do
        read -r -p "$(echo -e "Port ${BOLD}[${XRAY_DEFAULT_PORT}]${NC} > ")" port
        port="${port:-${XRAY_DEFAULT_PORT}}"

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

    VLESS_PORT="${port}"
    msg_success "Port: ${VLESS_PORT}"
}

prompt_vless_dest() {
    msg_step "[Step 3/10] Configure Camouflage Target"
    echo ""
    echo "  The 'dest' is the real TLS server Xray will camouflage as."
    echo "  It must support TLSv1.3 and H2."
    echo ""

    local dest
    read -r -p "$(echo -e "Dest ${BOLD}[${XRAY_DEFAULT_DEST}]${NC} > ")" dest
    dest="${dest:-${XRAY_DEFAULT_DEST}}"
    VLESS_DEST="${dest}"

    local sni_default
    sni_default="$(echo "${dest}" | sed 's/:.*$//')"
    local sni_input
    read -r -p "$(echo -e "Server Names (comma-separated) ${BOLD}[${sni_default}]${NC} > ")" sni_input
    sni_input="${sni_input:-${sni_default}}"
    # Store raw comma-separated for later use
    VLESS_SNI_RAW="${sni_input}"
    # Convert comma-separated to JSON array
    VLESS_SERVER_NAMES="$(echo "${sni_input}" | sed 's/[[:space:]]//g' | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","} printf "]"}')"

    msg_success "Dest: ${VLESS_DEST}"
    msg_success "SNI: ${VLESS_SERVER_NAMES}"
}

generate_uuid() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
    else
        VLESS_UUID="$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')"
    fi
}

generate_x25519_keypair() {
    msg_info "Generating x25519 keypair..."
    local output
    output="$(xray x25519)"
    VLESS_PRIVATE_KEY="$(echo "${output}" | grep 'PrivateKey:' | awk '{print $2}')"
    VLESS_PUBLIC_KEY="$(echo "${output}" | grep 'PublicKey)' | awk '{print $3}')"
    msg_success "x25519 keypair generated."
}

generate_short_id() {
    VLESS_SHORT_ID="$(openssl rand -hex 8)"
}

confirm_vless_settings() {
    msg_step "[Step 4/10] Confirm Settings"
    echo ""
    echo -e "  Protocol : ${BOLD}VLESS + Reality${NC}"
    echo -e "  Port     : ${BOLD}${VLESS_PORT}${NC}"
    echo -e "  Dest     : ${BOLD}${VLESS_DEST}${NC}"
    echo -e "  SNI      : ${BOLD}${VLESS_SERVER_NAMES}${NC}"
    echo ""

    if ! confirm "Proceed with these settings?"; then
        msg_error "Aborted by user."
        exit 0
    fi
}

create_xray_config() {
    msg_step "[Step 6/10] Generating Configuration"

    generate_uuid
    generate_x25519_keypair
    generate_short_id

    mkdir -p "${XRAY_CONFIG_DIR}"

    cat > "${XRAY_CONFIG_FILE}" << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": ${VLESS_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${VLESS_UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "${VLESS_DEST}",
                    "serverNames": ${VLESS_SERVER_NAMES},
                    "privateKey": "${VLESS_PRIVATE_KEY}",
                    "shortIds": [
                        "${VLESS_SHORT_ID}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF

    chmod 644 "${XRAY_CONFIG_FILE}"
    msg_success "Config written to ${XRAY_CONFIG_FILE}"
}

setup_xray_systemd() {
    msg_step "[Step 7/10] Setting Up Systemd Service"

    if ! pidof systemd &>/dev/null && ! systemctl --version &>/dev/null 2>&1; then
        msg_warn "systemd not detected. Skipping service setup."
        msg_info "You can start manually: xray run -c ${XRAY_CONFIG_FILE}"
        return
    fi

    cat > "${XRAY_SERVICE_FILE}" << 'EOF'
[Unit]
Description=Xray Server (VLESS+Reality)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=51200
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${XRAY_SERVICE_NAME}" --quiet
    systemctl restart "${XRAY_SERVICE_NAME}"

    sleep 1

    if systemctl is-active --quiet "${XRAY_SERVICE_NAME}"; then
        msg_success "Service ${XRAY_SERVICE_NAME} is running."
    else
        msg_error "Service failed to start. Check: journalctl -u ${XRAY_SERVICE_NAME}"
        exit 1
    fi
}

generate_vless_uri() {
    local sni
    sni="$(echo "${VLESS_SNI_RAW}" | cut -d',' -f1 | tr -d '[:space:]')"
    VLESS_URI="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${VLESS_PUBLIC_KEY}&sid=${VLESS_SHORT_ID}&type=tcp#vless-reality-${SERVER_IP}"
}

show_vless_clash_config() {
    local sni
    sni="$(echo "${VLESS_SNI_RAW}" | cut -d',' -f1 | tr -d '[:space:]')"
    echo -e "  ${BOLD}Clash/Mihomo Proxy Config:${NC}"
    echo -e "${YELLOW}"
    cat << EOF
proxies:
- name: "vless-${SERVER_IP}"
  type: vless
  server: ${SERVER_IP}
  port: ${VLESS_PORT}
  uuid: ${VLESS_UUID}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${sni}
  reality-opts:
    public-key: ${VLESS_PUBLIC_KEY}
    short-id: ${VLESS_SHORT_ID}
  client-fingerprint: chrome
EOF
    echo -e "${NC}"
}

show_vless_connection_info() {
    get_public_ip
    generate_vless_uri

    msg_step "[Step 10/10] Connection Information"
    echo ""
    echo -e "  ${BOLD}Server IP${NC}   : ${SERVER_IP}"
    echo -e "  ${BOLD}Port${NC}        : ${VLESS_PORT}"
    echo -e "  ${BOLD}UUID${NC}        : ${VLESS_UUID}"
    echo -e "  ${BOLD}Flow${NC}        : xtls-rprx-vision"
    echo -e "  ${BOLD}Security${NC}    : reality"
    echo -e "  ${BOLD}Dest${NC}        : ${VLESS_DEST}"
    echo -e "  ${BOLD}SNI${NC}         : ${VLESS_SNI_RAW}"
    echo -e "  ${BOLD}Public Key${NC}  : ${VLESS_PUBLIC_KEY}"
    echo -e "  ${BOLD}Short ID${NC}    : ${VLESS_SHORT_ID}"
    echo ""
    echo -e "  ${BOLD}VLESS URI${NC}:"
    echo -e "  ${GREEN}${VLESS_URI}${NC}"
    echo ""

    if command_exists qrencode; then
        echo -e "  ${BOLD}QR Code${NC} (scan with your client):"
        echo ""
        qrencode -t ansiutf8 "${VLESS_URI}"
        echo ""
    else
        msg_warn "Install qrencode for QR code display."
    fi

    show_vless_clash_config

    echo -e "${BOLD}Management commands:${NC}"
    echo "  systemctl status  ${XRAY_SERVICE_NAME}"
    echo "  systemctl restart ${XRAY_SERVICE_NAME}"
    echo "  systemctl stop    ${XRAY_SERVICE_NAME}"
    echo "  journalctl -u     ${XRAY_SERVICE_NAME} -f"
    echo ""
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

show_clash_config() {
    echo -e "  ${BOLD}Clash/Mihomo Proxy Config:${NC}"
    echo -e "${YELLOW}"
    cat << EOF
proxies:
- name: "ss-${SERVER_IP}"
  type: ss
  server: ${SERVER_IP}
  port: ${SERVER_PORT}
  cipher: ${CIPHER}
  password: "${PSK}"
  udp: true
EOF
    echo -e "${NC}"
}

show_connection_info() {
    get_public_ip
    generate_ss_uri

    msg_step "[Step 10/10] Connection Information"
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

    show_clash_config

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

    show_clash_config

    # Show service status and management commands
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "  Service: ${GREEN}running${NC}"
    else
        echo -e "  Service: ${RED}stopped${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Management commands:${NC}"
    echo "    systemctl start   ${SERVICE_NAME}"
    echo "    systemctl stop    ${SERVICE_NAME}"
    echo "    systemctl restart ${SERVICE_NAME}"
    echo "    journalctl -u     ${SERVICE_NAME} -f"
    echo ""
    return 0
}

# --- Show existing Xray config info -------------------------------------------

show_existing_xray_config() {
    if [[ ! -f "${XRAY_CONFIG_FILE}" ]]; then
        return 1
    fi

    local uuid port dest private_key short_id server_names_raw
    uuid="$(grep '"id"' "${XRAY_CONFIG_FILE}" | head -1 | sed 's/.*"id": *"//;s/".*//')"
    port="$(grep '"port"' "${XRAY_CONFIG_FILE}" | head -1 | sed 's/.*"port": *//;s/[^0-9].*//')"
    dest="$(grep '"dest"' "${XRAY_CONFIG_FILE}" | head -1 | sed 's/.*"dest": *"//;s/".*//')"
    private_key="$(grep '"privateKey"' "${XRAY_CONFIG_FILE}" | head -1 | sed 's/.*"privateKey": *"//;s/".*//')"
    short_id="$(grep '"shortIds"' -A1 "${XRAY_CONFIG_FILE}" | tail -1 | sed 's/.*"//;s/".*//')"
    # Extract serverNames as comma-separated
    server_names_raw="$(grep -oP '"serverNames"\s*:\s*\[([^\]]+)\]' "${XRAY_CONFIG_FILE}" | sed 's/.*\[//;s/\]//;s/"//g;s/ //g')"

    if [[ -z "${uuid}" || -z "${port}" ]]; then
        return 1
    fi

    # Regenerate public key from private key
    local public_key=""
    if command_exists xray && [[ -n "${private_key}" ]]; then
        public_key="$(xray x25519 -i "${private_key}" 2>/dev/null | grep 'PublicKey)' | awk '{print $3}')"
    fi

    # Set globals for URI generation
    VLESS_UUID="${uuid}"
    VLESS_PORT="${port}"
    VLESS_DEST="${dest}"
    VLESS_SHORT_ID="${short_id}"
    VLESS_PUBLIC_KEY="${public_key}"
    VLESS_SNI_RAW="${server_names_raw}"
    VLESS_SERVER_NAMES="$(echo "${server_names_raw}" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"", $i; if(i<NF) printf ","} printf "]"}')"

    get_public_ip
    if [[ -n "${public_key}" ]]; then
        generate_vless_uri
    fi

    echo -e "\n${BOLD}Current VLESS+Reality Configuration:${NC}\n"
    echo -e "  ${BOLD}Server IP${NC}   : ${SERVER_IP}"
    echo -e "  ${BOLD}Port${NC}        : ${VLESS_PORT}"
    echo -e "  ${BOLD}UUID${NC}        : ${VLESS_UUID}"
    echo -e "  ${BOLD}Flow${NC}        : xtls-rprx-vision"
    echo -e "  ${BOLD}Security${NC}    : reality"
    echo -e "  ${BOLD}Dest${NC}        : ${VLESS_DEST}"
    echo -e "  ${BOLD}SNI${NC}         : ${server_names_raw}"
    echo -e "  ${BOLD}Public Key${NC}  : ${public_key:-N/A}"
    echo -e "  ${BOLD}Short ID${NC}    : ${VLESS_SHORT_ID}"
    echo ""

    if [[ -n "${public_key}" ]]; then
        echo -e "  ${BOLD}VLESS URI${NC}:"
        echo -e "  ${GREEN}${VLESS_URI}${NC}"
        echo ""

        if command_exists qrencode; then
            echo -e "  ${BOLD}QR Code${NC} (scan with your client):"
            echo ""
            qrencode -t ansiutf8 "${VLESS_URI}"
            echo ""
        fi

        show_vless_clash_config
    fi

    # Show service status
    if systemctl is-active --quiet "${XRAY_SERVICE_NAME}" 2>/dev/null; then
        echo -e "  Service: ${GREEN}running${NC}"
    else
        echo -e "  Service: ${RED}stopped${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Management commands:${NC}"
    echo "    systemctl start   ${XRAY_SERVICE_NAME}"
    echo "    systemctl stop    ${XRAY_SERVICE_NAME}"
    echo "    systemctl restart ${XRAY_SERVICE_NAME}"
    echo "    journalctl -u     ${XRAY_SERVICE_NAME} -f"
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

    # Remove installer script
    if [[ -f /usr/bin/cpm ]]; then
        if confirm "Remove /usr/bin/cpm?"; then
            rm -f /usr/bin/cpm
            msg_info "Installer script removed."
        else
            msg_info "Installer script kept at /usr/bin/cpm."
        fi
    fi

    msg_success "Shadowsocks-Rust has been uninstalled."
}

uninstall_xray() {
    msg_step "Uninstalling Xray (VLESS+Reality)..."

    # Read port from config before removing, for firewall cleanup
    local port=""
    if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
        port="$(grep '"port"' "${XRAY_CONFIG_FILE}" | head -1 | sed 's/.*"port": *//;s/[^0-9].*//')"
    fi

    # Stop and disable service
    if systemctl is-active --quiet "${XRAY_SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${XRAY_SERVICE_NAME}"
        msg_info "Service stopped."
    fi
    if systemctl is-enabled --quiet "${XRAY_SERVICE_NAME}" 2>/dev/null; then
        systemctl disable "${XRAY_SERVICE_NAME}" --quiet
    fi
    rm -f "${XRAY_SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null

    # Remove binary
    rm -f "${XRAY_INSTALL_DIR}/${XRAY_BINARY_NAME}"
    msg_info "Xray binary removed."

    # Remove config
    if [[ -d "${XRAY_CONFIG_DIR}" ]]; then
        if confirm "Remove configuration directory (${XRAY_CONFIG_DIR})?"; then
            rm -rf "${XRAY_CONFIG_DIR}"
            msg_info "Configuration removed."
        else
            msg_info "Configuration kept at ${XRAY_CONFIG_DIR}."
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

    msg_success "Xray (VLESS+Reality) has been uninstalled."
}

# --- Protocol Selection -------------------------------------------------------

prompt_protocol() {
    msg_step "Select Protocol"
    echo ""
    echo "  1) Shadowsocks 2022    (fast, simple, UDP-capable)"
    echo "  2) VLESS + Reality     (TLS camouflage, anti-detection)"
    echo ""

    local choice
    read -r -p "$(echo -e "Select protocol ${BOLD}[default: 1]${NC} > ")" choice
    choice="${choice:-1}"

    case "${choice}" in
        1) PROTOCOL="ss2022" ;;
        2) PROTOCOL="vless-reality" ;;
        *)
            msg_warn "Invalid choice, using default."
            PROTOCOL="ss2022"
            ;;
    esac

    msg_success "Protocol: ${PROTOCOL}"
}

# --- VLESS Install Flow -------------------------------------------------------

install_vless_flow() {
    msg_step "[Step 1/10] System Detection"
    echo ""
    echo -e "  Distro : ${BOLD}${DISTRO_NAME}${NC} (${DISTRO_FAMILY})"
    echo -e "  Arch   : ${BOLD}${ARCH}${NC}"
    echo ""

    prompt_vless_port
    prompt_vless_dest
    confirm_vless_settings

    msg_step "[Step 5/10] Downloading & Installing Xray"
    get_latest_xray_version
    download_and_install_xray

    create_xray_config
    setup_xray_systemd
    configure_firewall "${VLESS_PORT}"
    prompt_install_script
    show_vless_connection_info

    msg_success "Installation complete!"
}

# --- Install Flow (Wizard) ----------------------------------------------------

install_flow() {
    if [[ -z "${PROTOCOL}" ]]; then
        prompt_protocol
    fi

    if [[ "${PROTOCOL}" == "vless-reality" ]]; then
        install_vless_flow
        PROTOCOL=""
        return
    fi
    PROTOCOL=""

    msg_step "[Step 1/10] System Detection"
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

    msg_step "[Step 5/10] Downloading & Installing"
    get_latest_version
    download_and_install

    create_config
    setup_systemd
    configure_firewall
    prompt_install_script
    show_connection_info

    msg_success "Installation complete!"
}

# --- Install Script to /usr/bin ------------------------------------------------

install_script() {
    local target="/usr/bin/cpm"
    local url="https://raw.githubusercontent.com/CGQAQ/cpm/main/cpm.sh?t=$(date +%s)"

    msg_info "Downloading cpm..."
    if curl -fsSL -o "${target}.tmp" "${url}"; then
        install -m 755 "${target}.tmp" "${target}"
        rm -f "${target}.tmp"
        msg_success "Script installed to ${target}"
        msg_info "You can now run: cpm"
    else
        rm -f "${target}.tmp"
        msg_error "Failed to download script."
    fi
}

upgrade_script() {
    local target="/usr/bin/cpm"
    local url="https://raw.githubusercontent.com/CGQAQ/cpm/main/cpm.sh?t=$(date +%s)"

    msg_info "Downloading latest cpm..."
    if curl -fsSL -o "${target}.tmp" "${url}"; then
        install -m 755 "${target}.tmp" "${target}"
        rm -f "${target}.tmp"
        local new_ver
        new_ver="$(grep '^SCRIPT_VERSION=' "${target}" | sed 's/SCRIPT_VERSION="//;s/"//')"
        msg_success "Upgraded to v${new_ver}"
    else
        rm -f "${target}.tmp"
        msg_error "Failed to download latest version."
    fi
}

prompt_install_script() {
    msg_step "[Step 9/10] Install Script"
    echo ""
    if confirm "Install this script to /usr/bin/cpm for easy access?"; then
        install_script
    else
        msg_info "Skipped."
    fi
}

# --- Help ---------------------------------------------------------------------

show_help() {
    echo "Usage: $(basename "$0") [COMMAND]"
    echo ""
    echo "SS Installer v${SCRIPT_VERSION} — Shadowsocks 2022 & VLESS+Reality"
    echo ""
    echo "Commands:"
    echo "  install       Install proxy (interactive wizard — SS2022 or VLESS+Reality)"
    echo "  uninstall     Uninstall proxy"
    echo "  start         Start proxy service(s)"
    echo "  stop          Stop proxy service(s)"
    echo "  restart       Restart proxy service(s)"
    echo "  enable        Enable auto-start on boot"
    echo "  disable       Disable auto-start on boot"
    echo "  status        Show current configuration and service status"
    echo "  upgrade       Upgrade the cpm script"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message and exit"
    echo ""
    echo "Run without arguments to launch the interactive menu."
}

# --- Main Menu ----------------------------------------------------------------

main() {
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        start)
            check_root
            is_ss_installed && { systemctl start "${SERVICE_NAME}"; msg_success "${SERVICE_NAME} started."; }
            is_xray_installed && { systemctl start "${XRAY_SERVICE_NAME}"; msg_success "${XRAY_SERVICE_NAME} started."; }
            is_ss_installed || is_xray_installed || msg_error "No proxy is installed."
            exit 0
            ;;
        stop)
            check_root
            is_ss_installed && { systemctl stop "${SERVICE_NAME}"; msg_success "${SERVICE_NAME} stopped."; }
            is_xray_installed && { systemctl stop "${XRAY_SERVICE_NAME}"; msg_success "${XRAY_SERVICE_NAME} stopped."; }
            is_ss_installed || is_xray_installed || msg_error "No proxy is installed."
            exit 0
            ;;
        restart)
            check_root
            is_ss_installed && { systemctl restart "${SERVICE_NAME}"; msg_success "${SERVICE_NAME} restarted."; }
            is_xray_installed && { systemctl restart "${XRAY_SERVICE_NAME}"; msg_success "${XRAY_SERVICE_NAME} restarted."; }
            is_ss_installed || is_xray_installed || msg_error "No proxy is installed."
            exit 0
            ;;
        enable)
            check_root
            is_ss_installed && { systemctl enable "${SERVICE_NAME}" --quiet; msg_success "${SERVICE_NAME} auto-start enabled."; }
            is_xray_installed && { systemctl enable "${XRAY_SERVICE_NAME}" --quiet; msg_success "${XRAY_SERVICE_NAME} auto-start enabled."; }
            is_ss_installed || is_xray_installed || msg_error "No proxy is installed."
            exit 0
            ;;
        disable)
            check_root
            is_ss_installed && { systemctl disable "${SERVICE_NAME}" --quiet; msg_success "${SERVICE_NAME} auto-start disabled."; }
            is_xray_installed && { systemctl disable "${XRAY_SERVICE_NAME}" --quiet; msg_success "${XRAY_SERVICE_NAME} auto-start disabled."; }
            is_ss_installed || is_xray_installed || msg_error "No proxy is installed."
            exit 0
            ;;
        status)
            check_root
            detect_os
            detect_arch
            detect_distro
            detect_libc
            show_banner
            local found=false
            if show_existing_config 2>/dev/null; then found=true; fi
            if show_existing_xray_config 2>/dev/null; then found=true; fi
            if [[ "${found}" == false ]]; then
                msg_info "No proxy is installed."
            fi
            exit 0
            ;;
        install)
            check_root
            detect_os
            detect_arch
            detect_distro
            detect_libc
            show_banner
            install_dependencies
            install_flow
            exit 0
            ;;
        uninstall)
            check_root
            detect_os
            detect_arch
            detect_distro
            detect_libc
            show_banner
            local ss_inst=false xray_inst=false
            is_ss_installed && ss_inst=true
            is_xray_installed && xray_inst=true
            if [[ "${ss_inst}" == true && "${xray_inst}" == true ]]; then
                echo -e "${BOLD}Which protocol to uninstall?${NC}"
                echo "  1) Shadowsocks 2022"
                echo "  2) VLESS+Reality"
                echo "  3) Both"
                echo ""
                local uchoice
                read -r -p "$(echo -e "Select ${BOLD}[default: 3]${NC} > ")" uchoice
                uchoice="${uchoice:-3}"
                case "${uchoice}" in
                    1) confirm "Uninstall Shadowsocks 2022?" && uninstall ;;
                    2) confirm "Uninstall VLESS+Reality?" && uninstall_xray ;;
                    3) confirm "Uninstall both?" && { uninstall; uninstall_xray; } ;;
                    *) msg_error "Invalid option." ;;
                esac
            elif [[ "${ss_inst}" == true ]]; then
                confirm "Are you sure you want to uninstall Shadowsocks 2022?" && uninstall
            elif [[ "${xray_inst}" == true ]]; then
                confirm "Are you sure you want to uninstall VLESS+Reality?" && uninstall_xray
            else
                msg_info "Nothing is installed."
            fi
            exit 0
            ;;
        upgrade)
            check_root
            upgrade_script
            exit 0
            ;;
        "")
            # No command — fall through to interactive menu
            ;;
        *)
            msg_error "Unknown command: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac

    check_root
    detect_os
    detect_arch
    detect_distro
    detect_libc

    show_banner
    install_dependencies

    local ss_installed=false xray_installed=false
    is_ss_installed && ss_installed=true
    is_xray_installed && xray_installed=true
    local any_installed=false
    [[ "${ss_installed}" == true || "${xray_installed}" == true ]] && any_installed=true

    if [[ "${any_installed}" == true ]]; then
        # Show existing configs
        [[ "${ss_installed}" == true ]] && { show_existing_config || true; }
        [[ "${xray_installed}" == true ]] && { show_existing_xray_config || true; }

        local script_installed=false
        [[ -f /usr/bin/cpm ]] && script_installed=true

        echo -e "${BOLD}Menu:${NC}"
        echo "  1) Start service(s)"
        echo "  2) Stop service(s)"
        echo "  3) Restart service(s)"
        echo "  4) Enable auto-start on boot"
        echo "  5) Disable auto-start on boot"
        if [[ "${script_installed}" == true ]]; then
            echo "  6) Upgrade cpm script"
        else
            echo "  6) Install this script to /usr/bin/cpm"
        fi
        echo "  7) Install another protocol"
        echo "  8) Reinstall / Reconfigure"
        echo "  9) Uninstall"
        echo "  0) Exit"
        echo ""

        local choice
        read -r -p "$(echo -e "Select option ${BOLD}[default: 0]${NC} > ")" choice
        choice="${choice:-0}"

        case "${choice}" in
            1)
                [[ "${ss_installed}" == true ]] && { systemctl start "${SERVICE_NAME}"; msg_success "${SERVICE_NAME} started."; }
                [[ "${xray_installed}" == true ]] && { systemctl start "${XRAY_SERVICE_NAME}"; msg_success "${XRAY_SERVICE_NAME} started."; }
                ;;
            2)
                [[ "${ss_installed}" == true ]] && { systemctl stop "${SERVICE_NAME}"; msg_success "${SERVICE_NAME} stopped."; }
                [[ "${xray_installed}" == true ]] && { systemctl stop "${XRAY_SERVICE_NAME}"; msg_success "${XRAY_SERVICE_NAME} stopped."; }
                ;;
            3)
                [[ "${ss_installed}" == true ]] && { systemctl restart "${SERVICE_NAME}"; msg_success "${SERVICE_NAME} restarted."; }
                [[ "${xray_installed}" == true ]] && { systemctl restart "${XRAY_SERVICE_NAME}"; msg_success "${XRAY_SERVICE_NAME} restarted."; }
                ;;
            4)
                [[ "${ss_installed}" == true ]] && { systemctl enable "${SERVICE_NAME}" --quiet; msg_success "${SERVICE_NAME} auto-start enabled."; }
                [[ "${xray_installed}" == true ]] && { systemctl enable "${XRAY_SERVICE_NAME}" --quiet; msg_success "${XRAY_SERVICE_NAME} auto-start enabled."; }
                ;;
            5)
                [[ "${ss_installed}" == true ]] && { systemctl disable "${SERVICE_NAME}" --quiet; msg_success "${SERVICE_NAME} auto-start disabled."; }
                [[ "${xray_installed}" == true ]] && { systemctl disable "${XRAY_SERVICE_NAME}" --quiet; msg_success "${XRAY_SERVICE_NAME} auto-start disabled."; }
                ;;
            6)
                if [[ "${script_installed}" == true ]]; then
                    upgrade_script
                else
                    install_script
                fi
                ;;
            7)
                if [[ "${ss_installed}" == false ]]; then
                    PROTOCOL="ss2022"
                    install_flow
                elif [[ "${xray_installed}" == false ]]; then
                    PROTOCOL="vless-reality"
                    install_vless_flow
                else
                    msg_info "Both protocols are already installed."
                fi
                ;;
            8)
                install_flow
                ;;
            9)
                if [[ "${ss_installed}" == true && "${xray_installed}" == true ]]; then
                    echo -e "${BOLD}Which protocol to uninstall?${NC}"
                    echo "  1) Shadowsocks 2022"
                    echo "  2) VLESS+Reality"
                    echo "  3) Both"
                    echo ""
                    local uchoice
                    read -r -p "$(echo -e "Select ${BOLD}[default: 3]${NC} > ")" uchoice
                    uchoice="${uchoice:-3}"
                    case "${uchoice}" in
                        1) confirm "Uninstall Shadowsocks 2022?" && uninstall ;;
                        2) confirm "Uninstall VLESS+Reality?" && uninstall_xray ;;
                        3) confirm "Uninstall both?" && { uninstall; uninstall_xray; } ;;
                        *) msg_error "Invalid option." ;;
                    esac
                elif [[ "${ss_installed}" == true ]]; then
                    confirm "Uninstall Shadowsocks 2022?" && uninstall
                else
                    confirm "Uninstall VLESS+Reality?" && uninstall_xray
                fi
                ;;
            0)
                msg_info "Goodbye!"
                exit 0
                ;;
            *)
                msg_error "Invalid option."
                exit 1
                ;;
        esac
    else
        local script_installed=false
        [[ -f /usr/bin/cpm ]] && script_installed=true

        echo -e "${BOLD}Menu:${NC}"
        echo "  1) Install proxy (SS2022 or VLESS+Reality)"
        if [[ "${script_installed}" == true ]]; then
            echo "  2) Upgrade cpm script"
        else
            echo "  2) Install this script to /usr/bin/cpm"
        fi
        echo "  3) Exit"
        echo ""

        local choice
        read -r -p "$(echo -e "Select option ${BOLD}[default: 1]${NC} > ")" choice
        choice="${choice:-1}"

        case "${choice}" in
            1)
                install_flow
                ;;
            2)
                if [[ "${script_installed}" == true ]]; then
                    upgrade_script
                else
                    install_script
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
    fi
}

main "$@"
