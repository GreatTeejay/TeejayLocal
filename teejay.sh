#!/bin/bash

# ==========================================
#  Teejay Tunnel - NUCLEAR STABILITY EDITION
#  Mode: Systemd Service (Real-time Watchdog)
#  Fixed: dpkg locks, firewall drops, latency
# ==========================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Config Paths ---
BASE_DIR="/etc/teejay-tunnel"
CONFIG_FILE="$BASE_DIR/config"
WATCHDOG_SCRIPT="$BASE_DIR/watchdog.sh"
SERVICE_FILE="/etc/systemd/system/teejay-watchdog.service"
LOG_FILE="/var/log/teejay-tunnel.log"
TUNNEL_NAME="tj-tun0"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Run as root! (sudo bash $0)${NC}"
   exit 1
fi

# --- Kill dpkg locks if stuck ---
fix_locks() {
    if pgrep unattended-upgr > /dev/null; then
        echo -e "${YELLOW}Killing background updates to release lock...${NC}"
        killall unattended-upgr 2>/dev/null
        rm -f /var/lib/dpkg/lock-frontend 2>/dev/null
        rm -f /var/lib/dpkg/lock 2>/dev/null
    fi
}

# --- Logo ---
logo() {
    clear
    echo -e "${CYAN}"
    echo "  _______           _             "
    echo " |__   __|         (_)            "
    echo "    | | ___  ___    _  __ _ _   _ "
    echo "    | |/ _ \/ _ \  | |/ _\` | | | |"
    echo "    | |  __/  __/  | | (_| | |_| |"
    echo "    |_|\___|\___|  | |\__,_|\__, |"
    echo "                  _/ |       __/ |"
    echo "                 |__/       |___/ "
    echo -e "${NC}"
    echo -e "  ${YELLOW}NUCLEAR EDITION - ZERO DOWNTIME${NC}"
    echo "------------------------------------------------"
}

get_real_ip() {
    curl -s --max-time 3 4.icanhazip.com || ip route get 8.8.8.8 | awk '{print $7; exit}'
}

# --- Main Setup Function ---
setup_tunnel() {
    local ROLE=$1
    fix_locks
    
    mkdir -p "$BASE_DIR"
    
    logo
    echo -e "${GREEN}Setup Mode: $ROLE${NC}"
    
    # 1. IP Detection
    DETECTED_IP=$(get_real_ip)
    echo -e "Detected IP: ${CYAN}$DETECTED_IP${NC}"
    read -p "Is this your server ip? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        LOCAL_PUB=$DETECTED_IP
    else
        read -p "Enter ip manually: " LOCAL_PUB
    fi
    
    echo ""
    read -p "Write kharej/remote IP: " REMOTE_PUB
    read -p "MTU (Recommended 1300-1400 for stability): " USER_MTU
    MTU=${USER_MTU:-1400}

    # 2. Assign Internal IPs
    if [ "$ROLE" == "IRAN" ]; then
        LOC_PRIV="10.10.10.1"
        REM_PRIV="10.10.10.2"
    else
        LOC_PRIV="10.10.10.2"
        REM_PRIV="10.10.10.1"
    fi

    # 3. Save Config
    cat <<EOF > "$CONFIG_FILE"
LOCAL_PUB="$LOCAL_PUB"
REMOTE_PUB="$REMOTE_PUB"
LOC_PRIV="$LOC_PRIV"
REM_PRIV="$REM_PRIV"
MTU="$MTU"
EOF

    echo -e "${YELLOW}Configuring Network & Firewall...${NC}"
    
    # Enable Forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-teejay.conf
    sysctl -p /etc/sysctl.d/99-teejay.conf >/dev/null 2>&1

    # Apply Tunnel Immediately
    apply_tunnel_logic
    
    # Install Watchdog Service
    install_service

    echo ""
    echo -e "${GREEN}DONE! Tunnel is active and protected by Watchdog Service.${NC}"
    echo -e "Logs are at: $LOG_FILE"
    read -p "Press Enter..."
}

# --- Tunnel Application Logic (Reusable) ---
apply_tunnel_logic() {
    source "$CONFIG_FILE"
    
    # 1. Allow GRE Protocol (47) in Firewall
    if command -v ufw >/dev/null; then
        ufw allow proto gre to any >/dev/null 2>&1
    fi
    iptables -I INPUT -p gre -j ACCEPT 2>/dev/null
    
    # 2. Reset Interface
    ip link set $TUNNEL_NAME down 2>/dev/null
    ip tunnel del $TUNNEL_NAME 2>/dev/null
    
    # 3. Build Tunnel
    ip tunnel add $TUNNEL_NAME mode gre local "$LOCAL_PUB" remote "$REMOTE_PUB" ttl 255
    ip link set $TUNNEL_NAME mtu "$MTU"
    ip addr add "$LOC_PRIV/30" dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME up
}

