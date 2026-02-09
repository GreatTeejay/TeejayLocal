#!/usr/bin/env bash
# teejay.sh
# TEEJAY - GRE + Forwarder Manager (IRAN/KHAREJ)
# Smooth UX: Local Setup جدا از Tunnel/Forwarder + Ping Test + Automation + Monitor + MTU presets

set +e
set +u
export LC_ALL=C

# ----------------------------- UI / THEME ------------------------------
LOG_LINES=()
LOG_MIN=4
LOG_MAX=12
BOX_W=77

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
  C_BLUE="$(tput setaf 4)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_MAGENTA=""; C_BLUE=""
fi

hr() {
  printf "%s%s%s\n" "${C_DIM}" "────────────────────────────────────────────────────────────────────────" "${C_RESET}"
}

ok() { printf "%s✔%s %s\n" "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf "%s⚠%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1"; }
err() { printf "%s✖%s %s\n" "${C_RED}" "${C_RESET}" "$1"; }

banner() {
  cat <<'EOF'
████████╗███████╗███████╗      ██╗ █████╗ ██╗   ██╗
╚══██╔══╝██╔════╝██╔════╝      ██║██╔══██╗╚██╗ ██╔╝
   ██║   █████╗  █████╗        ██║███████║ ╚████╔╝
   ██║   ██╔══╝  ██╔══╝   ██   ██║██╔══██║  ╚██╔╝
   ██║   ███████╗███████╗ ╚█████╔╝██║  ██║   ██║
   ╚═╝   ╚══════╝╚══════╝  ╚════╝ ╚═╝  ╚═╝   ╚═╝

                     T E E   J A Y
EOF
}

render_banner() {
  clear
  printf "%s" "${C_CYAN}${C_BOLD}"
  banner
  printf "%s\n" "${C_RESET}"
  hr
  printf "%s%s%s\n\n" "${C_BOLD}" "  Local Setup • Tunnel/Forwarder • Services • Tools" "${C_RESET}"
}

add_log() {
  local msg="$1"
  local ts
  ts="$(date +"%H:%M:%S")"
  # strip color codes for log alignment? (keep simple)
  LOG_LINES+=("[$ts] $msg")
  if ((${#LOG_LINES[@]} > LOG_MAX)); then
    LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
  fi
}

render() {
  render_banner

  local shown_count="${#LOG_LINES[@]}"
  local height=$shown_count
  ((height < LOG_MIN)) && height=$LOG_MIN
  ((height > LOG_MAX)) && height=$LOG_MAX

  printf "%s┌%s┐%s\n" "${C_DIM}" "$(printf '─%.0s' $(seq 1 $BOX_W))" "${C_RESET}"
  printf "%s│%-*s│%s\n" "${C_DIM}" "$BOX_W" " ACTION LOG" "${C_RESET}"

  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    printf "│ %-*s │\n" $((BOX_W-2)) "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-*s │\n" $((BOX_W-2)) ""
  done

  printf "%s└%s┘%s\n" "${C_DIM}" "$(printf '─%.0s' $(seq 1 $BOX_W))" "${C_RESET}"
  echo
}

pause_enter() {
  echo
  read -r -p "Press ENTER to return..." _
}

die_soft() {
  add_log "ERROR: $1"
  render
  pause_enter
}

# ----------------------------- Root / Utils ------------------------------
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
    echo "${C_BOLD}${prompt}${C_RESET}"
    read -r -e -p "> " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "Empty input. Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: $prompt $ans"
      return 0
    else
      add_log "Invalid: $prompt $ans"
    fi
  done
}

ask_yes_no() {
  # usage: ask_yes_no "Question" default(yes/no) -> echoes yes|no
  local q="$1"
  local def="${2:-yes}"
  local ans=""
  while true; do
    render
    echo "${C_BOLD}${q}${C_RESET}"
    echo
    echo "1) Yes"
    echo "2) No"
    echo "0) Back"
    echo
    read -r -p "Select: " ans
    ans="$(trim "$ans")"
    case "$ans" in
      1) echo "yes"; return 0 ;;
      2) echo "no"; return 0 ;;
      0) return 1 ;;
      "") [[ "$def" == "yes" ]] && echo "yes" || echo "no"; return 0 ;;
      *) add_log "Invalid selection." ;;
    esac
  done
}

