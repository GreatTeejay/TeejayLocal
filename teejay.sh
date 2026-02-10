#!/bin/bash

# ==========================================
#  TEE JAY TUNNEL - PREMIUM EDITION v4
#  Stable GRE Tunnel + Auto Healing Service
# ==========================================

# --- Colors & Styles ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Paths ---
DIR="/etc/teejay-tunnel"
CONF="$DIR/config.env"
SCRIPT="$DIR/watchdog.sh"
SERVICE="/etc/systemd/system/teejay-watchdog.service"
LOG="/var/log/teejay-tunnel.log"
IFACE="tj-tun0"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}CRITICAL ERROR:${NC} Please run as root!"
    echo -e "Usage: ${YELLOW}sudo bash $0${NC}"
    exit 1
fi

# --- Pre-flight Checks (Fix Locks & Modules) ---
prepare_system() {
    # 1. Load Kernel Module for GRE
    modprobe ip_gre 2>/dev/null
    lsmod | grep grep >/dev/null 2>&1

    # 2. Fix dpkg locks
    if pgrep unattended-upgr > /dev/null; then
        killall unattended-upgr 2>/dev/null
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
    fi
    
    # 3. Create Dir
    mkdir -p "$DIR"
}

# --- Visuals ---
header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  _______ ______ ______       _       __     __"
    echo " |__   __|  ____|  ____|     | |   /\\ \\   / /"
    echo "    | |  | |__  | |__        | |  /  \\ \\_/ / "
    echo "    | |  |  __| |  __|   _   | | / /\\ \\   /  "
    echo "    | |  | |____| |____ | |__| |/ ____ \\ |   "
    echo "    |_|  |______|______| \____//_/    \\_\\|   "
    echo -e "${NC}"
    echo -e "  ${YELLOW}Stable GRE Tunnel Automation${NC}"
    echo -e "  ${BLUE}==============================================${NC}"
}

# --- IP Detection ---
get_ip() {
    local ip=$(curl -s --max-time 3 4.icanhazip.com)
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    fi
    echo "$ip"
}

# --- Setup Function ---
setup() {
    prepare_system
    header
    
    # 1. Detect Role
    echo -e "${BOLD}Select Server Location:${NC}"
    echo -e "${CYAN}1)${NC} IRAN Server"
    echo -e "${CYAN}2)${NC} KHAREJ Server"
    read -p "Choose (1/2): " role_opt

    if [[ "$role_opt" == "1" ]]; then
        ROLE="IRAN"
        MY_LOC_IP="10.10.10.1"
        PEER_LOC_IP="10.10.10.2"
        PEER_NAME="KHAREJ"
    elif [[ "$role_opt" == "2" ]]; then
        ROLE="KHAREJ"
        MY_LOC_IP="10.10.10.2"
        PEER_LOC_IP="10.10.10.1"
        PEER_NAME="IRAN"
    else
        echo -e "${RED}Invalid Option.${NC}"
        sleep 2
        return
    fi

    echo ""
    echo -e "${GREEN}>> Selected Role: ${BOLD}$ROLE${NC}"
    
    # 2. Public IPs
    CURRENT_IP=$(get_ip)
    echo -e "Detected Public IP: ${YELLOW}$CURRENT_IP${NC}"
    read -p "Is this correct? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        MY_PUB_IP=$CURRENT_IP
    else
        read -p "Enter YOUR Public IP Manually: " MY_PUB_IP
    fi
    
    echo ""
    echo -e "Enter ${CYAN}${PEER_NAME}${NC} Public IP:"
    read -p "IP: " PEER_PUB_IP
    
    if [[ -z "$PEER_PUB_IP" ]]; then
        echo -e "${RED}Error: Peer IP is required.${NC}"
        exit 1
    fi

    # 3. Save Config
    cat <<EOF > "$CONF"
ROLE="$ROLE"
MY_PUB_IP="$MY_PUB_IP"
PEER_PUB_IP="$PEER_PUB_IP"
MY_LOC_IP="$MY_LOC_IP"
PEER_LOC_IP="$PEER_LOC_IP"
PEER_NAME="$PEER_NAME"
IFACE="$IFACE"
EOF

    # 4. Apply & Install Watchdog
    install_watchdog
    
    # 5. Final Output
    header
    echo -e "${GREEN}${BOLD}✅ SETUP SUCCESSFUL!${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e " 🌍 YOU ARE:          ${YELLOW}${BOLD}${ROLE} SERVER${NC}"
    echo -e " 📍 YOUR LOCAL IP:    ${CYAN}${MY_LOC_IP}${NC}"
    echo -e " 🎯 ${PEER_NAME} LOCAL IP:  ${RED}${PEER_LOC_IP}${NC}  <-- (Use this in config)"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "Tunnel is running. Watchdog is checking connection."
    echo ""
    read -p "Press Enter to return to menu..."
}

