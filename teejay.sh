#!/usr/bin/env bash

set +e
set +u
export LC_ALL=C

# --- COLORS & STYLING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

LOG_LINES=()
LOG_MIN=3
LOG_MAX=10

# --- BANNER & UI ---

banner() {
  cat <<EOF
${CYAN}
  ████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗
  ╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝
     ██║   █████╗  █████╗       ██║███████║ ╚████╔╝ 
     ██║   ██╔══╝  ██╔══╝  ██   ██║██╔══██║  ╚██╔╝  
     ██║   ███████╗███████╗╚█████╔╝██║  ██║   ██║   
     ╚═╝   ╚══════╝╚══════╝ ╚════╝ ╚═╝  ╚═╝   ╚═╝   
${PURPLE}       >>> NETWORK TUNNEL AUTOMATION V2 <<<${NC}
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
  ((height < LOG_MIN)) && height=$LOG_MIN
  ((height > LOG_MAX)) && height=$LOG_MAX

  echo -e "${BOLD}┌───────────────────────────── ${YELLOW}ACTION LOG${NC}${BOLD} ─────────────────────────────┐${NC}"
  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    # Strip colors for length calculation if needed, but keeping it simple
    printf "│ %-68s │\n" "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-68s │\n" ""
  done

  echo -e "${BOLD}└──────────────────────────────────────────────────────────────────────┘${NC}"
  echo
}

pause_enter() {
  echo
  echo -e "${CYAN}Press ${BOLD}ENTER${NC}${CYAN} to return to menu...${NC}"
  read -r _
}

die_soft() {
  add_log "ERROR: $1"
  render
  pause_enter
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    exec sudo -E bash "$0" "$@"
  fi
}

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# --- VALIDATORS ---

valid_octet() {
  local o="$1"
  [[ "$o" =~ ^[0-9]+$ ]] && ((o>=0 && o<=255))
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  valid_octet "$a" && valid_octet "$b" && valid_octet "$c" && valid_octet "$d"
}

valid_port() {
  local p="$1"
  is_int "$p" || return 1
  ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ \.0$ ]] || return 1
  return 0
}

valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  ((m>=576 && m<=1600))
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}

# --- INPUT HELPERS ---

ask_until_valid() {
  local prompt="$1" validator="$2" __var="$3"
  local ans=""
  while true; do
    render
    echo -e "${GREEN}?? ${NC}$prompt"
    read -r -e -p "   > " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "Empty input. Try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: Value accepted."
      return 0
    else
      add_log "Invalid input. Check format."
    fi
  done
}

get_public_ip() {
    local ip
    ip=$(curl -s --max-time 3 -4 ifconfig.me)
    if valid_ipv4 "$ip"; then
        echo "$ip"
    else
        echo ""
    fi
}

ask_ip_interactive() {
    local prompt_text="$1"
    local __result_var="$2"
    local detected_ip
    local user_choice
    
    detected_ip=$(get_public_ip)
    
    while true; do
        render
        echo -e "${GREEN}?? ${NC}$prompt_text"
        
        if [[ -n "$detected_ip" ]]; then
            echo -e "   Detected IP: ${YELLOW}$detected_ip${NC}"
            read -r -p "   Is this correct? (y/n): " user_choice
            user_choice="$(trim "${user_choice,,}")"
            
            if [[ "$user_choice" == "y" || "$user_choice" == "yes" ]]; then
                printf -v "$__result_var" '%s' "$detected_ip"
                add_log "IP Auto-Selected: $detected_ip"
                return 0
            elif [[ "$user_choice" == "n" || "$user_choice" == "no" ]]; then
                detected_ip="" # Force manual entry loop
                continue
            else
                 add_log "Please answer 'y' or 'n'."
                 continue
            fi
        fi

        # Manual Entry
        read -r -e -p "   Enter IP Manually: " user_choice
        user_choice="$(trim "$user_choice")"
        
        if valid_ipv4 "$user_choice"; then
             printf -v "$__result_var" '%s' "$user_choice"
             add_log "IP Manually Set: $user_choice"
             return 0
        else
             add_log "Invalid IPv4 format."
        fi
    done
}