ask_ports() {
  local prompt="Forward PORT(s) (example: 80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    echo "${C_BOLD}${prompt}${C_RESET}"
    read -r -e -p "> " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Please try again."
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
      add_log "Invalid ports: $raw"
      add_log "Examples: 80 | 80,2053 | 2050-2060"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports accepted: ${PORT_LIST[*]}"
    return 0
  done
}

# ----------------------------- Packages & Public IP ------------------------------
ensure_packages() {
  add_log "Checking packages: iproute2, socat, curl, iputils-ping"
  render
  local missing=()
  command -v ip    >/dev/null 2>&1 || missing+=("iproute2")
  command -v socat >/dev/null 2>&1 || missing+=("socat")
  command -v curl  >/dev/null 2>&1 || missing+=("curl")
  command -v ping  >/dev/null 2>&1 || missing+=("iputils-ping")

  if ((${#missing[@]}==0)); then
    add_log "All required packages are installed."
    return 0
  fi

  add_log "Installing: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

ensure_local_prereqs() {
  add_log "Checking packages: iproute2, curl, iputils-ping"
  render
  local missing=()
  command -v ip   >/dev/null 2>&1 || missing+=("iproute2")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v ping >/dev/null 2>&1 || missing+=("iputils-ping")

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

  detected="$(detect_public_ipv4 || true)"
  if valid_ipv4 "$detected"; then
    add_log "Detected ${label} public IP: ${detected}"
    local yn=""
    yn="$(ask_yes_no "Detected public IP is: ${detected}\n\nIs this your IP?" "yes")" || return 1
    if [[ "$yn" == "yes" ]]; then
      printf -v "$__var" '%s' "$detected"
      add_log "Using detected IP: $detected"
      return 0
    fi
  else
    add_log "Could not detect public IP automatically."
  fi

  local manual=""
  ask_until_valid "${label} public IP (manual):" valid_ipv4 manual
  printf -v "$__var" '%s' "$manual"
  return 0
}

# ----------------------------- Config / Backup ------------------------------
CFG_DIR=""
BACKUP_DIR=""

cfg_path() { local id="$1"; echo "${CFG_DIR}/gre${id}.conf"; }

cfg_write_kv() {
  local id="$1" k="$2" v="$3"
  local f; f="$(cfg_path "$id")"
  touch "$f" >/dev/null 2>&1 || true
  if grep -qE "^${k}=" "$f" 2>/dev/null; then
    sed -i -E "s|^${k}=.*|${k}=\"${v//\"/\\\"}\"|" "$f"
  else
    printf "%s=\"%s\"\n" "$k" "${v//\"/\\\"}" >> "$f"
  fi
}

cfg_load() {
  local id="$1"
  local f; f="$(cfg_path "$id")"
  [[ -f "$f" ]] || return 1
  # shellcheck disable=SC1090
  source "$f"
  return 0
}

backup_unit_files() {
  local id="$1"
  local u="/etc/systemd/system/gre${id}.service"
  [[ -f "$u" ]] && cp -a "$u" "${BACKUP_DIR}/gre${id}.service" >/dev/null 2>&1 || true
  for fw in /etc/systemd/system/fw-gre${id}-*.service; do
    [[ -f "$fw" ]] || continue
    cp -a "$fw" "${BACKUP_DIR}/$(basename "$fw")" >/dev/null 2>&1 || true
  done
}

# ----------------------------- GRE helpers / stability knobs ------------------------------
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

apply_net_tuning_common() {
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_keepalive_time=60 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_keepalive_probes=6 >/dev/null 2>&1 || true
}

ensure_mtu_line_in_unit() {
  local id="$1" mtu="$2" file="$3"
  [[ -f "$file" ]] || return 0

  if grep -qE "^ExecStart=/usr/bin/env ip link set gre${id} mtu[[:space:]]+[0-9]+$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/usr/bin/env ip link set gre${id} mtu[[:space:]]+[0-9]+$|ExecStart=/usr/bin/env ip link set gre${id} mtu ${mtu}|" "$file"
    add_log "Updated MTU line in: $file"
    return 0
  fi

  if grep -qE "^ExecStart=/usr/bin/env ip link set gre${id} up$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/usr/bin/env ip link set gre${id} up$|ExecStart=/usr/bin/env ip link set gre${id} mtu ${mtu}\nExecStart=/usr/bin/env ip link set gre${id} up|" "$file"
    add_log "Inserted MTU line in: $file"
    return 0
  fi

  printf "\nExecStart=/usr/bin/env ip link set gre%s mtu %s\n" "$id" "$mtu" >> "$file"
  add_log "WARNING: appended MTU line at end: $file"
}

pick_mtu_preset() {
  local choice=""
  while true; do
    render
    echo "${C_BOLD}MTU Setup (helps reduce GRE drops)${C_RESET}"
    echo
    echo "1) 1472  (often good)"
    echo "2) 1460"
    echo "3) 1420  (safe)"
    echo "4) Custom (576-1600)"
    echo "0) Skip"
    echo
    read -r -p "Select: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) echo "1472"; return 0 ;;
      2) echo "1460"; return 0 ;;
      3) echo "1420"; return 0 ;;
      4)
        local m=""
        ask_until_valid "Custom MTU (576-1600):" valid_mtu m
        echo "$m"
        return 0
        ;;
      0) echo ""; return 0 ;;
      *) add_log "Invalid selection." ;;
    esac
  done
}

