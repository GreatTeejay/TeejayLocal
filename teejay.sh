#!/usr/bin/env bash
#
# TEEJAY TUNNEL MANAGER v3.0 (Fixed & Stable)
#

set +e
set +u
export LC_ALL=C

# --- CONFIGS ---
LOG_MAX=10
LOG_LINES=()

# --- UTILS & UI ---
banner() {
  cat <<'EOF'
╔═════════════════════════════════════════════════════╗
║                                                     ║
║   ████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗║
║   ╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝║
║      ██║   █████╗  █████╗       ██║███████║ ╚████╔╝ ║
║      ██║   ██╔══╝  ██╔══╝  ██   ██║██╔══██║  ╚██╔╝  ║
║      ██║   ███████╗███████╗╚█████╔╝██║  ██║   ██║   ║
║      ╚═╝   ╚══════╝╚══════╝ ╚════╝ ╚═╝  ╚═╝   ╚═╝   ║
║                                                     ║
║           FIXED EDITION  |  NO BUGS                 ║
╚═════════════════════════════════════════════════════╝
EOF
}

add_log() {
  local msg="$1"
  local ts
  ts="$(date +"%H:%M:%S")"
  LOG_LINES+=("[$ts] $msg")
  if ((${#LOG_LINES[@]} > LOG_MAX)); then
    LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
  fi
}

render() {
  clear
  banner
  echo
  local shown_count="${#LOG_LINES[@]}"
  local height=$shown_count
  ((height < 3)) && height=3
  ((height > LOG_MAX)) && height=$LOG_MAX

  echo "┌───────────────────────────── ACTION LOG ─────────────────────────────┐"
  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    printf "│ %-68s │\n" "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-68s │\n" ""
  done

  echo "└──────────────────────────────────────────────────────────────────────┘"
  echo
}

pause_enter() {
  echo
  read -r -p "Press ENTER to return to menu..." _
}

die() {
  add_log "ERROR: $1"
  render
  echo "Critical Error: $1"
  exit 1
}

# --- VALIDATORS (FIXED) ---

# Simple trim function
trim() {
    local var="$*"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

is_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

valid_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then return 1; fi
        done
        return 0
    else
        return 1
    fi
}

valid_gre_base() {
    local ip="$1"
    valid_ipv4 "$ip" || return 1
    [[ "$ip" =~ \.0$ ]] || return 1
    return 0
}

valid_mtu() {
    local m="$1"
    # Pure integer check without complex regex if possible
    if [[ "$m" =~ ^[0-9]+$ ]]; then
        if ((m >= 576 && m <= 1600)); then
            return 0
        fi
    fi
    return 1
}

valid_port() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        if ((p >= 1 && p <= 65535)); then
            return 0
        fi
    fi
    return 1
}

# --- HELPERS ---

get_public_ip() {
    local ip
    ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 3 http://ifconfig.me)
    fi
    echo "$ip"
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}

# --- INPUT HANDLERS ---

ask_val() {
    local prompt="$1"
    local validator="$2"
    local output_var="$3"
    local answer

    while true; do
        render
        read -r -e -p "$prompt " answer
        answer=$(trim "$answer")

        if [[ -z "$answer" ]]; then
            add_log "Input cannot be empty."
            continue
        fi

        if $validator "$answer"; then
            printf -v "$output_var" "%s" "$answer"
            add_log "OK: $answer"
            return 0
        else
            add_log "Invalid input: $answer"
            sleep 1
        fi
    done
}

ask_ip_smart() {
    local type="$1" # IRAN or KHAREJ
    local output_var="$2"
    local detected
    local confirm

    detected=$(get_public_ip)

    if valid_ipv4 "$detected"; then
        while true; do
            render
            echo "Detected Public IP: $detected"
            read -r -p "Is this your $type IP? (y/n): " confirm
            confirm=$(trim "$confirm")
            case "${confirm,,}" in
                y|yes)
                    printf -v "$output_var" "%s" "$detected"
                    add_log "Set IP: $detected"
                    return 0
                    ;;
                n|no)
                    ask_val "Enter $type IP manually:" valid_ipv4 "$output_var"
                    return 0
                    ;;
                *)
                    add_log "Please enter 'y' or 'n'."
                    ;;
            esac
        done
    else
        add_log "Could not detect IP automatically."
        ask_val "Enter $type IP manually:" valid_ipv4 "$output_var"
    fi
}

