#!/usr/bin/env bash
set -Eeou pipefail

# ============================================================================
# InvestNet dVPN Node
# ============================================================================
# Single script to install, initialize, start, stop, and uninstall the node.
# - Auto-installs WireGuard packages if missing
# - Downloads architecture-aware binary (amd64/arm64)
# - SDK manages its own WireGuard 
# - Handles dynamic egress interface detection
# ============================================================================

# --- Configuration Constants ---
NODE_DIR="${HOME}/.investnet-dvpnx"
BINARY_NAME="investnet-dvpnx"
BINARY_PATH="/usr/local/bin/${BINARY_NAME}"
BINARY_REPO="akshiiitt/node-local-binary"
SYSTEMD_UNIT="/etc/systemd/system/investnet-dvpn-node.service"
API_PORT=18133
WG_PORT=51820
CHAIN_RPC="https://tendermint.devnet.invest.net:443"
CHAIN_ID="investnet_7031-1"
KEYRING_BACKEND="test"
KEYRING_NAME="investnet"
DENOM="invst"

# Intervals
NODE_INTERVAL_SESSION_USAGE_SYNC_WITH_BLOCKCHAIN="540s"
NODE_INTERVAL_SESSION_VALIDATE="60s"
NODE_INTERVAL_STATUS_UPDATE="20s"

# --- Utility Functions ---
log() { echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $*"; }
err() { echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $*" >&2; }

# Ensure running as root (needed for wg-quick, systemd, iptables)
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "This script must be run as root (or with sudo)."
        exit 1
    fi
}

# Detect CPU architecture and return the binary suffix
# ONLY Raspberry Pi (ARM) is supported
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64) echo "linux-arm64" ;;
        armv7l)  echo "linux-arm64" ;;
        x86_64)  err "This script is designed for Raspberry Pi only. x86_64/amd64 architecture is not supported."; exit 1 ;;
        *)       err "Unsupported architecture: $arch. Only Raspberry Pi (ARM/ARM64) is supported."; exit 1 ;;
    esac
}

# Install WireGuard packages if not already present
install_wireguard_packages() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        log "WireGuard already installed, skipping."
        return
    fi

    log "Installing WireGuard packages..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq wireguard wireguard-tools resolvconf 2>/dev/null || \
        apt-get install -y -qq wireguard wireguard-tools 2>/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wireguard-tools
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wireguard-tools
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm wireguard-tools
    else
        err "Could not detect package manager. Please install wireguard and wireguard-tools manually."
        exit 1
    fi

    # Open UDP port in UFW if present
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${WG_PORT}/udp >/dev/null 2>&1 || true
        ufw allow ${API_PORT}/tcp >/dev/null 2>&1 || true
    fi
    # Open UDP port in firewalld if present
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port=${WG_PORT}/udp --permanent >/dev/null 2>&1 || true
        firewall-cmd --add-port=${API_PORT}/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    log "WireGuard installed successfully."
}

# Check all required dependencies are available
check_deps() {
    local deps=("curl" "openssl" "ip" "wg" "wg-quick" "sed" "awk")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            err "Missing dependency: $dep"
            exit 1
        fi
    done
}

detect_public_ip() {
    local ip
    ip=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || \
         curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null || \
         curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)
    echo "$ip" | tr -d '[:space:]' | sed -E 's|^https?://||'
}

detect_egress_interface() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    fi
    if [[ -z "$iface" ]]; then
        iface=$(ip route | awk '/^default/ {print $5; exit}')
    fi
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route | awk '/^default/ {print $5; exit}')
    fi
    echo "$iface"
}

enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    # Persist for reboots
    if [[ ! -f /etc/sysctl.d/99-investnet-vpn.conf ]]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-investnet-vpn.conf
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-investnet-vpn.conf
        sysctl --system >/dev/null 2>&1 || true
    else
        if ! grep -q "net.ipv6.conf.all.forwarding" /etc/sysctl.d/99-investnet-vpn.conf; then
            echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-investnet-vpn.conf
            sysctl --system >/dev/null 2>&1 || true
        fi
    fi
}