make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5" mtu="${6:-}"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Service already exists: $unit"
    return 2
  fi

  add_log "Creating: $path"
  render

  local mtu_line=""
  if [[ -n "$mtu" ]]; then
    mtu_line="ExecStart=/usr/bin/env ip link set gre${id} mtu ${mtu}"
  fi

  cat >"$path" <<EOF
[Unit]
Description=TEEJAY GRE Tunnel to (${remote_ip})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/bin/bash -c "/usr/bin/env ip tunnel del gre${id} 2>/dev/null || true"
ExecStart=/usr/bin/env ip tunnel add gre${id} mode gre local ${local_ip} remote ${remote_ip} key ${key} nopmtudisc
ExecStart=/usr/bin/env ip addr add ${local_gre_ip}/30 dev gre${id}
${mtu_line}
ExecStart=/usr/bin/env ip link set gre${id} up
ExecStartPost=/bin/bash -c "/usr/bin/env sysctl -w net.ipv4.conf.gre${id}.rp_filter=0 >/dev/null 2>&1 || true"

ExecStop=/usr/bin/env ip link set gre${id} down
ExecStop=/usr/bin/env ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "GRE service created: $unit" || return 1
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

  add_log "Creating forwarder: fw-gre${id}-${port} -> ${target_ip}:${port}"
  render

  cat >"$path" <<EOF
[Unit]
Description=TEEJAY forward gre${id} ${port}
After=network-online.target gre${id}.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP4-LISTEN:${port},reuseaddr,fork TCP4:${target_ip}:${port}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "Forwarder created: fw-gre${id}-${port}" || add_log "Failed writing forwarder: $unit"
}

# ----------------------------- Monitor (reduce drops) ------------------------------
make_monitor_units() {
  local id="$1"
  local svc="/etc/systemd/system/teejay-mon-gre${id}.service"
  local tmr="/etc/systemd/system/teejay-mon-gre${id}.timer"

  if unit_exists "teejay-mon-gre${id}.service"; then
    add_log "Monitor already exists for GRE${id}"
    return 0
  fi

  add_log "Creating monitor for GRE${id} (ping peer every 10s)"
  render

  cat >"$svc" <<EOF
[Unit]
Description=TEEJAY Monitor GRE${id}
After=network-online.target gre${id}.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
set -e
CFG="${CFG_DIR}/gre${id}.conf"
[[ -f "\$CFG" ]] || exit 0
source "\$CFG"
T="\${PEER_GRE_IP:-}"
[[ -n "\$T" ]] || exit 0

if ping -n -c 1 -W 1 "\$T" >/dev/null 2>&1; then
  exit 0
fi

systemctl restart "gre${id}.service" >/dev/null 2>&1 || true
for fw in /etc/systemd/system/fw-gre${id}-*.service; do
  [[ -f "\$fw" ]] || continue
  systemctl restart "\$(basename "\$fw")" >/dev/null 2>&1 || true
done
'
EOF

  cat >"$tmr" <<EOF
[Unit]
Description=TEEJAY Monitor Timer GRE${id}

[Timer]
OnBootSec=15
OnUnitActiveSec=10
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

  systemd_reload
  add_log "Monitor created: teejay-mon-gre${id}.timer"
  return 0
}

