#!/bin/bash

# ==========================================
#  TEE JAY TUNNEL - MASTERPIECE EDITION
#  High Stability + Professional UI
# ==========================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# --- Config ---
DIR="/etc/teejay-tunnel"
CONF="$DIR/config.env"
WATCHDOG="$DIR/watchdog.sh"
SERVICE="/etc/systemd/system/teejay-service.service"
LOG="/var/log/teejay.log"
IFACE="tj-tun0"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Please run as root!${NC}"
    exit 1
fi

# --- Helper: Draw Lines ---
line() {
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

box_top() {
    echo -e "${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
}

box_bot() {
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
}

# --- System Prep ---
prepare_sys() {
    mkdir -p "$DIR"
    modprobe ip_gre 2>/dev/null
    if pgrep unattended-upgr > /dev/null; then
        killall unattended-upgr 2>/dev/null
        rm -f /var/lib/dpkg/lock* 2>/dev/null
    fi
}

# --- Visuals ---
logo() {
    clear
    echo -e "${CYAN}"
    echo "████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗"
    echo "╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝"
    echo "   ██║   █████╗  █████╗       ██║███████║ ╚████╔╝ "
    echo "   ██║   ██╔══╝  ██╔══╝  ██   ██║██╔══██║  ╚██╔╝  "
    echo "   ██║   ███████╗███████╗╚█████╔╝██║  ██║   ██║   "
    echo "   ╚═╝   ╚══════╝╚══════╝ ╚════╝ ╚═╝  ╚═╝   ╚═╝   "
    echo -e "${NC}"
    echo -e "      ${YELLOW}⚡ STABLE TUNNEL AUTOMATION SYSTEM ⚡${NC}"
    line
}

# --- Get IP ---
get_ip() {
    local ip=$(curl -s --max-time 3 4.icanhazip.com)
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    fi
    echo "$ip"
}

# --- Setup Logic ---
setup_tunnel() {
    local ROLE_INPUT=$1
    prepare_sys
    logo

    # 1. Mode Selection
    if [[ "$ROLE_INPUT" == "IRAN" ]]; then
        ROLE="IRAN"
        MY_LOC="10.10.10.1"
        PEER_LOC="10.10.10.2"
        PEER_NAME="KHAREJ"
        ICON="🇮🇷"
    else
        ROLE="KHAREJ"
        MY_LOC="10.10.10.2"
        PEER_LOC="10.10.10.1"
        PEER_NAME="IRAN"
        ICON="🌍"
    fi

    echo -e "${WHITE}  SELECTED MODE: ${GREEN}${ICON} $ROLE SERVER${NC}"
    echo -e "${PURPLE}──────────────────────────────────────────────────────────────${NC}"
    
    # 2. IP Config
    CURRENT_IP=$(get_ip)
    echo -e "  ${CYAN}[1]${NC} Detected IP: ${WHITE}$CURRENT_IP${NC}"
    read -p "      Is this correct? (y/n): " confirm_ip
    if [[ "$confirm_ip" =~ ^[Yy]$ ]]; then
        MY_PUB=$CURRENT_IP
    else
        read -p "      Enter Manual IP: " MY_PUB
    fi
    echo ""
    
    echo -e "  ${CYAN}[2]${NC} Enter ${YELLOW}${PEER_NAME}${NC} Public IP:"
    read -p "      IP Address: " PEER_PUB
    echo ""

    echo -e "  ${CYAN}[3]${NC} Enter MTU (Default 1300):"
    read -p "      Value: " USER_MTU
    MTU=${USER_MTU:-1300}

    # 3. Save Config
    cat <<EOF > "$CONF"
ROLE="$ROLE"
MY_PUB="$MY_PUB"
PEER_PUB="$PEER_PUB"
MY_LOC="$MY_LOC"
PEER_LOC="$PEER_LOC"
MTU="$MTU"
IFACE="$IFACE"
EOF

    # 4. Install Service
    install_service

    # 5. Final Output Table
    logo
    echo -e "${GREEN}  ✅ CONFIGURATION SUCCESSFUL!${NC}"
    echo ""
    box_top
    echo -e "${PURPLE}║${NC}  ${WHITE}ROLE          ${NC}│  ${YELLOW}${ROLE} SERVER${NC} ${ICON}                   ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${WHITE}PUBLIC IP     ${NC}│  ${CYAN}${MY_PUB}${NC}               ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${WHITE}LOCAL IP      ${NC}│  ${GREEN}${MY_LOC}${NC}                 ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${WHITE}PEER LOCAL IP ${NC}│  ${RED}${PEER_LOC}${NC} (Target)          ${PURPLE}║${NC}"
    box_bot
    echo ""
    echo -e "  ${CYAN}➜ Watchdog Service:${NC} ${GREEN}ACTIVE${NC} (Checks ping every 5s)"
    echo ""
    read -p "  Press Enter to return..."
}

# --- Service Installer ---
install_service() {
    echo -e "${PURPLE}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ⚙️  Installing Automation Service..."
    
    cat <<EOF > "$WATCHDOG"
#!/bin/bash
source $CONF

build_tunnel() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.\$IFACE.rp_filter=0 >/dev/null 2>&1
    
    ip link set \$IFACE down 2>/dev/null
    ip tunnel del \$IFACE 2>/dev/null
    
    ip tunnel add \$IFACE mode gre local "\$MY_PUB" remote "\$PEER_PUB" ttl 255
    ip link set \$IFACE mtu \$MTU
    ip addr add "\$MY_LOC/30" dev \$IFACE
    ip link set \$IFACE up
    
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o \$IFACE -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

while true; do
    if ! ip link show \$IFACE > /dev/null 2>&1; then
        echo "\$(date) - Interface missing. Rebuilding..." >> $LOG
        build_tunnel
    fi

    if ! ping -c 3 -W 2 "\$PEER_LOC" > /dev/null 2>&1; then
        echo "\$(date) - Connection lost. Rebuilding..." >> $LOG
        build_tunnel
    fi
    sleep 5
done
EOF
    chmod +x "$WATCHDOG"

    cat <<EOF > "$SERVICE"
[Unit]
Description=TEE JAY Tunnel Service
After=network.target network-online.target

[Service]
Type=simple
ExecStart=$WATCHDOG
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable teejay-service >/dev/null 2>&1
    systemctl restart teejay-service
}

# --- Uninstall ---
uninstall() {
    echo -e "${RED}  Uninstalling Service...${NC}"
    systemctl stop teejay-service 2>/dev/null
    systemctl disable teejay-service 2>/dev/null
    rm -f "$SERVICE"
    systemctl daemon-reload
    ip link set $IFACE down 2>/dev/null
    ip tunnel del $IFACE 2>/dev/null
    rm -rf "$DIR"
    echo -e "${GREEN}  System Cleaned.${NC}"
    sleep 1
}

# --- Status ---
show_status() {
    logo
    if [[ ! -f "$CONF" ]]; then
        echo -e "${RED}  ⚠️  Not Configured Yet.${NC}"
        read -p "  Press Enter..."
        return
    fi
    source "$CONF"
    
    echo -e "${WHITE}  STATUS REPORT:${NC}"
    box_top
    
    if ip link show $IFACE >/dev/null 2>&1; then
        echo -e "${PURPLE}║${NC}  INTERFACE     │  ${GREEN}● UP${NC}                       ${PURPLE}║${NC}"
    else
        echo -e "${PURPLE}║${NC}  INTERFACE     │  ${RED}● DOWN${NC}                     ${PURPLE}║${NC}"
    fi
    
    if systemctl is-active --quiet teejay-service; then
        echo -e "${PURPLE}║${NC}  WATCHDOG      │  ${GREEN}● RUNNING${NC}                  ${PURPLE}║${NC}"
    else
        echo -e "${PURPLE}║${NC}  WATCHDOG      │  ${RED}● STOPPED${NC}                  ${PURPLE}║${NC}"
    fi
    
    box_bot
    echo ""
    echo -e "  ${CYAN}Ping Test (${PEER_LOC}):${NC}"
    ping -c 3 -W 1 "$PEER_LOC"
    echo ""
    read -p "  Press Enter..."
}

# --- Main Menu ---
while true; do
    logo
    echo -e "${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC}  ${CYAN}1${NC} » Setup ${WHITE}IRAN${NC} Server   🇮🇷                             ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${CYAN}2${NC} » Setup ${WHITE}KHAREJ${NC} Server 🌍                             ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${CYAN}3${NC} » Service ${YELLOW}RESTART${NC} (Force Update)                      ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${CYAN}4${NC} » Check ${GREEN}STATUS${NC} (Ping)                                 ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${CYAN}5${NC} » ${RED}UNINSTALL${NC}                                            ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC}  ${CYAN}6${NC} » ${WHITE}EXIT${NC}                                                 ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "  Select Option: " opt
    
    case $opt in
        1) setup_tunnel "IRAN" ;;
        2) setup_tunnel "KHAREJ" ;;
        3) 
           echo -e "  ${YELLOW}Restarting Service...${NC}"
           systemctl restart teejay-service
           echo -e "  ${GREEN}Done.${NC}"
           sleep 1
           ;;
        4) show_status ;;
        5) uninstall ;;
        6) exit 0 ;;
        *) echo "  Invalid option." ;;
    esac
done
