#!/usr/bin/env bash
#
# TEEJAY - Ultimate GRE Tunnel & Forwarding Manager
# Optimized for stability and UI/UX
#

set +e
set +u
export LC_ALL=C

# --- COLORS & STYLING ---
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
P='\033[0;35m'
C='\033[0;36m'
W='\033[1;37m'
NC='\033[0m'

LOG_LINES=()
LOG_MAX=8

# --- BANNER ---
banner() {
  clear
  echo -e "${P}
████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗
╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝
   ██║   █████╗  █████╗       ██║███████║ ╚████╔╝ 
   ██║   ██╔══╝  ██╔══╝  ██   ██║██╔══██║  ╚██╔╝  
   ██║   ███████╗███████╗╚█████╔╝██║  ██║   ██║   
   ╚═╝   ╚══════╝╚══════╝ ╚════╝ ╚═╝  ╚═╝   ╚═╝   
${NC}   ${C}>> The Ultimate Tunneling Assistant <<${NC}
"
}

# --- LOGGING SYSTEM ---
add_log() {
  local msg="$1"
  local type="${2:-INFO}" # INFO, OK, ERR, WARN
  local ts
  ts="$(date +"%H:%M:%S")"
  
  local color="$W"
  case "$type" in
    OK) color="$G" ;;
    ERR) color="$R" ;;
    WARN) color="$Y" ;;
    INFO) color="$C" ;;
  esac

  LOG_LINES+=("${W}[$ts]${NC} ${color}${msg}${NC}")
  if ((${#LOG_LINES[@]} > LOG_MAX)); then
    LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
  fi
}

render() {
  banner
  echo -e "${W}┌───────────────────────────── ACTION LOG ─────────────────────────────┐${NC}"
  
  local count="${#LOG_LINES[@]}"
  local start=0
  [[ $count -gt $LOG_MAX ]] && start=$((count - LOG_MAX))

  for ((i=start; i<count; i++)); do
    # Remove color codes for printf alignment calculation (simplified)
    local raw="${LOG_LINES[$i]}"
    # Just printing directly for color support, alignment might vary slightly but looks better
    echo -e "│ ${raw} \033[K" 
  done

  # Fill empty lines
  local shown=$((count - start))
  local missing=$((LOG_MAX - shown))
  for ((i=0; i<missing; i++)); do
    echo -e "│"
  done

  echo -e "${W}└──────────────────────────────────────────────────────────────────────┘${NC}"
  echo
}

pause_enter() {
  echo
  echo -e "${C}Press ${W}[ENTER]${C} to continue...${NC}"
  read -r
}

die_soft() {
  add_log "$1" "ERR"
  render
  pause_enter
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Error: Must run as root.${NC}"
    exit 1
  fi
}

# --- VALIDATION UTILS ---
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  ((a<=255 && b<=255 && c<=255 && d<=255))
}

valid_port() {
  local p="$1"
  is_int "$p" && ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" && [[ "$ip" =~ \.0$ ]]
}

ipv4_set_last() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}

ask() {
  local prompt="$1" validator="$2" var="$3"
  while true; do
    render
    echo -e "${C}$prompt${NC}"
    read -r -e -p "> " ans
    ans="$(trim "$ans")"
    [[ -z "$ans" ]] && continue
    if "$validator" "$ans"; then
      printf -v "$var" '%s' "$ans"
      add_log "Set: $prompt -> $ans" "OK"
      return 0
    else
      add_log "Invalid input. Try again." "WARN"
    fi
  done
}