enable_monitor() {
  local id="$1"
  make_monitor_units "$id" || return 1
  systemctl enable --now "teejay-mon-gre${id}.timer" >/dev/null 2>&1 || true
  add_log "Monitor enabled for GRE${id}"
}

disable_monitor() {
  local id="$1"
  systemctl disable --now "teejay-mon-gre${id}.timer" >/dev/null 2>&1 || true
  add_log "Monitor disabled for GRE${id}"
}

# ----------------------------- Local Setup (GRE only) ------------------------------
iran_local_setup() {
  local ID IRANIP KHAREJIP GREBASE MTU_VALUE=""
  add_log "Wizard: IRAN Local Setup (GRE only)"

  ask_until_valid "GRE Number:" is_int ID
  ensure_local_prereqs || { die_soft "Package installation failed."; return 0; }

  ask_local_ip_smooth "IRAN" IRANIP || { add_log "Cancelled."; return 0; }
  ask_until_valid "KHAREJ public IP (remote):" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP RANGE base (example: 10.90.90.0):" valid_gre_base GREBASE

  MTU_VALUE="$(pick_mtu_preset)"

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  add_log "KEY=${key} | IRAN(GRE)=${local_gre_ip} | KHAREJ(GRE)=${peer_gre_ip}"

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && { die_soft "gre${ID}.service already exists."; return 0; }
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  cfg_write_kv "$ID" "SIDE" "IRAN"
  cfg_write_kv "$ID" "LOCAL_PUBLIC_IP" "$IRANIP"
  cfg_write_kv "$ID" "REMOTE_PUBLIC_IP" "$KHAREJIP"
  cfg_write_kv "$ID" "GRE_BASE" "$GREBASE"
  cfg_write_kv "$ID" "LOCAL_GRE_IP" "$local_gre_ip"
  cfg_write_kv "$ID" "PEER_GRE_IP" "$peer_gre_ip"
  cfg_write_kv "$ID" "KEY" "$key"
  cfg_write_kv "$ID" "MTU" "$MTU_VALUE"

  add_log "Reloading systemd..."
  systemd_reload
  add_log "Starting gre${ID}.service ..."
  enable_now "gre${ID}.service"

  apply_net_tuning_common
  backup_unit_files "$ID"

  render
  ok "Local GRE created successfully."
  echo
  echo "${C_BOLD}Summary:${C_RESET}"
  echo "  GRE ID         : ${ID}"
  echo "  Side           : IRAN"
  echo "  Local Public   : ${IRANIP}"
  echo "  Remote Public  : ${KHAREJIP}"
  echo "  Local GRE IP   : ${local_gre_ip}"
  echo "  Peer  GRE IP   : ${peer_gre_ip}"
  echo "  MTU            : ${MTU_VALUE:-default}"
  echo
  echo "${C_BOLD}Status:${C_RESET}"
  show_unit_status_brief "gre${ID}.service"
  echo
  warn "Next step: Tunnel / Forwarder -> Add ports (whenever you want)"
  pause_enter
}

kharej_local_setup() {
  local ID KHAREJIP IRANIP GREBASE MTU_VALUE=""
  add_log "Wizard: KHAREJ Local Setup (GRE only)"

  ask_until_valid "GRE Number (same as IRAN):" is_int ID
  ensure_local_prereqs || { die_soft "Package installation failed."; return 0; }

  ask_local_ip_smooth "KHAREJ" KHAREJIP || { add_log "Cancelled."; return 0; }
  ask_until_valid "IRAN public IP (remote):" valid_ipv4 IRANIP
  ask_until_valid "GRE IP RANGE base (example: 10.90.90.0):" valid_gre_base GREBASE

  MTU_VALUE="$(pick_mtu_preset)"

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  add_log "KEY=${key} | KHAREJ(GRE)=${local_gre_ip} | IRAN(GRE)=${peer_gre_ip}"

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && { die_soft "gre${ID}.service already exists."; return 0; }
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  cfg_write_kv "$ID" "SIDE" "KHAREJ"
  cfg_write_kv "$ID" "LOCAL_PUBLIC_IP" "$KHAREJIP"
  cfg_write_kv "$ID" "REMOTE_PUBLIC_IP" "$IRANIP"
  cfg_write_kv "$ID" "GRE_BASE" "$GREBASE"
  cfg_write_kv "$ID" "LOCAL_GRE_IP" "$local_gre_ip"
  cfg_write_kv "$ID" "PEER_GRE_IP" "$peer_gre_ip"
  cfg_write_kv "$ID" "KEY" "$key"
  cfg_write_kv "$ID" "MTU" "$MTU_VALUE"

  add_log "Reloading systemd..."
  systemd_reload
  add_log "Starting gre${ID}.service ..."
  enable_now "gre${ID}.service"

  apply_net_tuning_common
  backup_unit_files "$ID"

  render
  ok "Local GRE created successfully."
  echo
  echo "${C_BOLD}Summary:${C_RESET}"
  echo "  GRE ID         : ${ID}"
  echo "  Side           : KHAREJ"
  echo "  Local Public   : ${KHAREJIP}"
  echo "  Remote Public  : ${IRANIP}"
  echo "  Local GRE IP   : ${local_gre_ip}"
  echo "  Peer  GRE IP   : ${peer_gre_ip}"
  echo "  MTU            : ${MTU_VALUE:-default}"
  echo
  echo "${C_BOLD}Status:${C_RESET}"
  show_unit_status_brief "gre${ID}.service"
  echo
  warn "Next step: Tunnel / Forwarder -> Add ports (whenever you want)"
  pause_enter
}