# Download the latest binary for the correct architecture
download_binary() {
    local arch_suffix
    arch_suffix=$(detect_arch)

    log "Detected architecture: ${arch_suffix}"
    log "Downloading latest binary from GitHub..."

    local download_url="https://github.com/${BINARY_REPO}/releases/latest/download/${BINARY_NAME}-${arch_suffix}"

    # Download ARM binary directly to location (Raspberry Pi only)
    if curl -fSL --connect-timeout 15 --max-time 300 "$download_url" -o "$BINARY_PATH" 2>&1; then
        chmod +x "$BINARY_PATH"
        log "Downloaded Raspberry Pi binary (${arch_suffix})."
        log "Binary installed at ${BINARY_PATH}"
    else
        rm -f "$BINARY_PATH"
        err "Failed to download Raspberry Pi binary from GitHub. Check your internet connection."
        exit 1
    fi
}

# --- Command Implementations ---

cmd_init() {
    log "Initializing InvestNet dVPN Node..."
    check_root

    # 1. Install WireGuard if needed
    install_wireguard_packages
    check_deps

    # 2. Download latest binary
    download_binary

    # 3. Prepare Directories
    mkdir -p "${NODE_DIR}/wireguard"

    # 4. Detect Settings
    local pub_ip
    pub_ip=$(detect_public_ip)
    if [[ -z "$pub_ip" ]]; then
        read -p "Could not auto-detect public IP. Please enter it: " pub_ip
    fi
    log "Detected public IP: ${pub_ip}"

    local moniker="node-$(openssl rand -hex 4)"
    read -p "Enter node moniker (default: $moniker): " user_moniker
    moniker="${user_moniker:-$moniker}"

    # 5. Pricing (integer only, min 1, max 6 digits)
    while true; do
        read -p "Enter hourly price in $DENOM (min: 1, max: 999999, default: 1): " HOURLY_INPUT
        HOURLY_INPUT="${HOURLY_INPUT:-1}"
        
        # Check if it's a valid integer with no decimals
        if ! [[ "$HOURLY_INPUT" =~ ^[0-9]+$ ]]; then
            err "Invalid input: must be a whole number (no decimals, no letters)"
            continue
        fi
        
        # Check if it's within range (1 to 999999)
        if [[ "$HOURLY_INPUT" -lt 1 ]]; then
            err "Price too low: minimum is 1 $DENOM"
            continue
        fi
        
        if [[ "$HOURLY_INPUT" -gt 999999 ]]; then
            err "Price too high: maximum is 999999 $DENOM (6 digits)"
            continue
        fi
        
        # Valid input, break the loop
        log "Hourly price set to: $HOURLY_INPUT $DENOM"
        break
    done
    # Calculate token amount (multiply by 10^18) without python3
    local HOURLY_QUOTE="${HOURLY_INPUT}000000000000000000"

    local gigabyte_prices="${DENOM}:20.0,20000000000000000000"
    local hourly_prices="${DENOM}:${HOURLY_INPUT},${HOURLY_QUOTE}"

    # 6. Enable IP forwarding (persisted)
    enable_ip_forward

    # 7. Initialize Node Config
    log "Running node init..."
    "$BINARY_PATH" init \
        --force \
        --home "$NODE_DIR" \
        --node.moniker "$moniker" \
        --node.api-port "$API_PORT" \
        --node.remote-addrs "${pub_ip}" \
        --node.service-type "wireguard" \
        --node.gigabyte-prices "$gigabyte_prices" \
        --node.hourly-prices "$hourly_prices" \
        --rpc.addrs "$CHAIN_RPC" \
        --rpc.chain-id "$CHAIN_ID" \
        --keyring.backend "$KEYRING_BACKEND" \
        --keyring.name "$KEYRING_NAME" \
        --node.interval-session-usage-sync-with-blockchain "$NODE_INTERVAL_SESSION_USAGE_SYNC_WITH_BLOCKCHAIN" \
        --node.interval-session-validate "$NODE_INTERVAL_SESSION_VALIDATE" \
        --node.interval-status-update "$NODE_INTERVAL_STATUS_UPDATE" \
        --tx.gas-prices "1000000invst" \
        --tx.gas-adjustment "1.6"

    # 8. Initialize Keys
    log "Initializing account keys..."
    local account_name="main"
    read -p "Enter account name (default: $account_name): " user_account
    account_name="${user_account:-$account_name}"
    "$BINARY_PATH" keys add "$account_name" --home "$NODE_DIR" --keyring.backend "$KEYRING_BACKEND" --keyring.name "$KEYRING_NAME"

    # 9. Update from_name in config.toml
    if [[ -f "${NODE_DIR}/config.toml" ]]; then
        sed -i -E "s/^[[:space:]]*from_name = .*/from_name = \"${account_name}\"/" "${NODE_DIR}/config.toml"
    fi

    # 10. (Removed) The SDK automatically generates WireGuard keys and config
    # during the node run / setup phase.

    log "Initialization complete!"
    echo ""
    echo "=========================================================================="
    echo "  IMPORTANT: SAVE YOUR MNEMONIC SAFELY!"
    echo "  Make sure your account has balance before running: $0 start"
    echo "=========================================================================="
}

