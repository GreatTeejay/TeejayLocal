#!/usr/bin/env bash
# teejay.sh
# TEEJAY - GRE + Forwarder Manager (Local setup جدا از Tunnel/Forwarder)

set +e
set +u
export LC_ALL=C

# ----------------------------- UI / THEME ------------------------------
LOG_LINES=()
LOG_MIN=4
LOG_MAX=12

# Colors (safe fallback)
if command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_CYAN="$(tput setaf 6)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_RED="$(tput setaf 1)"
  C_MAGENTA="$(tput setaf 5)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_MAGENTA=""
fi

banner() {
  cat <<EOF
${C_CYAN}${C_BOLD}
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     ████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗               ║
║     ╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝               ║
║        ██║   █████╗  █████╗       ██║███████║ ╚████╔╝                ║
║        ██║   ██╔══╝  ██╔══╝       ██║██╔══██║  ╚██╔╝                 ║
║        ██║   ███████╗███████╗     ██║██║  ██║   ██║                  ║
║        ╚═╝   ╚══════╝╚══════╝     ╚═╝╚═╝  ╚═╝   ╚═╝                  ║
║                                                                      ║
║                         T E E J A Y                                  ║
║                 Local Setup  |  Tunnel/Forwarder                     ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
${C_RESET}
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

  echo "${C_DIM}┌────────────────────────────── ACTION LOG ──────────────────────────────┐${C_RESET}"
  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    printf "│ %-73s │\n" "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-73s │\n" ""
  done

  echo "${C_DIM}└─────────────────────────────────────────────────────────────────────────┘${C_RESET}"
  echo
}

pause_enter() {
  echo
  read -r -p "Press ENTER to return..." _
}

die_soft() {
  add_log "${C_RED}ERROR:${C_RESET} $1"
  render
  pause_enter
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

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
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ \.0$ ]] || return 1
  return 0
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}

ask_until_valid() {
  local prompt="$1" validator="$2" __var="$3"
  local ans=""
  while true; do
    render
    read -r -e -p "$prompt " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "${C_YELLOW}Empty input.${C_RESET} Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "${C_GREEN}OK:${C_RESET} $prompt $ans"
      return 0
    else
      add_log "${C_RED}Invalid:${C_RESET} $prompt $ans"
    fi
  done
}

ask_ports() {
  local prompt="Forward PORT(s) (example: 80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    read -r -e -p "$prompt " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "${C_YELLOW}Empty ports.${C_RESET} Please try again."
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
      add_log "${C_RED}Invalid ports:${C_RESET} $raw"
      add_log "Examples: 80 | 80,2053 | 2050-2060"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "${C_GREEN}Ports accepted:${C_RESET} ${PORT_LIST[*]}"
    return 0
  done
}