# ----------------------------- Tunnel / Forwarder (FIXED) ------------------------------
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

get_gre_cidr() {
  local id="$1"
  ip -4 addr show dev "gre${id}" 2>/dev/null | awk '/inet /{print $2}' | head -n1
}

# ✅ FIX: compute peer correctly for /30 based on current local host (.1 or .2)
gre_peer_ip_from_cidr() {
  local cidr="$1"
  local ip mask
  ip="${cidr%/*}"
  mask="${cidr#*/}"

  valid_ipv4 "$ip" || return 1
  [[ "$mask" == "30" ]] || return 2

  IFS='.' read -r a b c d <<<"$ip"
  local base=$(( d & 252 ))   # network base last octet
  local h1=$(( base + 1 ))
  local h2=$(( base + 2 ))

  if (( d == h1 )); then
    echo "${a}.${b}.${c}.${h2}"
    return 0
  elif (( d == h2 )); then
    echo "${a}.${b}.${c}.${h1}"
    return 0
  fi

  return 3
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

tunnel_forwarder_add_ports() {
  local -a PORT_LIST=()
  local id cidr target_ip

  ensure_packages || { die_soft "Package installation failed."; return 0; }

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

  # ✅ Best: use config PEER_GRE_IP if exists (no guessing)
  if cfg_load "$id" && valid_ipv4 "${PEER_GRE_IP:-}"; then
    target_ip="${PEER_GRE_IP}"
    add_log "Using PEER_GRE_IP from config: ${target_ip}"
  else
    # fallback: compute from live gre CIDR
    cidr="$(get_gre_cidr "$id")"
    if [[ -z "$cidr" ]]; then
      die_soft "Cannot detect inet on gre${id}. Is gre${id} UP?"
      return 0
    fi
    add_log "Detected gre${id} inet: ${cidr}"

    target_ip="$(gre_peer_ip_from_cidr "$cidr")"
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      die_soft "gre${id} mask is not /30 (found: ${cidr})."
      return 0
    elif [[ $rc -ne 0 || -z "$target_ip" ]]; then
      die_soft "Failed to compute peer from: ${cidr}"
      return 0
    fi
    add_log "Computed peer IP from /30: ${target_ip}"
  fi

  add_log "Creating forwarders..."
  local p
  for p in "${PORT_LIST[@]}"; do
    make_fw_service "$id" "$p" "$target_ip"
  done

  cfg_write_kv "$id" "PORTS" "${PORT_LIST[*]}"

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Enable & Start forwarders..."
  for p in "${PORT_LIST[@]}"; do
    enable_now "fw-gre${id}-${p}.service"
  done

  backup_unit_files "$id"

  render
  ok "Forwarders installed."
  echo
  echo "${C_BOLD}Forwarder Summary:${C_RESET}"
  echo "  GRE ID   : ${id}"
  echo "  Target   : ${target_ip}"
  echo "  Ports    : ${PORT_LIST[*]}"
  echo
  echo "${C_BOLD}Status:${C_RESET}"
  for p in "${PORT_LIST[@]}"; do
    echo
    show_unit_status_brief "fw-gre${id}-${p}.service"
  done
  pause_enter
}

# ----------------------------- Tools: Ping Test (10s) ------------------------------
ping_test_10s() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Ping Test (10 seconds)" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  if ! cfg_load "$id"; then
    die_soft "Config not found for GRE${id} (${CFG_DIR}/gre${id}.conf). Run Local Setup first."
    return 0
  fi

  local target="${PEER_GRE_IP:-}"
  if ! valid_ipv4 "$target"; then
    die_soft "PEER_GRE_IP is missing/invalid in config for GRE${id}."
    return 0
  fi

  add_log "Ping target for GRE${id}: ${target}"
  render
  echo "${C_BOLD}Pinging for 10 seconds...${C_RESET}"
  echo "GRE${id} SIDE=${SIDE:-unknown}  ->  PEER_GRE_IP=${target}"
  echo

  if command -v timeout >/dev/null 2>&1; then
    timeout 10 ping -n "$target"
    local rc=$?
    echo
    [[ $rc -eq 0 ]] && ok "Ping OK" || err "Ping FAILED (rc=$rc)"
  else
    ping -n -c 10 -i 1 "$target"
    local rc=$?
    echo
    [[ $rc -eq 0 ]] && ok "Ping OK" || err "Ping FAILED (rc=$rc)"
  fi

  pause_enter
}

