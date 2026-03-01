#!/usr/bin/env bash
set -Eeou pipefail

# InvestNet dVPN Node Management Script (Native Version)
# - Supports the native nested structure: ~/.investnet-dvpnx/wireguard/config.toml
# - Handles dynamic interface detection (e.g., ens5 on AWS)
# - Corrects configuration validation errors (Raw IP only for remote-addrs)

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
NODE_INTERVAL_STATUS_UPDATE="15s"

# --- Utility Functions ---
log() { echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $*"; }
err() { echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $*" >&2; }

check_deps() {
    local deps=("curl" "jq" "openssl" "ip" "wg" "wg-quick" "sed" "awk" "python3" "fuser")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            # Special check for fuser which might be in /sbin or /usr/sbin
            if [[ "$dep" == "fuser" ]] && [[ -f "/sbin/fuser" || -f "/usr/sbin/fuser" ]]; then
                continue
            fi
            err "Missing dependency: $dep. Please install it (e.g., sudo apt install psmisc)."
            exit 1
        fi
    done
}

detect_public_ip() {
    local ip
    ip=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null || true)
    # Strip protocol and port
    echo "$ip" | tr -d '[:space:]' | sed -E 's|^https?://||' | sed 's/:.*//'
}

detect_egress_interface() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$iface" ]]; then
        iface=$(ip route | awk '/^default/ {print $5; exit}')
    fi
    echo "$iface"
}

# --- Command Implementations ---

cmd_init() {
    log "Initializing InvestNet dVPN Node (Native Structure)..."
    check_deps

    # 1. Always download the latest binary from GitHub
    log "Downloading latest binary from GitHub..."
    local download_url="https://github.com/${BINARY_REPO}/releases/latest/download/${BINARY_NAME}"
    sudo curl -fsSL "$download_url" -o "$BINARY_PATH"
    sudo chmod +x "$BINARY_PATH"
    log "Binary downloaded successfully."

    local BIN="$BINARY_PATH"

    # 2. Prepare Directories
    mkdir -p "${NODE_DIR}/wireguard"

    # 3. Detect Settings
    local pub_ip
    pub_ip=$(detect_public_ip)
    if [[ -z "$pub_ip" ]]; then
        read -p "Could not auto-detect public IP. Please enter it: " pub_ip
    fi

    local moniker="node-$(openssl rand -hex 4)"
    read -p "Enter node moniker (default: $moniker): " user_moniker
    moniker="${user_moniker:-$moniker}"

    # 4. Pricing
    read -p "Enter hourly price in $DENOM (default: 1): " HOURLY_INPUT
    HOURLY_INPUT="${HOURLY_INPUT:-1}"
    HOURLY_QUOTE=$(python3 -c "print(int(${HOURLY_INPUT} * 10**18))")
    
    local gigabyte_prices="${DENOM}:20.0,20000000000000000000"
    local hourly_prices="${DENOM}:${HOURLY_INPUT},${HOURLY_QUOTE}"

    # 5. Initialize Node Config
    log "Running node init..."
    "$BIN" init \
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
        --tx.gas-prices "1000000000${DENOM}"

    # 6. Initialize Keys
    log "Initializing account keys..."
    local account_name="main"
    read -p "Enter account name (default: $account_name): " user_account
    account_name="${user_account:-$account_name}"
    "$BIN" keys add "$account_name" --home "$NODE_DIR" --keyring.backend "$KEYRING_BACKEND" --keyring.name "$KEYRING_NAME"

    # 7. Update from_name in config.toml
    if [[ -f "${NODE_DIR}/config.toml" ]]; then
        sed -i -E "s/^[[:space:]]*from_name = .*/from_name = \"${account_name}\"/" "${NODE_DIR}/config.toml"
    fi

    # 8. Generate WireGuard keys and config
    local wg_config_toml="${NODE_DIR}/wireguard/config.toml"
    log "Creating Native WireGuard service config..."
    local priv_key=$(wg genkey)
    local iface=$(detect_egress_interface)

    cat > "$wg_config_toml" <<EOF
ipv4_addr = "10.8.0.1/24"
ipv6_addr = ""
port = "${WG_PORT}"
private_key = "${priv_key}"
out_interface = "${iface}"
EOF

    log "Initialization complete!"
    echo "=========================================================="
    echo "IMPORTANT: SAVE YOUR MNEMONIC SAFELY!"
    echo "Make sure your account has balance before starting."
    echo "=========================================================="
}