# ----------------------------- Packages & IP detect ------------------------------
ensure_packages() {
  add_log "Checking required packages: iproute2, socat, curl"
  render
  local missing=()
  command -v ip    >/dev/null 2>&1 || missing+=("iproute2")
  command -v socat >/dev/null 2>&1 || missing+=("socat")
  command -v curl  >/dev/null 2>&1 || missing+=("curl")

  if ((${#missing[@]}==0)); then
    add_log "All required packages are installed."
    return 0
  fi

  add_log "Installing missing packages: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

ensure_local_prereqs() {
  add_log "Checking required packages: iproute2, curl"
  render
  local missing=()
  command -v ip   >/dev/null 2>&1 || missing+=("iproute2")
  command -v curl >/dev/null 2>&1 || missing+=("curl")

  if ((${#missing[@]}==0)); then
    add_log "Local prerequisites are installed."
    return 0
  fi

  add_log "Installing: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Installed successfully." || return 1
  return 0
}

detect_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 3 https://api64.ipify.org 2>/dev/null || true)"
  valid_ipv4 "$ip" && { echo "$ip"; return 0; }

  ip="$(curl -4 -fsS --max-time 3 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
  valid_ipv4 "$ip" && { echo "$ip"; return 0; }

  ip="$(curl -4 -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n' || true)"
  valid_ipv4 "$ip" && { echo "$ip"; return 0; }

  return 1
}

ask_local_ip_smooth() {
  # usage: ask_local_ip_smooth "IRAN" varname
  local label="$1" __var="$2"
  local detected=""

  if ! command -v curl >/dev/null 2>&1; then
    add_log "curl not found. Skipping auto-detect; please enter IP manually."
    local manual=""
    ask_until_valid "${label} public IP (manual):" valid_ipv4 manual
    printf -v "$__var" '%s' "$manual"
    return 0
  fi

  detected="$(detect_public_ipv4 || true)"

  if valid_ipv4 "$detected"; then
    add_log "Detected ${label} public IP: ${C_CYAN}${detected}${C_RESET}"

    local choice=""
    while true; do
      render
      echo "${C_BOLD}${label} IP confirmation${C_RESET}"
      echo
      echo "Detected public IP:"
      echo "  ${C_CYAN}${detected}${C_RESET}"
      echo
      echo "Is this your IP?"
      echo "1) Yes"
      echo "2) No (enter manually)"
      echo "0) Back (cancel)"
      echo
      read -r -p "Select: " choice
      choice="$(trim "$choice")"

      case "$choice" in
        1)
          printf -v "$__var" '%s' "$detected"
          add_log "${C_GREEN}Using detected IP:${C_RESET} $detected"
          return 0
          ;;
        2)
          local manual=""
          ask_until_valid "${label} public IP (manual):" valid_ipv4 manual
          printf -v "$__var" '%s' "$manual"
          return 0
          ;;
        0)
          return 1
          ;;
        *)
          add_log "Invalid selection."
          ;;
      esac
    done
  fi

  add_log "${C_YELLOW}Could not detect public IP automatically.${C_RESET}"
  local manual=""
  ask_until_valid "${label} public IP (manual):" valid_ipv4 manual
  printf -v "$__var" '%s' "$manual"
  return 0
}

# ----------------------------- GRE helpers ------------------------------
valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  ((m>=576 && m<=1600))
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }
unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }
enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }

show_unit_status_brief() {
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,12p'
}

ensure_mtu_line_in_unit() {
  local id="$1" mtu="$2" file="$3"
  [[ -f "$file" ]] || return 0

  if grep -qE "^ExecStart=/sbin/ip link set gre${id} mtu[[:space:]]+[0-9]+$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} mtu[[:space:]]+[0-9]+$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}|" "$file"
    add_log "Updated MTU line in: $file"
    return 0
  fi

  if grep -qE "^ExecStart=/sbin/ip link set gre${id} up$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} up$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}\nExecStart=/sbin/ip link set gre${id} up|" "$file"
    add_log "Inserted MTU line in: $file"
    return 0
  fi

  printf "\nExecStart=/sbin/ip link set gre%s mtu %s\n" "$id" "$mtu" >> "$file"
  add_log "WARNING: 'ip link set gre${id} up' not found; appended MTU line at end: $file"
}

make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5" mtu="${6:-}"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "${C_YELLOW}Service already exists:${C_RESET} $unit"
    return 2
  fi

  add_log "Creating: $path"
  render

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

  [[ $? -eq 0 ]] && add_log "${C_GREEN}GRE service created:${C_RESET} $unit" || return 1
  return 0
}

make_fw_service() {
  local id="$1" port="$2" target_ip="$3"
  local unit="fw-gre${id}-${port}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Forwarder exists, skip: $unit"
    return 0
  fi

  add_log "Creating forwarder: fw-gre${id}-${port}"
  render

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

  [[ $? -eq 0 ]] && add_log "${C_GREEN}Forwarder created:${C_RESET} fw-gre${id}-${port}" || add_log "Failed writing forwarder: $unit"
}

apply_rpfilter_relax() {
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
}