# ----------------------------- Automation ------------------------------
automation_fast_rebuild() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Automation: Fast Rebuild" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  add_log "Fast rebuild for GRE${id}..."
  render

  for fw in /etc/systemd/system/fw-gre${id}-*.service; do
    [[ -f "$fw" ]] || continue
    systemctl stop "$(basename "$fw")" >/dev/null 2>&1 || true
  done

  systemctl restart "gre${id}.service" >/dev/null 2>&1 || true

  for fw in /etc/systemd/system/fw-gre${id}-*.service; do
    [[ -f "$fw" ]] || continue
    systemctl restart "$(basename "$fw")" >/dev/null 2>&1 || true
  done

  apply_net_tuning_common
  add_log "Fast rebuild done."
  render
  show_unit_status_brief "gre${id}.service"
  pause_enter
}

automation_restore_from_backup() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Automation: Restore From Backup" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  local bak_gre="${BACKUP_DIR}/gre${id}.service"
  if [[ ! -f "$bak_gre" ]]; then
    die_soft "Backup not found: $bak_gre"
    return 0
  fi

  add_log "Restoring GRE${id} from backups..."
  render

  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  for fw in /etc/systemd/system/fw-gre${id}-*.service; do
    [[ -f "$fw" ]] || continue
    systemctl stop "$(basename "$fw")" >/dev/null 2>&1 || true
    systemctl disable "$(basename "$fw")" >/dev/null 2>&1 || true
  done

  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/fw-gre${id}-*.service >/dev/null 2>&1 || true

  cp -a "$bak_gre" "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  for fw_bak in "${BACKUP_DIR}"/fw-gre${id}-*.service; do
    [[ -f "$fw_bak" ]] || continue
    cp -a "$fw_bak" "/etc/systemd/system/$(basename "$fw_bak")" >/dev/null 2>&1 || true
  done

  systemd_reload

  systemctl enable --now "gre${id}.service" >/dev/null 2>&1 || true
  for fw in /etc/systemd/system/fw-gre${id}-*.service; do
    [[ -f "$fw" ]] || continue
    systemctl enable --now "$(basename "$fw")" >/dev/null 2>&1 || true
  done

  apply_net_tuning_common
  add_log "Restore completed."
  render
  show_unit_status_brief "gre${id}.service"
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
        systemctl --no-pager --full status "$unit" 2>&1 | sed -n '1,20p'
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
    echo "3) Monitor timers"
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
          id="${GRE_IDS[$MENU_SELECTED]}"
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
          u="${FW_UNITS[$MENU_SELECTED]}"
          add_log "Forwarder selected."
          service_action_menu "$u"
        fi
        ;;
      3)
        mapfile -t GRE_IDS < <(get_gre_ids)
        local -a GRE_LABELS=()
        local id
        for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done
        if menu_select_index "Monitor Timers" "Select GRE:" "${GRE_LABELS[@]}"; then
          id="${GRE_IDS[$MENU_SELECTED]}"
          while true; do
            render
            echo "${C_BOLD}Monitor for GRE${id}${C_RESET}"
            echo
            echo "1) Enable monitor (ping peer every 10s, auto-restart)"
            echo "2) Disable monitor"
            echo "3) Status"
            echo "0) Back"
            echo
            local a=""
            read -r -p "Select: " a
            a="$(trim "$a")"
            case "$a" in
              1) enable_monitor "$id" ;;
              2) disable_monitor "$id" ;;
              3) render; systemctl --no-pager --full status "teejay-mon-gre${id}.timer" 2>&1 | sed -n '1,20p'; pause_enter ;;
              0) break ;;
              *) add_log "Invalid option." ;;
            esac
          done
        fi
        ;;
      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

