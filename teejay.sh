#!/bin/bash

# ==========================================
#  Teejay Tunnel Script + Auto Healing
#  Simple GRE Tunnel with Ping Watchdog
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/teejay-tunnel"
CONFIG_FILE="$CONFIG_DIR/config"
WATCHDOG_FILE="$CONFIG_DIR/watchdog.sh"
LOG_FILE="/var/log/teejay-tunnel.log"
TUNNEL_NAME="tj-tun0"

mkdir -p "$CONFIG_DIR"

# --- Helper Functions ---

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
    echo -e "  ${YELLOW}Stable Local IP Tunnel Generator${NC}"
    echo -e "  ${YELLOW}Powered by Teejay Automation${NC}"
    echo "------------------------------------------------"
}

get_real_ip() {
    local ip=""
    ip=$(curl -s --max-time 3 4.icanhazip.com 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

setup_tunnel() {
    local ROLE=$1
    
    logo
    echo -e "${GREEN}Running Setup for: $ROLE${NC}"
    echo ""

    # 1. Detect and Confirm Local Public IP
    DETECTED_IP=$(get_real_ip)
    echo -e "Detected Server IP: ${CYAN}$DETECTED_IP${NC}"
    read -p "Is this your server IP? (Y/N): " confirm_ip
    
    if [[ "$confirm_ip" =~ ^[Yy]$ ]]; then
        LOCAL_PUBLIC_IP=$DETECTED_IP
    else
        read -p "Enter server IP manually: " LOCAL_PUBLIC_IP
    fi

    echo ""
    
    # 2. Get Remote Public IP
    read -p "Enter Remote (Kharej/Iran) Public IP: " REMOTE_PUBLIC_IP

    # 3. MTU Settings
    read -p "Enter MTU (Default 1436): " USER_MTU
    MTU=${USER_MTU:-1436}

    # 4. Define Local IPs based on Role
    # Iran: 192.168.100.1 <---> Kharej: 192.168.100.2
    if [ "$ROLE" == "IRAN" ]; then
        LOCAL_PRIVATE_IP="192.168.100.1"
        REMOTE_PRIVATE_IP="192.168.100.2"
    else
        LOCAL_PRIVATE_IP="192.168.100.2"
        REMOTE_PRIVATE_IP="192.168.100.1"
    fi

    echo ""
    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "Public:  $LOCAL_PUBLIC_IP <---> $REMOTE_PUBLIC_IP"
    echo -e "Local:   $LOCAL_PRIVATE_IP <---> $REMOTE_PRIVATE_IP"
    echo -e "MTU:     $MTU"
    echo ""
    read -p "Press Enter to apply..."

    # Save Config
    cat <<EOF > "$CONFIG_FILE"
LOCAL_PUBLIC_IP="$LOCAL_PUBLIC_IP"
REMOTE_PUBLIC_IP="$REMOTE_PUBLIC_IP"
LOCAL_PRIVATE_IP="$LOCAL_PRIVATE_IP"
REMOTE_PRIVATE_IP="$REMOTE_PRIVATE_IP"
MTU="$MTU"
EOF

    # Apply Tunnel
    apply_tunnel_commands
    
    # Setup Automation automatically after setup
    setup_automation_cron

    echo ""
    echo -e "${GREEN}Tunnel Setup Complete!${NC}"
    echo -e "Try pinging ${CYAN}$REMOTE_PRIVATE_IP${NC} from Status menu."
    read -p "Press Enter to return to menu..."
}

apply_tunnel_commands() {
    # Load config if exists
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo -e "${RED}No config found!${NC}"
        return
    fi

    # Clean existing
    ip link set $TUNNEL_NAME down 2>/dev/null
    ip tunnel del $TUNNEL_NAME 2>/dev/null

    # Create new
    ip tunnel add $TUNNEL_NAME mode gre local "$LOCAL_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
    ip link set $TUNNEL_NAME mtu "$MTU"
    ip addr add "$LOCAL_PRIVATE_IP/30" dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME up
    
    # Enable IP Forwarding just in case
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
}

setup_automation_cron() {
    echo -e "${YELLOW}Setting up Watchdog Automation...${NC}"

    # Create the Watchdog Script
    cat <<EOF > "$WATCHDOG_FILE"
#!/bin/bash
# Teejay Tunnel Watchdog
source $CONFIG_FILE

# Check if tunnel interface exists
if ! ip link show $TUNNEL_NAME > /dev/null 2>&1; then
    echo "\$(date) - Interface missing. Recreating..." >> $LOG_FILE
    # Re-run creation logic (We embed the commands here to be standalone)
    ip tunnel add $TUNNEL_NAME mode gre local "\$LOCAL_PUBLIC_IP" remote "\$REMOTE_PUBLIC_IP" ttl 255
    ip link set $TUNNEL_NAME mtu "\$MTU"
    ip addr add "\$LOCAL_PRIVATE_IP/30" dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME up
    exit 0
fi

# Ping check
if ! ping -c 3 -W 2 "\$REMOTE_PRIVATE_IP" > /dev/null 2>&1; then
    echo "\$(date) - Ping failed to \$REMOTE_PRIVATE_IP. Restarting tunnel..." >> $LOG_FILE
    
    # Kill and Recreate
    ip link set $TUNNEL_NAME down
    ip tunnel del $TUNNEL_NAME
    
    ip tunnel add $TUNNEL_NAME mode gre local "\$LOCAL_PUBLIC_IP" remote "\$REMOTE_PUBLIC_IP" ttl 255
    ip link set $TUNNEL_NAME mtu "\$MTU"
    ip addr add "\$LOCAL_PRIVATE_IP/30" dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME up
    
    echo "\$(date) - Tunnel recreated." >> $LOG_FILE
else
    # Ping OK - Optional: Log only on verbose
    # echo "\$(date) - Ping OK" >> $LOG_FILE
    true
fi
EOF

    chmod +x "$WATCHDOG_FILE"

    # Add to Crontab if not exists
    (crontab -l 2>/dev/null | grep -v "$WATCHDOG_FILE"; echo "* * * * * $WATCHDOG_FILE") | crontab -
    
    echo -e "${GREEN}Automation Active.${NC} Checks ping every 1 minute."
}

show_status() {
    logo
    echo -e "${YELLOW}Tunnel Status:${NC}"
    if ip link show $TUNNEL_NAME > /dev/null 2>&1; then
        echo -e "Interface: ${GREEN}UP${NC}"
        ip addr show $TUNNEL_NAME | grep "inet"
    else
        echo -e "Interface: ${RED}DOWN${NC}"
    fi
    echo ""
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "Pinging Remote ($REMOTE_PRIVATE_IP)..."
        ping -c 3 -W 1 "$REMOTE_PRIVATE_IP"
    else
        echo "No configuration found."
    fi

    echo ""
    echo -e "${YELLOW}Recent Watchdog Logs:${NC}"
    tail -n 5 "$LOG_FILE" 2>/dev/null || echo "No logs yet."
    
    echo ""
    read -p "Press Enter to continue..."
}

uninstall() {
    echo -e "${RED}Uninstalling Teejay Tunnel...${NC}"
    
    # Remove Cron
    crontab -l 2>/dev/null | grep -v "$WATCHDOG_FILE" | crontab -
    
    # Remove Interface
    ip link set $TUNNEL_NAME down 2>/dev/null
    ip tunnel del $TUNNEL_NAME 2>/dev/null
    
    # Remove Files
    rm -rf "$CONFIG_DIR"
    rm -f "$LOG_FILE"
    
    echo -e "${GREEN}Uninstalled successfully.${NC}"
    read -p "Press Enter..."
}

# --- Main Menu ---

while true; do
    logo
    echo "1 - Setup Iran Local"
    echo "2 - Setup Kharej Local"
    echo "3 - Setup Automation (Force Re-apply)"
    echo "4 - Status (Ping check & Logs)"
    echo "5 - Uninstall"
    echo "6 - Exit"
    echo ""
    read -p "Select option: " choice

    case $choice in
        1)
            setup_tunnel "IRAN"
            ;;
        2)
            setup_tunnel "KHAREJ"
            ;;
        3)
            if [ -f "$CONFIG_FILE" ]; then
                setup_automation_cron
                read -p "Automation updated. Press Enter..."
            else
                echo -e "${RED}Please setup tunnel (Option 1 or 2) first.${NC}"
                read -p "Press Enter..."
            fi
            ;;
        4)
            show_status
            ;;
        5)
            uninstall
            ;;
        6)
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            ;;
    esac
done