# --- Watchdog Service Installer ---
install_service() {
    echo -e "${YELLOW}Installing Systemd Watchdog (Checks every 10s)...${NC}"

    # 1. Create the detailed watchdog script
    cat <<EOF > "$WATCHDOG_SCRIPT"
#!/bin/bash
source $CONFIG_FILE
LOG="$LOG_FILE"
TUNNEL="$TUNNEL_NAME"

while true; do
    # Check if interface exists
    if ! ip link show \$TUNNEL > /dev/null 2>&1; then
        echo "\$(date) - [CRITICAL] Interface missing. Rebuilding..." >> \$LOG
        ip tunnel add \$TUNNEL mode gre local "\$LOCAL_PUB" remote "\$REMOTE_PUB" ttl 255
        ip link set \$TUNNEL mtu "\$MTU"
        ip addr add "\$LOC_PRIV/30" dev \$TUNNEL
        ip link set \$TUNNEL up
        sleep 2
    fi

    # Ping Check (3 packets, fast timeout)
    if ! ping -c 3 -W 2 "\$REM_PRIV" > /dev/null 2>&1; then
        echo "\$(date) - [DOWN] Connection lost. Restarting tunnel..." >> \$LOG
        
        # Hard Reset
        ip link set \$TUNNEL down
        ip tunnel del \$TUNNEL
        
        ip tunnel add \$TUNNEL mode gre local "\$LOCAL_PUB" remote "\$REMOTE_PUB" ttl 255
        ip link set \$TUNNEL mtu "\$MTU"
        ip addr add "\$LOC_PRIV/30" dev \$TUNNEL
        ip link set \$TUNNEL up
        
        # Enforce Firewall again just in case
        iptables -I INPUT -p gre -j ACCEPT 2>/dev/null
        
        echo "\$(date) - [RECOVERED] Tunnel rebuilt." >> \$LOG
    else
        # Success - Do nothing (or log verbose)
        # echo "\$(date) - [OK] Heartbeat" >> \$LOG
        true
    fi
    
    # Wait 10 seconds before next check
    sleep 10
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    # 2. Create Systemd Service Unit
    cat <<SERVICE > "$SERVICE_FILE"
[Unit]
Description=Teejay Tunnel Watchdog
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SERVICE

    # 3. Enable and Start
    systemctl daemon-reload
    systemctl enable teejay-watchdog
    systemctl restart teejay-watchdog
}

# --- Uninstaller ---
uninstall() {
    echo -e "${RED}Stopping and Removing everything...${NC}"
    systemctl stop teejay-watchdog 2>/dev/null
    systemctl disable teejay-watchdog 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    ip link set $TUNNEL_NAME down 2>/dev/null
    ip tunnel del $TUNNEL_NAME 2>/dev/null
    
    rm -rf "$BASE_DIR"
    echo -e "${GREEN}Cleaned up.${NC}"
}

# --- Status ---
show_status() {
    logo
    echo -e "${CYAN}--- Service Status ---${NC}"
    systemctl status teejay-watchdog | grep "Active:"
    
    echo -e "\n${CYAN}--- Network Status ---${NC}"
    if ip link show $TUNNEL_NAME >/dev/null 2>&1; then
        echo -e "Interface: ${GREEN}UP${NC}"
        ip addr show $TUNNEL_NAME | grep "inet"
    else
        echo -e "Interface: ${RED}DOWN${NC}"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "\n${CYAN}--- Connectivity Test ---${NC}"
        ping -c 4 -W 1 "$REM_PRIV"
    fi
    
    echo -e "\n${CYAN}--- Last 5 Failure Logs ---${NC}"
    tail -n 5 "$LOG_FILE" 2>/dev/null || echo "No errors logged yet."
    
    read -p "Press Enter..."
}

# --- Menu ---
while true; do
    logo
    echo "1 - setup Iran Local"
    echo "2 - setup Kharej local"
    echo "3 - automation (Restarts Service)"
    echo "4 - status"
    echo "5 - unistall"
    echo "6 - exit"
    echo ""
    read -p "Select: " opt
    case $opt in
        1) setup_tunnel "IRAN" ;;
        2) setup_tunnel "KHAREJ" ;;
        3) 
           echo "Restarting Watchdog Service..."
           systemctl restart teejay-watchdog
           echo "Done."
           sleep 1
           ;;
        4) show_status ;;
        5) uninstall ;;
        6) exit 0 ;;
        *) echo "Invalid" ;;
    esac
done