# ----------------------------- Local Setup (GRE only) ------------------------------
iran_local_setup() {
  local ID IRANIP KHAREJIP GREBASE
  local use_mtu="n" MTU_VALUE=""

  add_log "${C_MAGENTA}Wizard:${C_RESET} IRAN Local Setup (GRE only)"
  ask_until_valid "GRE Number:" is_int ID

  ensure_local_prereqs || { die_soft "Package installation failed (iproute2/curl)."; return 0; }

  ask_local_ip_smooth "IRAN" IRANIP || { add_log "Cancelled."; return 0; }
  ask_until_valid "KHAREJ IP (remote):" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP RANGE base (example: 10.80.70.0):" valid_gre_base GREBASE

  while true; do
    render
    read -r -p "Set custom MTU? (y/n): " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes) ask_until_valid "Custom MTU (576-1600):" valid_mtu MTU_VALUE; break ;;
      n|no|"") MTU_VALUE=""; break ;;
      *) add_log "Invalid input. Please enter y or n." ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  add_log "KEY=${key} | IRAN(GRE)=${local_gre_ip} | KHAREJ(GRE)=${peer_gre_ip}"

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && { die_soft "gre${ID}.service already exists."; return 0; }
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}.service ..."
  enable_now "gre${ID}.service"
  apply_rpfilter_relax

  render
  echo "${C_BOLD}GRE IPs:${C_RESET}"
  echo "  IRAN  : ${local_gre_ip}"
  echo "  KHAREJ: ${peer_gre_ip}"
  echo
  echo "${C_BOLD}Status:${C_RESET}"
  show_unit_status_brief "gre${ID}.service"
  echo
  echo "${C_DIM}Forwarders are separate. Use Tunnel/Forwarder menu later.${C_RESET}"
  pause_enter
}

kharej_local_setup() {
  local ID KHAREJIP IRANIP GREBASE
  local use_mtu="n" MTU_VALUE=""

  add_log "${C_MAGENTA}Wizard:${C_RESET} KHAREJ Local Setup (GRE only)"
  ask_until_valid "GRE Number (same as IRAN):" is_int ID

  ensure_local_prereqs || { die_soft "Package installation failed (iproute2/curl)."; return 0; }

  ask_local_ip_smooth "KHAREJ" KHAREJIP || { add_log "Cancelled."; return 0; }
  ask_until_valid "IRAN IP (remote):" valid_ipv4 IRANIP
  ask_until_valid "GRE IP RANGE base (example: 10.80.70.0):" valid_gre_base GREBASE

  while true; do
    render
    read -r -p "Set custom MTU? (y/n): " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes) ask_until_valid "Custom MTU (576-1600):" valid_mtu MTU_VALUE; break ;;
      n|no|"") MTU_VALUE=""; break ;;
      *) add_log "Invalid input. Please enter y or n." ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  add_log "KEY=${key} | KHAREJ(GRE)=${local_gre_ip} | IRAN(GRE)=${peer_gre_ip}"

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && { die_soft "gre${ID}.service already exists."; return 0; }
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}.service ..."
  enable_now "gre${ID}.service"
  apply_rpfilter_relax

  render
  echo "${C_BOLD}GRE IPs:${C_RESET}"
  echo "  KHAREJ: ${local_gre_ip}"
  echo "  IRAN  : ${peer_gre_ip}"
  echo
  echo "${C_BOLD}Status:${C_RESET}"
  show_unit_status_brief "gre${ID}.service"
  pause_enter
}