cmd_start() {
    log "Starting InvestNet dVPN Node..."
    check_deps
    
    if [[ ! -f "${NODE_DIR}/config.toml" ]]; then
        err "Node not initialized. Run 'init' first."
        exit 1
    fi

    # 1. Stop service before updating files to avoid systemd warnings
    sudo systemctl stop investnet-dvpn-node.service 2>/dev/null || true
    sudo systemctl stop wg-quick@wg0 2>/dev/null || true
    sudo wg-quick down wg0 2>/dev/null || true
    sudo ip link del wg0 2>/dev/null || true

    # 2. Force free port 51820 (WireGuard)
    log "Enforcing port ${WG_PORT} for WireGuard..."
    sudo fuser -k ${WG_PORT}/udp 2>/dev/null || true

    # 3. Sync Settings
    local pub_ip=$(detect_public_ip)
    local iface=$(detect_egress_interface)

    log "Syncing configuration..."
    # Update main config (IP only)
    sed -i -E "s/^remote-addrs = .*/remote-addrs = [\"${pub_ip}\"]/" "${NODE_DIR}/config.toml"
    sed -i -E "s/^remote_addrs = .*/remote_addrs = [\"${pub_ip}\"]/" "${NODE_DIR}/config.toml"

    # Update WG service config (Port and Interface)
    if [[ -f "${NODE_DIR}/wireguard/config.toml" ]]; then
        log "Updating wireguard config with port ${WG_PORT} and interface ${iface}"
        sed -i -E "s/^port = .*/port = \"${WG_PORT}\"/" "${NODE_DIR}/wireguard/config.toml"
        sed -i -E "s/^out_interface = .*/out_interface = \"${iface}\"/" "${NODE_DIR}/wireguard/config.toml"
    fi

    # 4. Create Systemd Unit
    log "Setting up systemd service..."
    local current_user=$(whoami)
    local home_dir=$(eval echo "~$current_user")
    local BIN=$(command -v "$BINARY_NAME" || echo "$BINARY_PATH")

    sudo bash -c "cat > $SYSTEMD_UNIT" <<EOF
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

    # 5. Start Service
    sudo systemctl daemon-reload
    sudo systemctl enable investnet-dvpn-node.service
    log "Restarting service to apply configuration..."
    sudo systemctl restart investnet-dvpn-node.service

    log "Node started/restarted. Check status with './investnet-node.sh status'"
}

cmd_status() {
    sudo systemctl status investnet-dvpn-node.service --no-pager || true
    echo "--- Recent Logs ---"
    sudo journalctl -u investnet-dvpn-node.service -n 50 --no-pager
    
    # Wait a bit for the interface if it's missing (up to 5s)
    echo "--- Interface Status ---"
    local count=0
    while ! ip addr show wg0 >/dev/null 2>&1 && [ $count -lt 5 ]; do
        sleep 1
        ((count++))
    done
    sudo ip addr show wg0 2>/dev/null || echo "Interface 'wg0' not found (may still be initializing)."
    
    echo "--- WireGuard Status ---"
    sudo wg show || echo "WireGuard is not active or no interfaces found."
}

cmd_stop() {
    log "Stopping node..."
    sudo systemctl stop investnet-dvpn-node.service || true
    sudo wg-quick down wg0 2>/dev/null || true
}

cmd_uninstall() {
    read -p "Are you sure you want to uninstall everything? (y/N): " confirm
    if [[ "$confirm" != "y" ]]; then exit 0; fi

    log "Uninstalling..."
    cmd_stop
    sudo systemctl disable investnet-dvpn-node.service 2>/dev/null || true
    sudo rm -f "$SYSTEMD_UNIT"
    sudo systemctl daemon-reload
    sudo rm -rf "$NODE_DIR"
    log "Uninstalled successfully."
}

# --- Dispatcher ---
case "${1:-help}" in
    init) cmd_init ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    restart) cmd_stop; cmd_start ;;
    uninstall) cmd_uninstall ;;
    *)
        echo "Usage: $0 {init|start|stop|status|restart|uninstall}"
        exit 1
        ;;
esac