cmd_start() {
    log "Starting InvestNet dVPN Node..."
    check_root

    if [[ ! -f "${NODE_DIR}/config.toml" ]]; then
        err "Node not initialized. Run '$0 init' first."
        exit 1
    fi

    # 1. Clean up any existing systemd instances
    systemctl stop investnet-dvpn-node.service 2>/dev/null || true

    # 2. Free WireGuard port
    log "Enforcing port ${WG_PORT} for WireGuard..."
    fuser -k ${WG_PORT}/udp 2>/dev/null || true

    # 3. Ensure IP forwarding is enabled
    enable_ip_forward

    # 4. Sync Settings (public IP and egress interface may change)
    local pub_ip=$(detect_public_ip)
    local iface=$(detect_egress_interface)

    log "Syncing configuration (IP: ${pub_ip}, interface: ${iface})..."
    sed -i -E "s/^[[:space:]]*remote-addrs[[:space:]]*=.*/remote-addrs = [\"${pub_ip}\"]/" "${NODE_DIR}/config.toml" 2>/dev/null || true
    sed -i -E "s/^[[:space:]]*remote_addrs[[:space:]]*=.*/remote_addrs = [\"${pub_ip}\"]/" "${NODE_DIR}/config.toml" 2>/dev/null || true

    # Update WG service config with the correct interface
    if [[ -f "${NODE_DIR}/wireguard/config.toml" ]]; then
        sed -i -E "s/^[[:space:]]*out_interface[[:space:]]*=.*/out_interface = \"${iface}\"/" "${NODE_DIR}/wireguard/config.toml"
    fi

    # 5. Create Systemd Unit
    log "Setting up systemd service..."
    local home_dir
    home_dir=$(eval echo "~$(logname 2>/dev/null || whoami)")
    local BIN=$(command -v "$BINARY_NAME" 2>/dev/null || echo "$BINARY_PATH")

    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=InvestNet dVPN Node
After=network-online.target
Wants=network-online.target

[Service]
User=root
Type=simple
ExecStart=${BIN} start --home ${NODE_DIR} --keyring.backend ${KEYRING_BACKEND} --keyring.name ${KEYRING_NAME}
Restart=always
RestartSec=10
LimitNOFILE=65536
Environment=HOME=${home_dir}

[Install]
WantedBy=multi-user.target
EOF

    # 6. Start Service
    systemctl daemon-reload
    systemctl enable investnet-dvpn-node.service >/dev/null 2>&1
    log "Starting service..."
    systemctl restart investnet-dvpn-node.service

    log "Node started. Check status with: $0 status"
}