ask_ports() {
  local raw=""
  while true; do
    render
    echo -e "${C}Forward Ports (e.g., 80 or 80,443 or 2050-2060):${NC}"
    read -r -e -p "> " raw
    raw="$(trim "$raw")"
    [[ -z "$raw" ]] && continue

    # Parse ports
    local -a ports=()
    local ok=1
    
    # Replace comma with space
    local clean_raw="${raw//,/ }"
    
    for part in $clean_raw; do
       if [[ "$part" =~ ^[0-9]+$ ]]; then
          valid_port "$part" && ports+=("$part") || ok=0
       elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          local s="${BASH_REMATCH[1]}"
          local e="${BASH_REMATCH[2]}"
          if valid_port "$s" && valid_port "$e" && ((s<=e)); then
             for ((p=s; p<=e; p++)); do ports+=("$p"); done
          else
             ok=0
          fi
       else
          ok=0
       fi
    done

    if ((ok==0 || ${#ports[@]}==0)); then
       add_log "Invalid port format." "WARN"
       continue
    fi
    
    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | sort -n | uniq)
    add_log "Selected ${#PORT_LIST[@]} ports." "OK"
    return 0
  done
}

# --- SYSTEM SETUP ---

ensure_packages() {
  local -a needed=()
  command -v ip >/dev/null 2>&1 || needed+=("iproute2")
  command -v socat >/dev/null 2>&1 || needed+=("socat")
  command -v haproxy >/dev/null 2>&1 || needed+=("haproxy")
  
  if ((${#needed[@]} > 0)); then
    add_log "Installing dependencies: ${needed[*]}" "INFO"
    render
    apt-get update -y >/dev/null 2>&1
    apt-get install -y "${needed[@]}" >/dev/null 2>&1
  fi
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }

# --- CORE LOGIC ---

make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" gre_local="$4" key="$5" mtu="${6:-}"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"

  add_log "Creating GRE Service: $unit" "INFO"
  
  local mtu_cmd=""
  [[ -n "$mtu" ]] && mtu_cmd="ExecStart=/sbin/ip link set gre${id} mtu ${mtu}"

  cat >"$path" <<EOF
[Unit]
Description=TEEJAY GRE Tunnel ${id}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/sbin/ip tunnel del gre${id}
ExecStart=/sbin/ip tunnel add gre${id} mode gre local ${local_ip} remote ${remote_ip} key ${key} nopmtudisc
ExecStart=/sbin/ip addr add ${gre_local}/30 dev gre${id}
${mtu_cmd}
ExecStart=/sbin/ip link set gre${id} up
ExecStop=/sbin/ip link set gre${id} down
ExecStop=/sbin/ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF
}

# ** NEW ** Keepalive Service to fix timeout issues
make_keepalive_service() {
    local id="$1" target_gre_ip="$2"
    local unit="keepalive-gre${id}.service"
    local path="/etc/systemd/system/${unit}"

    add_log "Adding Heartbeat (Keepalive) for GRE${id}..." "INFO"

    cat >"$path" <<EOF
[Unit]
Description=TEEJAY Keepalive for GRE${id}
After=gre${id}.service
Requires=gre${id}.service

[Service]
Type=simple
ExecStart=/bin/ping -i 10 ${target_gre_ip}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable "$unit" >/dev/null 2>&1
    systemctl start "$unit" >/dev/null 2>&1
}

make_fw_socat() {
  local id="$1" port="$2" target="$3"
  local unit="fw-gre${id}-${port}.service"
  local path="/etc/systemd/system/${unit}"

  cat >"$path" <<EOF
[Unit]
Description=TEEJAY Socat Forward ${port}
After=network-online.target gre${id}.service

[Service]
ExecStart=/usr/bin/socat TCP4-LISTEN:${port},reuseaddr,fork TCP4:${target}:${port}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now "$unit" >/dev/null 2>&1
}

# --- SETUP FLOWS ---

setup_iran() {
  local ID IRAN_IP KHAREJ_IP BASE_IP
  local MODE="socat"
  
  ask "Enter GRE ID (e.g. 1):" is_int ID
  ask "IRAN IP (This Server):" valid_ipv4 IRAN_IP
  ask "KHAREJ IP (Remote Server):" valid_ipv4 KHAREJ_IP
  ask "GRE Range (e.g. 10.10.10.0):" valid_gre_base BASE_IP
  
  # Select Mode
  while true; do
    render
    echo -e "${C}Select Forwarding Mode:${NC}"
    echo "1) Socat (Simple, Standard)"
    echo "2) HAProxy (Advanced, TCP optimization)"
    read -r -e -p "> " m
    case "$m" in
        1) MODE="socat"; break ;;
        2) MODE="haproxy"; break ;;
        *) ;;
    esac
  done

  ask_ports
  
  # MTU
  local mtu_val=""
  render
  read -r -p "Set custom MTU? (Enter value 576-1500 or leave empty for default): " mtu_input
  if [[ -n "$mtu_input" ]] && valid_port "$mtu_input"; then
      mtu_val="$mtu_input"
  fi

  local gre_local="$(ipv4_set_last "$BASE_IP" 1)"
  local gre_peer="$(ipv4_set_last "$BASE_IP" 2)"
  local key=$((ID*100))

  ensure_packages

  # Create GRE
  make_gre_service "$ID" "$IRAN_IP" "$KHAREJ_IP" "$gre_local" "$key" "$mtu_val"
  systemd_reload
  systemctl enable --now "gre${ID}.service"

  # Create Keepalive (Crucial for stability)
  make_keepalive_service "$ID" "$gre_peer"

  # Forwarding
  if [[ "$MODE" == "socat" ]]; then
      add_log "Configuring Socat..." "INFO"
      for p in "${PORT_LIST[@]}"; do
          make_fw_socat "$ID" "$p" "$gre_peer"
      done
  else
      add_log "Configuring HAProxy..." "INFO"
      # HAProxy Logic
      mkdir -p /etc/haproxy/conf.d
      local hcfg="/etc/haproxy/conf.d/gre${ID}.cfg"
      echo "" > "$hcfg"
      for p in "${PORT_LIST[@]}"; do
          cat >> "$hcfg" <<EOF
frontend f_gre${ID}_${p}
    bind *:${p}
    default_backend b_gre${ID}_${p}
backend b_gre${ID}_${p}
    mode tcp
    server s_gre${ID}_${p} ${gre_peer}:${p} check
EOF
      done
      
      # Patch HAProxy service to read conf.d
      if ! grep -q "conf.d" /lib/systemd/system/haproxy.service; then
         sed -i 's|ExecStart=.*|ExecStart=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ -p /run/haproxy.pid|' /lib/systemd/system/haproxy.service
         systemctl daemon-reload
      fi
      systemctl enable --now haproxy
      systemctl restart haproxy
  fi

  add_log "SETUP COMPLETE!" "OK"
  echo -e "
${G}Tunnel GRE${ID} is UP!${NC}
Local GRE IP: ${gre_local}
Remote GRE IP: ${gre_peer}
Mode: ${MODE}
Keepalive: Active
"
  pause_enter
}

setup_kharej() {
  local ID KHAREJ_IP IRAN_IP BASE_IP
  
  ask "Enter GRE ID (Same as IRAN):" is_int ID
  ask "KHAREJ IP (This Server):" valid_ipv4 KHAREJ_IP
  ask "IRAN IP (Remote Server):" valid_ipv4 IRAN_IP
  ask "GRE Range (Same as IRAN):" valid_gre_base BASE_IP

  local mtu_val=""
  render
  read -r -p "Set custom MTU? (Leave empty default): " mtu_input
  [[ -n "$mtu_input" ]] && mtu_val="$mtu_input"

  local gre_local="$(ipv4_set_last "$BASE_IP" 2)"
  local gre_peer="$(ipv4_set_last "$BASE_IP" 1)"
  local key=$((ID*100))

  ensure_packages

  make_gre_service "$ID" "$KHAREJ_IP" "$IRAN_IP" "$gre_local" "$key" "$mtu_val"
  systemd_reload
  systemctl enable --now "gre${ID}.service"
  
  # Kharej usually doesn't need keepalive initiator, but good practice
  make_keepalive_service "$ID" "$gre_peer"

  add_log "KHAREJ SETUP COMPLETE!" "OK"
  pause_enter
}

# --- DIAGNOSTICS ---

do_ping_test() {
    mapfile -t UNITS < <(systemctl list-units --all --no-legend "gre*.service" | awk '{print $1}')
    
    if ((${#UNITS[@]} == 0)); then
        die_soft "No GRE tunnels found."
        return
    fi

    render
    echo -e "${C}Select Tunnel to Ping:${NC}"
    local i=1
    for u in "${UNITS[@]}"; do
        echo "$i) $u"
        ((i++))
    done
    read -r -p "> " sel

    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#UNITS[@]})); then
        local unit="${UNITS[$((sel-1))]}"
        local id="${unit#gre}"
        id="${id%.service}"
        
        # Extract peer IP from service file
        local peer_ip
        peer_ip=$(grep "tunnel add" "/etc/systemd/system/${unit}" | grep -o "local [0-9.]*" | awk '{print $2}')
        # Actually we need the GRE internal peer IP.
        # Let's get current GRE IP and guess peer.
        local current_ip
        current_ip=$(ip -4 addr show "gre${id}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        
        if [[ -z "$current_ip" ]]; then
             echo -e "${R}Interface gre${id} is down or has no IP.${NC}"
             pause_enter
             return
        fi

        # Simple logic: if ends in .1 -> .2, if .2 -> .1
        local last_octet="${current_ip##*.}"
        local prefix="${current_ip%.*}"
        local target_ip=""
        if [[ "$last_octet" == "1" ]]; then target_ip="${prefix}.2"; else target_ip="${prefix}.1"; fi

        render
        echo -e "${Y}Pinging Peer Tunnel IP: ${target_ip} ...${NC}"
        echo
        ping -c 4 "$target_ip"
        echo
        pause_enter
    fi
}

# --- MENU SYSTEM ---

main_menu() {
  while true; do
    render
    echo -e "${G}1)${NC} Setup IRAN Side (Tunnel + Forward)"
    echo -e "${G}2)${NC} Setup KHAREJ Side (Tunnel Only)"
    echo -e "${Y}3)${NC} Connectivity Check (PING)"
    echo -e "${R}4)${NC} Uninstall / Clean"
    echo -e "${B}0)${NC} Exit"
    echo
    read -r -p "Select option: " opt
    
    case "$opt" in
      1) setup_iran ;;
      2) setup_kharej ;;
      3) do_ping_test ;;
      4) 
         read -r -p "Enter GRE ID to uninstall: " uid
         if [[ -n "$uid" ]]; then
             systemctl stop "gre${uid}" "keepalive-gre${uid}" "fw-gre${uid}-*" 2>/dev/null
             systemctl disable "gre${uid}" "keepalive-gre${uid}" "fw-gre${uid}-*" 2>/dev/null
             rm -f /etc/systemd/system/gre${uid}.service
             rm -f /etc/systemd/system/keepalive-gre${uid}.service
             rm -f /etc/systemd/system/fw-gre${uid}-*.service
             rm -f /etc/haproxy/conf.d/gre${uid}.cfg
             systemd_reload
             add_log "Removed GRE${uid} and associated services." "OK"
             pause_enter
         fi
         ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

ensure_root
main_menu