# --- Installation & Watchdog Logic ---
install_watchdog() {
    echo -e "${YELLOW}Configuring Network & Services...${NC}"
    
    # Create the Watchdog Script
    cat <<EOF > "$SCRIPT"
#!/bin/bash
source $CONF

setup_tunnel() {
    # 1. Enable IP Forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    
    # 2. Firewall Rules (Allow GRE Protocol 47)
    iptables -I INPUT -p gre -j ACCEPT 2>/dev/null
    iptables -I OUTPUT -p gre -j ACCEPT 2>/dev/null
    
    # 3. Create Interface
    ip link set \$IFACE down 2>/dev/null
    ip tunnel del \$IFACE 2>/dev/null
    
    ip tunnel add \$IFACE mode gre local "\$MY_PUB_IP" remote "\$PEER_PUB_IP" ttl 255
    ip link set \$IFACE mtu 1400
    ip addr add "\$MY_LOC_IP/30" dev \$IFACE
    ip link set \$IFACE up
}

# Initial Setup
setup_tunnel

while true; do
    # Check Interface
    if ! ip link show \$IFACE > /dev/null 2>&1; then
        echo "\$(date) - Interface missing. Rebuilding..." >> $LOG
        setup_tunnel
    fi

    # Check Ping (Fast check: 3 packets, 1 sec wait)
    if ! ping -c 3 -W 1 "\$PEER_LOC_IP" > /dev/null 2>&1; then
        echo "\$(date) - Connection lost to \$PEER_LOC_IP. Restarting..." >> $LOG
        setup_tunnel
        echo "\$(date) - Restarted." >> $LOG
    fi
    
    # Check every 10 seconds
    sleep 10
done
EOF
    chmod +x "$SCRIPT"

    # Create Systemd Service
    cat <<EOF > "$SERVICE"
[Unit]
Description=TEE JAY Tunnel Watchdog
After=network.target network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Reload & Start
    systemctl daemon-reload
    systemctl enable teejay-watchdog >/dev/null 2>&1
    systemctl restart teejay-watchdog
}

# --- Uninstall ---
uninstall() {
    header
    echo -e "${RED}Uninstalling...${NC}"
    systemctl stop teejay-watchdog 2>/dev/null
    systemctl disable teejay-watchdog 2>/dev/null
    rm -f "$SERVICE"
    systemctl daemon-reload
    
    ip link set $IFACE down 2>/dev/null
    ip tunnel del $IFACE 2>/dev/null
    
    rm -rf "$DIR"
    echo -e "${GREEN}Done.${NC}"
    sleep 1
}

# --- Status ---
status() {
    header
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}Not configured yet.${NC}"
        read -p "Press Enter..."
        return
    fi
    source "$CONF"
    
    echo -e "${BOLD}Current Configuration:${NC}"
    echo -e "Role: ${YELLOW}$ROLE${NC}"
    echo -e "Tunnel Interface: ${CYAN}$IFACE${NC}"
    
    echo -e "\n${BOLD}Network Status:${NC}"
    if ip link show $IFACE > /dev/null 2>&1; then
         echo -e "Interface State: ${GREEN}UP${NC}"
    else
         echo -e "Interface State: ${RED}DOWN${NC}"
    fi
    
    echo -e "\n${BOLD}Connectivity Test:${NC}"
    echo -e "Pinging ${PEER_NAME} Local IP ($PEER_LOC_IP)..."
    ping -c 4 -W 1 "$PEER_LOC_IP"
    
    echo -e "\n${BOLD}Recent Logs:${NC}"
    tail -n 3 "$LOG" 2>/dev/null || echo "No logs yet."
    
    echo ""
    read -p "Press Enter..."
}

# --- Main Menu ---
while true; do
    header
    echo -e " ${CYAN}1${NC} - Setup ${BOLD}IRAN${NC} Local"
    echo -e " ${CYAN}2${NC} - Setup ${BOLD}KHAREJ${NC} Local"
    echo -e " ${CYAN}3${NC} - Automation & Watchdog Status"
    echo -e " ${CYAN}4${NC} - Status (Ping Test)"
    echo -e " ${CYAN}5${NC} - Uninstall"
    echo -e " ${CYAN}6${NC} - Exit"
    echo -e "${BLUE}==============================================${NC}"
    read -p " Select Option: " opt
    
    case $opt in
        1) setup ;; # Role logic handled inside setup
        2) setup ;; 
        3) 
           echo -e "${YELLOW}Restarting Automation Service...${NC}"
           systemctl restart teejay-watchdog
           echo -e "${GREEN}Done.${NC}"
           sleep 1
           ;;
        4) status ;;
        5) uninstall ;;
        6) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done