ask_ports() {
  local prompt="Forward PORTs (e.g: 80 | 80,443 | 2000-3000):"
  local raw=""
  while true; do
    render
    echo -e "${GREEN}?? ${NC}$prompt"
    read -r -e -p "   > " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Try again."
      continue
    fi

    local -a ports=()
    local ok=1

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      valid_port "$raw" && ports+=("$raw") || ok=0

    elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
      local s="${raw%-*}"
      local e="${raw#*-}"
      if valid_port "$s" && valid_port "$e" && ((s<=e)); then
        local p
        for ((p=s; p<=e; p++)); do ports+=("$p"); done
      else
        ok=0
      fi

    elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
      IFS=',' read -r -a parts <<<"$raw"
      local part
      for part in "${parts[@]}"; do
        valid_port "$part" && ports+=("$part") || { ok=0; break; }
      done
    else
      ok=0
    fi

    if ((ok==0)); then
      add_log "Invalid format."
      add_log "Examples: 443 OR 80,443 OR 8000-9000"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports queued: ${#PORT_LIST[@]} ports"
    return 0
  done
}

# --- SYSTEM & SERVICE FUNCTIONS ---

ensure_packages() {
  add_log "Checking requirements..."
  render
  local missing=()
  command -v ip >/dev/null 2>&1 || missing+=("iproute2")
  command -v socat >/dev/null 2>&1 || missing+=("socat")

  if ((${#missing[@]}==0)); then
    return 0
  fi

  add_log "Installing: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Installed successfully." || return 1
  return 0
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }
unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }
enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }

make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5" mtu="${6:-}"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Service $unit already exists. Skipping."
    return 2
  fi

  add_log "Generating Service: $unit"
  
  local mtu_line=""
  if [[ -n "$mtu" ]]; then
    mtu_line="ExecStart=/sbin/ip link set gre${id} mtu ${mtu}"
  fi

  cat >"$path" <<EOF
[Unit]
Description=GRE Tunnel to (${remote_ip})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "/sbin/ip tunnel del gre${id} 2>/dev/null || true"
ExecStart=/sbin/ip tunnel add gre${id} mode gre local ${local_ip} remote ${remote_ip} key ${key} nopmtudisc
ExecStart=/sbin/ip addr add ${local_gre_ip}/30 dev gre${id}
${mtu_line}
ExecStart=/sbin/ip link set gre${id} up
ExecStop=/sbin/ip link set gre${id} down
ExecStop=/sbin/ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && return 0 || return 1
}

make_fw_service() {
  local id="$1" port="$2" target_ip="$3"
  local unit="fw-gre${id}-${port}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "FW Exists: $unit"
    return 0
  fi

  cat >"$path" <<EOF
[Unit]
Description=forward gre${id} ${port}
After=network-online.target gre${id}.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP4-LISTEN:${port},reuseaddr,fork TCP4:${target_ip}:${port}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

# --- CORE SETUP LOGIC ---

setup_iran_local() {
  local ID IRANIP KHAREJIP GREBASE
  local use_mtu="n" MTU_VALUE=""

  ask_until_valid "GRE Number (Unique ID):" is_int ID
  
  # New IP Logic
  ask_ip_interactive "Enter IRAN (Local) IP:" IRANIP

  ask_until_valid "KHAREJ (Remote) IP:" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP Range (e.g. 10.10.10.0):" valid_gre_base GREBASE

  while true; do
    render
    echo -e "${GREEN}?? ${NC}Set Custom MTU? (Default is standard)"
    read -r -p "   (y/n) > " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes)
        ask_until_valid "Custom MTU (576-1600):" valid_mtu MTU_VALUE
        break
        ;;
      n|no|"")
        MTU_VALUE=""
        break
        ;;
      *) add_log "Please enter y or n." ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  
  ensure_packages || { die_soft "Install failed."; return 0; }

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && { die_soft "Service already exists!"; return 0; }
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE file."; return 0; }

  add_log "Reloading & Starting Systemd..."
  systemd_reload
  enable_now "gre${ID}.service"

  render
  echo -e "${GREEN}✔ IRAN LOCAL SETUP COMPLETE!${NC}"
  echo
  echo "GRE IPs:"
  echo -e "  Local (IRAN) : ${CYAN}${local_gre_ip}${NC}"
  echo -e "  Remote       : ${CYAN}${peer_gre_ip}${NC}"
  echo
  echo -e "${YELLOW}NOTE:${NC} Ports are NOT forwarded yet."
  echo "Go to 'Add Tunnel Port' in the main menu to add ports."
  pause_enter
}

