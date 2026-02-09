#!/bin/bash

# Logo
show_logo() {
    clear
    echo -e "\e[36m"
    echo "  _______     _             "
    echo " |__   __|   (_)            "
    echo "    | | ___  _  __ _ _   _  "
    echo "    | |/ _ \| |/ _\` | | | | "
    echo "    | |  __/| | (_| | |_| | "
    echo "    |_|\___|| |\__,_|\__, | "
    echo "           _/ |       __/ | "
    echo "          |__/       |___/  "
    echo -e "\e[0m"
    echo -e "\e[1;33m  --- Local IP Management --- \e[0m"
    echo ""
}

# Variables
TUNNEL_NAME="teejay_tun"
MONITOR_SCRIPT="/usr/local/bin/teejay_watchdog.sh"

# Function to detect Local IP
get_local_ip() {
    hostname -I | awk '{print $1}'
}

# Setup Iran
setup_iran() {
    local_ip=$(get_local_ip)
    echo -e "Your Server IP is: \e[32m$local_ip\e[0m"
    read -p "Is this your server IP? (Y/N): " check_ip
    if [[ "$check_ip" =~ ^[Nn]$ ]]; then
        read -p "Enter IP manually: " local_ip
    fi

    read -p "Enter Kharej (Remote) IP: " remote_ip
    read -p "Enter MTU (Recommended 1450): " mtu
    mtu=${mtu:-1450}

    # Commands
    ip tunnel add $TUNNEL_NAME mode ipip remote $remote_ip local $local_ip
    ip addr add 10.0.0.1/30 dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME mtu $mtu
    ip link set $TUNNEL_NAME up

    echo -e "\e[32mIran Local Setup Completed! (Internal IP: 10.0.0.1)\e[0m"
    sleep 2
}

# Setup Kharej
setup_kharej() {
    local_ip=$(get_local_ip)
    echo -e "Your Server IP is: \e[32m$local_ip\e[0m"
    read -p "Is this your server IP? (Y/N): " check_ip
    if [[ "$check_ip" =~ ^[Nn]$ ]]; then
        read -p "Enter IP manually: " local_ip
    fi

    read -p "Enter Iran (Remote) IP: " remote_ip
    read -p "Enter MTU (Recommended 1450): " mtu
    mtu=${mtu:-1450}

    # Commands
    ip tunnel add $TUNNEL_NAME mode ipip remote $remote_ip local $local_ip
    ip addr add 10.0.0.2/30 dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME mtu $mtu
    ip link set $TUNNEL_NAME up

    echo -e "\e[32mKharej Local Setup Completed! (Internal IP: 10.0.0.2)\e[0m"
    sleep 2
}

# Automation / Watchdog
setup_automation() {
    echo "Creating Watchdog Service..."
    read -p "Enter Remote Internal IP to monitor (e.g. 10.0.0.1 or 10.0.0.2): " target_ping
    
    cat <<EOF > $MONITOR_SCRIPT
#!/bin/bash
# Teejay Watchdog
ping -c 3 $target_ping > /dev/null
if [ \$? -ne 0 ]; then
    echo "Ping lost! Recreating tunnel..."
    # Get current config
    REMOTE=\$(ip -d tunnel show $TUNNEL_NAME | grep -oP 'remote \K\S+')
    LOCAL=\$(ip -d tunnel show $TUNNEL_NAME | grep -oP 'local \K\S+')
    ADDR=\$(ip addr show $TUNNEL_NAME | grep -oP 'inet \K\S+')
    MTU=\$(ip link show $TUNNEL_NAME | grep -oP 'mtu \K\S+')

    ip tunnel del $TUNNEL_NAME
    ip tunnel add $TUNNEL_NAME mode ipip remote \$REMOTE local \$LOCAL
    ip addr add \$ADDR dev $TUNNEL_NAME
    ip link set $TUNNEL_NAME mtu \$MTU
    ip link set $TUNNEL_NAME up
fi
EOF
    chmod +x $MONITOR_SCRIPT
    
    # Add to crontab (every 1 minute)
    (crontab -l 2>/dev/null; echo "* * * * * $MONITOR_SCRIPT") | crontab -
    echo -e "\e[32mAutomation is active! Checking every 1 minute.\e[0m"
    sleep 2
}

# Status
show_status() {
    echo -e "\e[1;34m--- Interface Status ---\e[0m"
    ip addr show $TUNNEL_NAME 2>/dev/null || echo "Tunnel is offline."
    echo -e "\n\e[1;34m--- Ping Test ---\e[0m"
    read -p "Enter internal IP to test ping: " test_ip
    ping -c 4 $test_ip
    read -p "Press enter to return..."
}

# Uninstall
uninstall() {
    ip tunnel del $TUNNEL_NAME 2>/dev/null
    crontab -l | grep -v "$MONITOR_SCRIPT" | crontab -
    rm -f $MONITOR_SCRIPT
    echo -e "\e[31mAll settings removed.\e[0m"
    sleep 2
}

# Main Menu
while true; do
    show_logo
    echo "1 - Setup Iran Local"
    echo "2 - Setup Kharej Local"
    echo "3 - Automation (Monitor & Auto-fix)"
    echo "4 - Status (Ping & Config)"
    echo "5 - Uninstall"
    echo "6 - Exit"
    echo ""
    read -p "Select an option: " opt

    case $opt in
        1) setup_iran ;;
        2) setup_kharej ;;
        3) setup_automation ;;
        4) show_status ;;
        5) uninstall ;;
        6) exit ;;
        *) echo "Invalid option" ;;
    esac
done