ask_ports_smart() {
    local raw
    while true; do
        render
        echo "Example: 443 OR 2083,8443 OR 2050-2060"
        read -r -e -p "Forward Ports: " raw
        raw=$(trim "$raw")
        
        if [[ -z "$raw" ]]; then continue; fi
        
        # Simple parsing
        local -a p_list=()
        local valid=1
        
        # Replace commas with spaces
        local clean="${raw//,/ }"
        
        for item in $clean; do
            if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local s="${BASH_REMATCH[1]}"
                local e="${BASH_REMATCH[2]}"
                if ((s <= e)) && valid_port "$s" && valid_port "$e"; then
                    for ((k=s; k<=e; k++)); do p_list+=("$k"); done
                else
                    valid=0
                fi
            elif valid_port "$item"; then
                p_list+=("$item")
            else
                valid=0
            fi
        done
        
        if ((valid == 1)) && ((${#p_list[@]} > 0)); then
            mapfile -t PORT_LIST < <(printf "%s\n" "${p_list[@]}" | sort -n | uniq)
            add_log "Ports OK: ${#PORT_LIST[@]} ports selected."
            return 0
        else
            add_log "Invalid port format."
            sleep 1
        fi
    done
}

# --- CORE FUNCTIONS ---

install_deps() {
    add_log "Checking dependencies..."
    local need_install=0
    command -v ip >/dev/null 2>&1 || need_install=1
    command -v socat >/dev/null 2>&1 || need_install=1
    
    if ((need_install == 1)); then
        render
        echo "Installing iproute2 & socat..."
        apt-get update -y >/dev/null 2>&1
        apt-get install -y iproute2 socat >/dev/null 2>&1
    fi
}

setup_tunnel_only() {
    local mode="$1" # IRAN or KHAREJ
    
    local ID LOCAL_IP REMOTE_IP GRE_RANGE MTU_VAL="1476"
    
    ask_val "Enter GRE ID (Number):" is_int ID
    
    if [[ "$mode" == "IRAN" ]]; then
        ask_ip_smart "IRAN (Local)" LOCAL_IP
        ask_val "Enter KHAREJ (Remote) IP:" valid_ipv4 REMOTE_IP
    else
        ask_ip_smart "KHAREJ (Local)" LOCAL_IP
        ask_val "Enter IRAN (Remote) IP:" valid_ipv4 REMOTE_IP
    fi
    
    ask_val "GRE Range (e.g., 10.10.10.0):" valid_gre_base GRE_RANGE
    
    # MTU Question
    while true; do
        render
        read -r -p "Set custom MTU? Default is 1476. (y/n): " ans
        case "${ans,,}" in
            y|yes)
                ask_val "Enter MTU (576-1600):" valid_mtu MTU_VAL
                break
                ;;
            n|no|"")
                break
                ;;
        esac
    done

    # Logic
    local gre_local_ip gre_peer_ip
    if [[ "$mode" == "IRAN" ]]; then
        gre_local_ip=$(ipv4_set_last_octet "$GRE_RANGE" 1)
        gre_peer_ip=$(ipv4_set_last_octet "$GRE_RANGE" 2)
    else
        gre_local_ip=$(ipv4_set_last_octet "$GRE_RANGE" 2)
        gre_peer_ip=$(ipv4_set_last_octet "$GRE_RANGE" 1)
    fi
    
    local key=$((ID * 100))
    local unit="gre${ID}.service"
    
    install_deps
    
    add_log "Configuring Service..."
    
    # Create Systemd Unit
    cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=TEEJAY GRE Tunnel ${ID}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# CLEANUP
ExecStart=-/sbin/ip tunnel del gre${ID}
# CREATE - tunnel mode gre local IP
ExecStart=/sbin/ip tunnel add gre${ID} mode gre local ${LOCAL_IP} remote ${REMOTE_IP} key ${key} nopmtudisc
# IP ASSIGN
ExecStart=/sbin/ip addr add ${gre_local_ip}/30 dev gre${ID}
# MTU
ExecStart=/sbin/ip link set gre${ID} mtu ${MTU_VAL}
# UP
ExecStart=/sbin/ip link set gre${ID} up

ExecStop=/sbin/ip link set gre${ID} down
ExecStop=/sbin/ip tunnel del gre${ID}

[Install]
WantedBy=multi-user.target
EOF

    # Keepalive Service
    local ka_unit="keepalive-gre${ID}.service"
    cat > "/etc/systemd/system/${ka_unit}" <<EOF
[Unit]
Description=Keepalive for GRE${ID}
After=${unit}

[Service]
Type=simple
ExecStart=/bin/ping -i 10 ${gre_peer_ip}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${unit}" >/dev/null 2>&1
    systemctl enable --now "${ka_unit}" >/dev/null 2>&1
    
    add_log "Tunnel GRE${ID} Setup Done."
    add_log "Mode: GRE | Local: ${LOCAL_IP} | MTU: ${MTU_VAL}"
    pause_enter
}

port_forward_menu() {
    # Scan for GRE services
    local ids=()
    # Ugly but safe grep
    for f in /etc/systemd/system/gre*.service; do
        [[ -e "$f" ]] || break
        local fname="${f##*/}"
        if [[ "$fname" =~ ^gre([0-9]+)\.service$ ]]; then
            ids+=("${BASH_REMATCH[1]}")
        fi
    done
    
    if ((${#ids[@]} == 0)); then
        add_log "No Tunnels Found. Setup Local First."
        pause_enter
        return
    fi
    
    render
    echo "Select Tunnel to Forward Ports on:"
    local c=0
    for i in "${ids[@]}"; do
        echo "$((++c))) GRE${i}"
    done
    
    local choice
    read -r -p "Select: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > c)); then
        add_log "Invalid selection"
        pause_enter
        return
    fi
    
    local sel_id="${ids[$((choice-1))]}"
    
    # Calculate Peer IP logic again
    # Read from unit file to be safe
    local ufile="/etc/systemd/system/gre${sel_id}.service"
    local grep_ip
    grep_ip=$(grep -oP 'ip addr add \K[0-9.]+' "$ufile")
    
    if [[ -z "$grep_ip" ]]; then
        add_log "Could not read IP from service file."
        pause_enter
        return
    fi
    
    local base="${grep_ip%.*}"
    local last="${grep_ip##*.}"
    local peer_ip
    
    if [[ "$last" == "1" ]]; then peer_ip="${base}.2"; else peer_ip="${base}.1"; fi
    
    add_log "Forwarding via GRE${sel_id} -> Peer: ${peer_ip}"
    
    ask_ports_smart
    install_deps
    
    for p in "${PORT_LIST[@]}"; do
        local fw_unit="fw-gre${sel_id}-${p}.service"
        cat > "/etc/systemd/system/${fw_unit}" <<EOF
[Unit]
Description=Forward Port ${p} over GRE${sel_id}
After=gre${sel_id}.service

[Service]
ExecStart=/usr/bin/socat TCP4-LISTEN:${p},reuseaddr,fork TCP4:${peer_ip}:${p}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable --now "${fw_unit}" >/dev/null 2>&1
    done
    
    add_log "Forwarding Setup Complete."
    pause_enter
}

check_connectivity() {
    render
    echo "Running connectivity check..."
    # Find active tunnels
    local active_tunnels
    active_tunnels=$(ip -o tunnel show | grep gre | awk -F: '{print $1}')
    
    if [[ -z "$active_tunnels" ]]; then
        add_log "No active tunnels in kernel."
        pause_enter
        return
    fi
    
    for t in $active_tunnels; do
        local my_ip
        my_ip=$(ip -4 addr show dev "$t" | grep -oP 'inet \K[\d.]+')
        if [[ -n "$my_ip" ]]; then
            local base="${my_ip%.*}"
            local last="${my_ip##*.}"
            local peer
            if [[ "$last" == "1" ]]; then peer="${base}.2"; else peer="${base}.1"; fi
            
            echo "--------------------------------"
            echo "Tunnel: $t | My IP: $my_ip"
            echo "Pinging Peer: $peer ..."
            ping -c 3 -W 1 "$peer"
            echo "--------------------------------"
        fi
    done
    pause_enter
}

uninstall() {
    render
    read -r -p "Type 'delete' to remove ALL TEEJAY configs: " ans
    if [[ "$ans" == "delete" ]]; then
        systemctl stop gre*.service fw-gre*.service keepalive-gre*.service 2>/dev/null
        systemctl disable gre*.service fw-gre*.service keepalive-gre*.service 2>/dev/null
        rm -f /etc/systemd/system/gre*.service
        rm -f /etc/systemd/system/fw-gre*.service
        rm -f /etc/systemd/system/keepalive-gre*.service
        systemctl daemon-reload
        systemctl reset-failed
        add_log "All Cleaned."
    else
        add_log "Cancelled."
    fi
    pause_enter
}

# --- MAIN LOOP ---

if [[ $EUID -ne 0 ]]; then
   echo "Run as root!"
   exit 1
fi

while true; do
    render
    echo "1 > Setup IRAN Local (Tunnel Mode)"
    echo "2 > Setup KHAREJ Local (Tunnel Mode)"
    echo "3 > Connectivity Check (Ping)"
    echo "4 > Add Port Forwarding"
    echo "5 > Uninstall & Clean"
    echo "0 > Exit"
    echo
    read -r -p "Select: " opt
    
    case "$opt" in
        1) setup_tunnel_only "IRAN" ;;
        2) setup_tunnel_only "KHAREJ" ;;
        3) check_connectivity ;;
        4) port_forward_menu ;;
        5) uninstall ;;
        0) exit 0 ;;
        *) add_log "Invalid Option" ;;
    esac
done