# ----------------------------- Tunnel / Forwarder (separate) ------------------------------
get_gre_ids() {
  local ids=()

  while IFS= read -r u; do
    [[ "$u" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^gre[0-9]+\.service$' || true)

  while IFS= read -r f; do
    f="$(basename "$f")"
    [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null || true)

  printf "%s\n" "${ids[@]}" | awk 'NF{a[$0]=1} END{for(k in a) print k}' | sort -n
}

get_all_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre*-*.service" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^fw-gre[0-9]+-[0-9]+\.service$' \
    | sort -V || true
}

get_fw_units_for_id() {
  local id="$1"
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${id}-*.service" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E "^fw-gre${id}-[0-9]+\.service$" \
    | sort -V || true
}

MENU_SELECTED=-1
menu_select_index() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")
  local choice=""

  while true; do
    render
    echo "${C_BOLD}$title${C_RESET}"
    echo

    if ((${#items[@]} == 0)); then
      echo "No service found."
      echo
      read -r -p "Press ENTER to go back..." _
      MENU_SELECTED=-1
      return 1
    fi

    local i
    for ((i=0; i<${#items[@]}; i++)); do
      printf "%d) %s\n" $((i+1)) "${items[$i]}"
    done
    echo "0) Back"
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

    add_log "Invalid selection: $choice"
  done
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
  return 0
}

tunnel_forwarder_add_ports() {
  local -a PORT_LIST=()
  local id cidr target_ip

  ensure_packages || { die_soft "Package installation failed (iproute2/socat/curl)."; return 0; }

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local gid
  for gid in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${gid}"); done

  if ! menu_select_index "Tunnel / Forwarder" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  id="${GRE_IDS[$MENU_SELECTED]}"
  add_log "Selected: GRE${id}"

  ask_ports

  cidr="$(get_gre_cidr "$id")"
  if [[ -z "$cidr" ]]; then
    die_soft "Cannot detect inet on gre${id}. Is gre${id} UP?"
    return 0
  fi
  add_log "Detected gre${id} inet: ${cidr}"

  target_ip="$(gre_target_ip_from_cidr "$cidr")"
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    die_soft "gre${id} mask is not /30 (found: ${cidr})."
    return 0
  elif [[ $rc -ne 0 || -z "$target_ip" ]]; then
    die_soft "Failed to compute target IP from: ${cidr}"
    return 0
  fi

  add_log "Target IP for forwarders: ${C_CYAN}${target_ip}${C_RESET}"
  add_log "Creating forwarders..."
  local p
  for p in "${PORT_LIST[@]}"; do
    make_fw_service "$id" "$p" "$target_ip"
  done

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Enable & Start forwarders..."
  for p in "${PORT_LIST[@]}"; do
    enable_now "fw-gre${id}-${p}.service"
  done

  render
  echo "${C_BOLD}GRE${id}:${C_RESET}"
  echo "  inet   : ${cidr}"
  echo "  target : ${target_ip}"
  echo
  echo "${C_BOLD}Forwarder status:${C_RESET}"
  for p in "${PORT_LIST[@]}"; do
    echo
    show_unit_status_brief "fw-gre${id}-${p}.service"
  done
  pause_enter
}

# ----------------------------- Services Management ------------------------------
service_action_menu() {
  local unit="$1"
  local action=""

  while true; do
    render
    echo "Selected: ${C_BOLD}$unit${C_RESET}"
    echo
    echo "1) Enable & Start"
    echo "2) Restart"
    echo "3) Stop & Disable"
    echo "4) Status"
    echo "0) Back"
    echo

    read -r -e -p "Select action: " action
    action="$(trim "$action")"

    case "$action" in
      1)
        add_log "Enable & Start: $unit"
        systemctl enable "$unit" >/dev/null 2>&1 && add_log "Enabled: $unit" || add_log "Enable failed: $unit"
        systemctl start "$unit"  >/dev/null 2>&1 && add_log "Started: $unit" || add_log "Start failed: $unit"
        ;;
      2)
        add_log "Restart: $unit"
        systemctl restart "$unit" >/dev/null 2>&1 && add_log "Restarted: $unit" || add_log "Restart failed: $unit"
        ;;
      3)
        add_log "Stop & Disable: $unit"
        systemctl stop "$unit"    >/dev/null 2>&1 && add_log "Stopped: $unit" || add_log "Stop failed: $unit"
        systemctl disable "$unit" >/dev/null 2>&1 && add_log "Disabled: $unit" || add_log "Disable failed: $unit"
        ;;
      4)
        render
        echo "---- STATUS ($unit) ----"
        systemctl --no-pager --full status "$unit" 2>&1 | sed -n '1,16p'
        echo "------------------------"
        pause_enter
        ;;
      0) return 0 ;;
      *) add_log "Invalid action: $action" ;;
    esac
  done
}