setup_kharej_local() {
  local ID KHAREJIP IRANIP GREBASE
  local use_mtu="n" MTU_VALUE=""

  ask_until_valid "GRE Number (Same as Iran):" is_int ID
  
  # New IP Logic
  ask_ip_interactive "Enter KHAREJ (Local) IP:" KHAREJIP

  ask_until_valid "IRAN (Remote) IP:" valid_ipv4 IRANIP
  ask_until_valid "GRE IP Range (Same as Iran):" valid_gre_base GREBASE

  while true; do
    render
    echo -e "${GREEN}?? ${NC}Set Custom MTU?"
    read -r -p "   (y/n) > " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes) ask_until_valid "Custom MTU (576-1600):" valid_mtu MTU_VALUE; break ;;
      n|no|"") MTU_VALUE=""; break ;;
      *) add_log "Please enter y or n." ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"

  ensure_packages || { die_soft "Install failed."; return 0; }

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && { die_soft "Service already exists!"; return 0; }
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE file."; return 0; }

  add_log "Reloading & Starting..."
  systemd_reload
  enable_now "gre${ID}.service"

  render
  echo -e "${GREEN}✔ KHAREJ LOCAL SETUP COMPLETE!${NC}"
  echo
  echo "GRE IPs:"
  echo -e "  Local (KHAREJ): ${CYAN}${local_gre_ip}${NC}"
  echo -e "  Remote        : ${CYAN}${peer_gre_ip}${NC}"
  pause_enter
}

# --- TUNNEL / PORT LOGIC ---

get_gre_ids() {
  local ids=()
  # From memory
  while IFS= read -r u; do
    [[ "$u" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^gre[0-9]+\.service$' || true)
  
  # From file (backup)
  while IFS= read -r f; do
    f="$(basename "$f")"
    [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null || true)

  printf "%s\n" "${ids[@]}" | awk 'NF{a[$0]=1} END{for(k in a) print k}' | sort -n
}

get_gre_cidr() {
  local id="$1"
  ip -4 addr show dev "gre${id}" 2>/dev/null | awk '/inet /{print $2}' | head -n1
}

gre_target_ip_from_cidr() {
  local cidr="$1"
  local ip mask
  ip="${cidr%/*}"
  mask="${cidr#*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$mask" == "30" ]] || return 2
  IFS='.' read -r a b c d <<<"$ip"
  local base_last=$(( d & 252 ))
  local target_last=$(( base_last + 2 ))
  ((target_last>=0 && target_last<=255)) || return 3
  echo "${a}.${b}.${c}.${target_last}"
}