cmd_status() {
    echo "=== Service Status ==="
    systemctl status investnet-dvpn-node.service --no-pager 2>/dev/null || echo "Service not found."

    echo ""
    echo "=== Recent Logs ==="
    journalctl -u investnet-dvpn-node.service -n 30 --no-pager 2>/dev/null || true

    echo ""
    echo "=== WireGuard Interface ==="
    local count=0
    while ! ip addr show wg0 >/dev/null 2>&1 && [[ $count -lt 3 ]]; do
        sleep 1
        ((count++))
    done
    ip addr show wg0 2>/dev/null || echo "Interface 'wg0' not found (may still be initializing)."

    echo ""
    echo "=== WireGuard Peers ==="
    wg show 2>/dev/null || echo "WireGuard is not active."

    echo ""
    echo "=== IP Forwarding ==="
    sysctl net.ipv4.ip_forward 2>/dev/null || true

    echo ""
    echo "=== NAT Rules ==="
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "MASQUERADE|Chain" || echo "No NAT rules found."
}

cmd_stop() {
    log "Stopping node..."
    check_root
    systemctl stop investnet-dvpn-node.service 2>/dev/null || true
    wg-quick down wg0 2>/dev/null || true
    log "Node stopped."
}

cmd_uninstall() {
    check_root
    read -p "Are you sure you want to uninstall the node and all data? (y/N): " confirm
    if [[ "$confirm" != "y" ]]; then exit 0; fi

    log "Uninstalling InvestNet dVPN Node..."

    # 1. Stop everything
    cmd_stop

    # 2. Disable and remove systemd service
    systemctl disable investnet-dvpn-node.service 2>/dev/null || true
    rm -f "$SYSTEMD_UNIT"
    systemctl daemon-reload

    # 3. Clean up WireGuard interface
    ip link del wg0 2>/dev/null || true

    # 4. Clean up iptables rules
    local iface=$(detect_egress_interface)
    iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || true
    ip6tables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i wg0 -o ${iface} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${iface} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o ${iface} -j MASQUERADE 2>/dev/null || true
    ip6tables -D FORWARD -i wg0 -o ${iface} -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -i ${iface} -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -o ${iface} -j MASQUERADE 2>/dev/null || true

    # 5. Clean up nftables
    nft delete rule ip wg-nat POSTROUTING oifname "${iface}" masquerade 2>/dev/null || true
    nft list chains ip wg-nat >/dev/null 2>&1 && nft flush chain ip wg-nat POSTROUTING 2>/dev/null || true
    nft list tables ip 2>/dev/null | grep -q wg-nat && nft delete table ip wg-nat 2>/dev/null || true

    # 6. Revert DNS
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl revert wg0 2>/dev/null || true
    fi

    # 7. Close firewall ports
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow ${WG_PORT}/udp 2>/dev/null || true
        ufw delete allow ${API_PORT}/tcp 2>/dev/null || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --remove-port=${WG_PORT}/udp --permanent 2>/dev/null || true
        firewall-cmd --remove-port=${API_PORT}/tcp --permanent 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi

    # 8. Remove node data
    rm -rf "$NODE_DIR"

    # 9. Remove binary
    rm -f "$BINARY_PATH"

    # 10. Remove sysctl config
    rm -f /etc/sysctl.d/99-investnet-vpn.conf
    sysctl --system >/dev/null 2>&1 || true

    log "Uninstalled successfully. WireGuard packages are left installed."
}

cmd_help() {
    echo ""
    echo "InvestNet dVPN Node Management"
    echo ""
    echo "Usage: $0 {init|start|stop|restart|status|uninstall}"
    echo ""
    echo "Commands:"
    echo "  init        Install dependencies, download binary, and initialize the node"
    echo "  start       Start the node (creates systemd service)"
    echo "  stop        Stop the node"
    echo "  restart     Restart the node"
    echo "  status      Show node status, logs, WireGuard info, and NAT rules"
    echo "  uninstall   Stop node, remove service, data, and binary"
    echo ""
}

# --- Dispatcher ---
case "${1:-help}" in
    init)      cmd_init ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    status)    cmd_status ;;
    restart)   cmd_stop; cmd_start ;;
    uninstall) cmd_uninstall ;;
    *)         cmd_help ;;
esac