services_management() {
  local sel=""

  while true; do
    render
    echo "${C_BOLD}Services Management${C_RESET}"
    echo
    echo "1) GRE services"
    echo "2) Forwarder services"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1)
        mapfile -t GRE_IDS < <(get_gre_ids)
        local -a GRE_LABELS=()
        local id
        for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

        if menu_select_index "GRE Services" "Select GRE:" "${GRE_LABELS[@]}"; then
          local idx="$MENU_SELECTED"
          id="${GRE_IDS[$idx]}"
          add_log "GRE selected: GRE${id}"
          service_action_menu "gre${id}.service"
        fi
        ;;

      2)
        mapfile -t FW_UNITS < <(get_all_fw_units)
        local -a FW_LABELS=()
        local u gid port

        for u in "${FW_UNITS[@]}"; do
          if [[ "$u" =~ ^fw-gre([0-9]+)-([0-9]+)\.service$ ]]; then
            gid="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            FW_LABELS+=("GRE${gid}:${port}")
          else
            FW_LABELS+=("${u%.service}")
          fi
        done

        if menu_select_index "Forwarder Services" "Select Forwarder:" "${FW_LABELS[@]}"; then
          local fidx="$MENU_SELECTED"
          u="${FW_UNITS[$fidx]}"
          add_log "Forwarder selected: ${FW_LABELS[$fidx]}"
          service_action_menu "$u"
        fi
        ;;

      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

# ----------------------------- Uninstall & Clean ------------------------------
automation_backup_dir() { echo "/root/gre-backup"; }
automation_script_path() { local id="$1"; echo "/usr/local/bin/sepehr-recreate-gre${id}.sh"; }
automation_log_path() { local id="$1"; echo "/var/log/sepehr-gre${id}.log"; }

remove_gre_automation_cron() {
  local id="$1"
  local script
  script="$(automation_script_path "$id")"

  crontab -l >/dev/null 2>&1 || return 0
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$script" > "$tmp" || true
  crontab "$tmp" 2>/dev/null || true
  rm -f "$tmp" >/dev/null 2>&1 || true
}

remove_gre_automation_backups() {
  local id="$1"
  local bakdir
  bakdir="$(automation_backup_dir)"

  [[ -d "$bakdir" ]] || { add_log "Backup dir not found: $bakdir"; return 0; }

  local removed_any=0

  if [[ -f "$bakdir/gre${id}.service" ]]; then
    rm -f "$bakdir/gre${id}.service" >/dev/null 2>&1 || true
    add_log "Removed backup: $bakdir/gre${id}.service"
    removed_any=1
  fi

  local fw
  shopt -s nullglob
  for fw in "$bakdir"/fw-gre${id}-*.service; do
    rm -f "$fw" >/dev/null 2>&1 || true
    add_log "Removed backup: $fw"
    removed_any=1
  done
  shopt -u nullglob

  [[ $removed_any -eq 0 ]] && add_log "No backup files found for GRE${id}."
}

uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Uninstall & Clean" "Select GRE to uninstall:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"

  while true; do
    render
    echo "${C_BOLD}Uninstall & Clean${C_RESET}"
    echo
    echo "Target: ${C_RED}GRE${id}${C_RESET}"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "${confirm^^}" == "NO" ]]; then
      add_log "Uninstall cancelled for GRE${id}"
      return 0
    fi
    if [[ "${confirm^^}" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  add_log "Stopping/Disabling gre${id}.service"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  mapfile -t FW_UNITS < <(get_fw_units_for_id "$id")
  if ((${#FW_UNITS[@]} > 0)); then
    local u
    for u in "${FW_UNITS[@]}"; do
      add_log "Stopping/Disabling $u"
      systemctl stop "$u" >/dev/null 2>&1 || true
      systemctl disable "$u" >/dev/null 2>&1 || true
    done
  else
    add_log "No forwarders found for GRE${id}"
  fi

  add_log "Removing unit files..."
  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/fw-gre${id}-*.service >/dev/null 2>&1 || true

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  add_log "Removing automation (cron/script/log/backup)..."
  remove_gre_automation_cron "$id"
  local a_script a_log
  a_script="$(automation_script_path "$id")"
  a_log="$(automation_log_path "$id")"
  [[ -f "$a_script" ]] && rm -f "$a_script" >/dev/null 2>&1 || true
  [[ -f "$a_log" ]] && rm -f "$a_log" >/dev/null 2>&1 || true
  remove_gre_automation_backups "$id"

  add_log "${C_GREEN}Uninstall completed for GRE${id}${C_RESET}"
  render
  pause_enter
}

# ----------------------------- MTU change ------------------------------
change_mtu() {
  local id mtu

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Change MTU" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  ask_until_valid "New MTU for gre (576-1600):" valid_mtu mtu

  add_log "Setting MTU on interface gre${id} to ${mtu}..."
  render
  ip link set "gre${id}" mtu "$mtu" >/dev/null 2>&1 || add_log "WARNING: gre${id} interface not found/up (will still patch unit)."

  local unit="/etc/systemd/system/gre${id}.service"
  local backup="/root/gre-backup/gre${id}.service"

  add_log "Patching unit file: $unit"
  render
  if [[ -f "$unit" ]]; then
    ensure_mtu_line_in_unit "$id" "$mtu" "$unit"
  else
    die_soft "Unit file not found: $unit"
    return 0
  fi

  if [[ -f "$backup" ]]; then
    add_log "Patching backup unit: $backup"
    render
    ensure_mtu_line_in_unit "$id" "$mtu" "$backup"
  else
    add_log "No backup unit found (skip): $backup"
  fi

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Restarting gre${id}.service..."
  systemctl restart "gre${id}.service" >/dev/null 2>&1 || add_log "WARNING: restart failed for gre${id}.service"

  add_log "${C_GREEN}Done:${C_RESET} GRE${id} MTU changed to ${mtu}"
  render
  pause_enter
}

# ----------------------------- Menus (smooth separation) ------------------------------
local_setup_menu() {
  local choice=""
  while true; do
    render
    echo "${C_BOLD}Local Setup (GRE only)${C_RESET}"
    echo
    echo "1) Setup IRAN local"
    echo "2) Setup KHAREJ local"
    echo "0) Back"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Selected: IRAN local setup"; iran_local_setup ;;
      2) add_log "Selected: KHAREJ local setup"; kharej_local_setup ;;
      0) return 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

tunnel_menu() {
  local choice=""
  while true; do
    render
    echo "${C_BOLD}Tunnel / Forwarder (separate)${C_RESET}"
    echo
    echo "1) Add/Install Forwarder ports for an existing GRE"
    echo "0) Back"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Selected: Add forwarder ports"; tunnel_forwarder_add_ports ;;
      0) return 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

main_menu() {
  local choice=""
  while true; do
    render
    echo "${C_BOLD}Main Menu${C_RESET}"
    echo
    echo "1) Local Setup (IRAN / KHAREJ)  [GRE only]"
    echo "2) Tunnel / Forwarder           [ports later]"
    echo "3) Services Management"
    echo "4) Uninstall & Clean"
    echo "5) Change MTU"
    echo "0) Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Open: Local Setup"; local_setup_menu ;;
      2) add_log "Open: Tunnel/Forwarder"; tunnel_menu ;;
      3) add_log "Open: Services Management"; services_management ;;
      4) add_log "Selected: Uninstall & Clean"; uninstall_clean ;;
      5) add_log "Selected: Change MTU"; change_mtu ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

ensure_root "$@"
add_log "TEEjAY started. GRE/Forwarder manager loaded."
main_menu