add_tunnel_port() {
  local -a PORT_LIST=()
  local id cidr target_ip

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local gid
  for gid in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE Tunnel #${gid}")
  done

  if ! menu_select_index "Add Tunnel Ports" "Select Tunnel to add ports to:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  add_log "Selected GRE${id}"

  ask_ports # Fills PORT_LIST

  add_log "Detecting Tunnel IPs..."
  cidr="$(get_gre_cidr "$id")"
  if [[ -z "$cidr" ]]; then
    die_soft "Cannot detect IP on gre${id}. Is the tunnel UP? (Check Service Management)"
    return 0
  fi
  
  target_ip="$(gre_target_ip_from_cidr "$cidr")"
  if [[ -z "$target_ip" ]]; then
     die_soft "Could not calculate destination IP from $cidr"
     return 0
  fi

  add_log "Traffic will go to -> $target_ip"

  local p
  for p in "${PORT_LIST[@]}"; do
    make_fw_service "$id" "$p" "$target_ip"
  done

  systemd_reload
  for p in "${PORT_LIST[@]}"; do
    enable_now "fw-gre${id}-${p}.service"
  done

  render
  echo -e "${GREEN}✔ Tunnel Ports Added!${NC}"
  echo
  echo -e "Forwarding ${BOLD}${PORT_LIST[*]}${NC} -> ${target_ip}"
  pause_enter
}

# --- UTILS FOR MENUS ---

menu_select_index() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")
  local choice=""

  while true; do
    render
    echo -e "${CYAN}:: $title ::${NC}"
    echo

    if ((${#items[@]} == 0)); then
      echo "No active services found."
      echo
      read -r -p "Press ENTER..." _
      MENU_SELECTED=-1
      return 1
    fi

    local i
    for ((i=0; i<${#items[@]}; i++)); do
      echo -e "${BOLD}$((i+1)))${NC} ${items[$i]}"
    done
    echo -e "${BOLD}0)${NC} Back"
    echo

    read -r -e -p "$prompt " choice
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      MENU_SELECTED=-1
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#items[@]})); then
      MENU_SELECTED=$((choice-1))
      return 0
    fi
    add_log "Invalid number."
  done
}

# --- CLEANUP & OTHER FEATURES (Kept mostly logic, improved flow) ---

uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE Tunnel #${id}"); done

  if ! menu_select_index "Uninstall" "Select Tunnel to DELETE:" "${GRE_LABELS[@]}"; then return 0; fi

  local id="${GRE_IDS[$MENU_SELECTED]}"
  
  render
  echo -e "${RED}${BOLD}WARNING: DELETING GRE #${id}${NC}"
  echo "This will delete the tunnel interface and all associated port forwarders."
  echo
  read -r -p "Type 'YES' to confirm: " confirm
  if [[ "$confirm" != "YES" ]]; then
    add_log "Deletion Cancelled."
    return 0
  fi

  add_log "Stopping services..."
  systemctl stop "gre${id}.service" 2>/dev/null
  systemctl disable "gre${id}.service" 2>/dev/null
  
  # Find and stop forwarders
  find /etc/systemd/system -name "fw-gre${id}-*.service" | while read -r f; do
     systemctl stop "$(basename "$f")" 2>/dev/null
     systemctl disable "$(basename "$f")" 2>/dev/null
     rm -f "$f"
     add_log "Removed Forwarder: $(basename "$f")"
  done

  rm -f "/etc/systemd/system/gre${id}.service"
  systemctl daemon-reload
  systemctl reset-failed
  
  # Cleanup Automation files
  rm -f "/usr/local/bin/sepehr-recreate-gre${id}.sh"
  rm -f "/var/log/sepehr-gre${id}.log"
  # Clean backups if any
  rm -f "/root/gre-backup/gre${id}.service"
  rm -f /root/gre-backup/fw-gre${id}-*.service

  add_log "Cleaned up GRE #${id}."
  pause_enter
}

# --- MAIN MENU ---

main_menu() {
  local choice=""
  while true; do
    render
    echo -e "${BOLD}1 >${NC} ${GREEN}Setup IRAN Local${NC}   (Create Interface Only)"
    echo -e "${BOLD}2 >${NC} ${GREEN}Setup KHAREJ Local${NC} (Create Interface Only)"
    echo -e "${BOLD}3 >${NC} ${YELLOW}Add Tunnel Port${NC}    (Forwarding / Ports)"
    echo "------------------------------------------------"
    echo -e "4 > Services Management (Start/Stop/Status)"
    echo -e "5 > Uninstall & Clean"
    echo "------------------------------------------------"
    echo -e "6 > Change MTU"
    echo -e "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) setup_iran_local ;;
      2) setup_kharej_local ;;
      3) add_tunnel_port ;;
      4) services_management ;; # Assumed exists or reuse old logic if needed, but for brevity using placeholder or removed if not provided in full update. I will re-inject the Service Management Function below.
      5) uninstall_clean ;;
      6) change_mtu ;;
      0) exit 0 ;;
      *) add_log "Invalid option." ;;
    esac
  done
}