# ----------------------------- Uninstall & Clean ------------------------------
uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Uninstall & Clean" "Select GRE to uninstall:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  id="${GRE_IDS[$MENU_SELECTED]}"

  local yn=""
  yn="$(ask_yes_no "Uninstall GRE${id} and all forwarders/monitor/config?\n\nThis cannot be undone." "no")" || return 0
  [[ "$yn" == "yes" ]] || { add_log "Cancelled."; return 0; }

  add_log "Stopping/Disabling gre${id}.service"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  for fw in /etc/systemd/system/fw-gre${id}-*.service; do
    [[ -f "$fw" ]] || continue
    systemctl stop "$(basename "$fw")" >/dev/null 2>&1 || true
    systemctl disable "$(basename "$fw")" >/dev/null 2>&1 || true
  done

  systemctl disable --now "teejay-mon-gre${id}.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/teejay-mon-gre${id}.service" "/etc/systemd/system/teejay-mon-gre${id}.timer" >/dev/null 2>&1 || true

  add_log "Removing unit files..."
  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/fw-gre${id}-*.service >/dev/null 2>&1 || true

  add_log "Removing config..."
  rm -f "$(cfg_path "$id")" >/dev/null 2>&1 || true

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  add_log "Uninstall completed for GRE${id}"
  render
  ok "Removed successfully."
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
  ip link set "gre${id}" mtu "$mtu" >/dev/null 2>&1 || add_log "WARNING: gre${id} interface not found/up (unit will be patched)."

  local unit="/etc/systemd/system/gre${id}.service"
  local backup="${BACKUP_DIR}/gre${id}.service"

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
  fi

  cfg_write_kv "$id" "MTU" "$mtu"

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Restarting gre${id}.service..."
  systemctl restart "gre${id}.service" >/dev/null 2>&1 || add_log "WARNING: restart failed for gre${id}.service"

  add_log "Done: GRE${id} MTU changed to ${mtu}"
  render
  ok "MTU updated."
  pause_enter
}

# ----------------------------- Menus ------------------------------
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

tools_menu() {
  local choice=""
  while true; do
    render
    echo "${C_BOLD}Tools${C_RESET}"
    echo
    echo "1) Ping test (10 seconds) to peer GRE IP"
    echo "2) Automation: Fast rebuild (restart GRE + forwarders)"
    echo "3) Automation: Restore from backup (reinstall saved units)"
    echo "0) Back"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) ping_test_10s ;;
      2) automation_fast_rebuild ;;
      3) automation_restore_from_backup ;;
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
    echo "2) Tunnel / Forwarder           [add ports later]"
    echo "3) Services Management          [GRE/FW/Monitor]"
    echo "4) Tools                        [Ping/Automation]"
    echo "5) Uninstall & Clean"
    echo "6) Change MTU"
    echo "0) Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) add_log "Open: Local Setup"; local_setup_menu ;;
      2) add_log "Open: Tunnel/Forwarder"; tunnel_menu ;;
      3) add_log "Open: Services Management"; services_management ;;
      4) add_log "Open: Tools"; tools_menu ;;
      5) add_log "Selected: Uninstall & Clean"; uninstall_clean ;;
      6) add_log "Selected: Change MTU"; change_mtu ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

# ----------------------------- Boot ------------------------------
ensure_root "$@"

# init dirs AFTER root (important fix)
CFG_DIR="/etc/teejay"
BACKUP_DIR="/root/teejay-backup"
mkdir -p "$CFG_DIR" "$BACKUP_DIR" >/dev/null 2>&1 || true

add_log "TEEJAY started. GRE/Forwarder manager loaded."
main_menu
