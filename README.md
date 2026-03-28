# SS Installer

One-command installer for Shadowsocks 2022 (shadowsocks-rust) on Linux.

## Quick Start

```bash
sudo bash <(curl -sSL https://raw.githubusercontent.com/CGQAQ/ss-installer/main/install.sh)
```

## Supported Systems

- Debian / Ubuntu
- CentOS / RHEL / Fedora
- Arch Linux / Manjaro
- Alpine Linux
- Architectures: x86_64, aarch64

## Features

- Interactive menu-driven setup with sensible defaults
- Shadowsocks 2022 ciphers (AEAD-2022)
- Auto-generates PSK key
- Systemd service management
- Firewall auto-configuration (ufw / firewalld / iptables)
- Displays ss:// URI + QR code for easy client setup
- Reinstall / reconfigure and uninstall support