# --- MISSING FUNCTIONS RE-INJECTED (From original logic but cleaned) ---

ensure_mtu_line_in_unit() {
  local id="$1" mtu="$2" file="$3"
  [[ -f "$file" ]] || return 0
  if grep -qE "^ExecStart=/sbin/ip link set gre${id} mtu" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} mtu.*|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}|" "$file"
  elif grep -qE "^ExecStart=/sbin/ip link set gre${id} up$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} up$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}\nExecStart=/sbin/ip link set gre${id} up|" "$file"
  else
    printf "\nExecStart=/sbin/ip link set gre%s mtu %s\n" "$id" "$mtu" >> "$file"
  fi
}

change_mtu() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE Tunnel #${id}"); done
  if ! menu_select_index "Change MTU" "Select Tunnel:" "${GRE_LABELS[@]}"; then return 0; fi
  local id="${GRE_IDS[$MENU_SELECTED]}"
  
  local mtu
  ask_until_valid "New MTU (576-1600):" valid_mtu mtu
  
  ip link set "gre${id}" mtu "$mtu" 2>/dev/null
  ensure_mtu_line_in_unit "$id" "$mtu" "/etc/systemd/system/gre${id}.service"
  systemd_reload
  add_log "MTU Updated to $mtu"
  pause_enter
}

service_action_menu() {
  local unit="$1"
  local action=""
  while true; do
    render
    echo -e "Unit: ${CYAN}$unit${NC}"
    echo
    echo "1) Start & Enable"
    echo "2) Restart"
    echo "3) Stop & Disable"
    echo "4) Show Logs/Status"
    echo "0) Back"
    echo
    read -r -p "Action: " action
    case "$action" in
      1) systemctl enable --now "$unit" && add_log "Started.";;
      2) systemctl restart "$unit" && add_log "Restarted.";;
      3) systemctl disable --now "$unit" && add_log "Stopped.";;
      4) systemctl status "$unit" | cat; read -p "Enter..." _ ;;
      0) return 0 ;;
    esac
  done
}

get_all_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre*-*.service" 2>/dev/null | awk -F/ '{print $NF}' | sort -V
}

services_management() {
  local sel=""
  while true; do
    render
    echo "1) Manage Tunnels (GRE Interfaces)"
    echo "2) Manage Forwarders (Ports)"
    echo "0) Back"
    read -r -p "Select: " sel
    case "$sel" in
      1)
        mapfile -t GRE_IDS < <(get_gre_ids)
        local -a L=(); for i in "${GRE_IDS[@]}"; do L+=("GRE #$i"); done
        if menu_select_index "Tunnels" "Select:" "${L[@]}"; then
             service_action_menu "gre${GRE_IDS[$MENU_SELECTED]}.service"
        fi
        ;;
      2)
        mapfile -t FWS < <(get_all_fw_units)
        if menu_select_index "Forwarders" "Select:" "${FWS[@]}"; then
             service_action_menu "${FWS[$MENU_SELECTED]}"
        fi
        ;;
      0) return 0 ;;
    esac
  done
}

ensure_root "$@"
main_menu
