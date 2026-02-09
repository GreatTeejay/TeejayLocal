#!/usr/bin/env bash
# teejay.sh — TEEJAY GRE + Forwarder Manager
# Goals (per your request):
# 1) Logo: "TEE JAY" واضح و خوش‌استایل
# 2) UI/UX بهتر و Smooth‌تر
# 3) Local Setup و Tunnel/Forwarder کاملاً جدا
# 4) Auto-detect IP + نمایش + سوال انگلیسی "Is this your IP?" با گزینه Yes/No و Manual
# 5) Ping Test 10s (به peer GRE بر اساس سمت)
# 6) Fix bugs (خصوصاً: انتخاب GRE در Uninstall + محاسبه target در Add Tunnel Port)
# 7) Automation (Rebuild/Regenerate) حفظ شود
# 8) بهبود پایداری GRE: MTU presets + sysctl tuning + optional monitor (light)

set +e
set +u
export LC_ALL=C

# ----------------------------- UI (Color-safe) -----------------------------
LOG_LINES=()
LOG_MIN=4
LOG_MAX=12

if command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_CYAN="$(tput setaf 6)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_RED="$(tput setaf 1)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

banner() {
cat <<'EOF'
████████╗███████╗███████╗      ██╗ █████╗ ██╗   ██╗
╚══██╔══╝██╔════╝██╔════╝      ██║██╔══██╗╚██╗ ██╔╝
   ██║   █████╗  █████╗        ██║███████║ ╚████╔╝
   ██║   ██╔══╝  ██╔══╝   ██   ██║██╔══██║  ╚██╔╝
   ██║   ███████╗███████╗ ╚█████╔╝██║  ██║   ██║
   ╚═╝   ╚══════╝╚══════╝  ╚════╝ ╚═╝  ╚═╝   ╚═╝

                 T  E  E     J  A  Y
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
  printf "%s%s%s\n" "${C_CYAN}${C_BOLD}" "$(banner)" "${C_RESET}"
  echo

  local shown_count="${#LOG_LINES[@]}"
  local height=$shown_count
  ((height < LOG_MIN)) && height=$LOG_MIN
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
  read -r -p "Press ENTER to return..." _
}

die_soft() {
  add_log "ERROR: $1"
  render
  pause_enter
}

# ----------------------------- Root / Utils -----------------------------
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
  is_int "$p" || return 1
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
      add_log "Empty input. Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: $prompt $ans"
      return 0
    else
      add_log "Invalid: $prompt $ans"
      add_log "Please enter a valid value."
    fi
  done
}

ask_yes_no_en() {
  # Usage: ask_yes_no_en "Question" -> returns 0=yes 1=no
  local q="$1"
  local ans=""
  while true; do
    render
    echo -e "${q}"
    echo
    echo "1) Yes"
    echo "2) No"
    echo
    read -r -p "Select: " ans
    ans="$(trim "$ans")"
    case "$ans" in
      1|y|Y|yes|YES) return 0 ;;
      2|n|N|no|NO) return 1 ;;
      *) add_log "Invalid selection. Choose 1 or 2." ;;
    esac
  done
}

# ----------------------------- Ports parsing -----------------------------
ask_ports() {
  local prompt="ForWard PORT (80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    read -r -e -p "$prompt " raw
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

# ----------------------------- Packages -----------------------------
ensure_iproute_only() {
  add_log "Checking required package: iproute2"
  render

  if command -v ip >/dev/null 2>&1; then
    add_log "iproute2 is already installed."
    return 0
  fi

  add_log "Installing missing package: iproute2"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y iproute2 >/dev/null 2>&1 && add_log "iproute2 installed successfully." || return 1
  return 0
}

ensure_packages() {
  add_log "Checking required packages: iproute2, socat, curl, iputils-ping"
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

  add_log "Installing missing packages: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

# ----------------------------- Public IP detect (Auto + Confirm) -----------------------------
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

ask_local_ip_auto_or_manual() {
  # Usage: ask_local_ip_auto_or_manual "IRAN" VAR
  local label="$1" __var="$2"
  local detected=""
  detected="$(detect_public_ipv4 || true)"

  if valid_ipv4 "$detected"; then
    add_log "Detected ${label} public IP: ${detected}"
    if ask_yes_no_en "Detected IP: ${detected}\nIs this your IP?"; then
      printf -v "$__var" '%s' "$detected"
      add_log "Using detected IP: ${detected}"
      return 0
    fi
  else
    add_log "Could not auto-detect public IP. Manual required."
  fi

  local manual=""
  ask_until_valid "${label} IP (manual):" valid_ipv4 manual
  printf -v "$__var" '%s' "$manual"
  return 0
}

# ----------------------------- MTU -----------------------------
valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  ((m>=576 && m<=1600))
}

pick_mtu_smooth() {
  local choice=""
  while true; do
    render
    echo "MTU Options (helps reduce GRE drops):"
    echo "1) Default (skip)"
    echo "2) 1472"
    echo "3) 1460"
    echo "4) 1420 (safe)"
    echo "5) Custom"
    echo "0) Back"
    echo
    read -r -p "Select: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) echo ""; return 0 ;;
      2) echo "1472"; return 0 ;;
      3) echo "1460"; return 0 ;;
      4) echo "1420"; return 0 ;;
      5)
        local m=""
        ask_until_valid "Custom MTU (576-1600):" valid_mtu m
        echo "$m"
        return 0
        ;;
      0) return 1 ;;
      *) add_log "Invalid selection." ;;
    esac
  done
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
  add_log "WARNING: appended MTU line at end: $file"
}

# ----------------------------- systemd helpers -----------------------------
systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }
unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }
enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }
stop_disable() { systemctl stop "$1" >/dev/null 2>&1; systemctl disable "$1" >/dev/null 2>&1; }

show_unit_status_brief() {
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,12p'
}

apply_sysctl_tuning() {
  # low-risk tuning for GRE stability
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  # keepalive helps long-lived NAT paths (not GRE itself, but forwarders)
  sysctl -w net.ipv4.tcp_keepalive_time=60 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_keepalive_probes=6 >/dev/null 2>&1 || true
}

# ----------------------------- GRE/Forwarder unit creation -----------------------------
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
    mtu_line="ExecStart=/sbin/ip link set gre${id} mtu ${mtu}"
  fi

  cat >"$path" <<EOF
[Unit]
Description=TEEJAY GRE Tunnel to (${remote_ip})
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
ExecStartPost=/bin/bash -c "/sbin/sysctl -w net.ipv4.conf.gre${id}.rp_filter=0 >/dev/null 2>&1 || true"
ExecStop=/sbin/ip link set gre${id} down
ExecStop=/sbin/ip tunnel del gre${id}

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

# ----------------------------- FIX: peer calc from /30 CIDR -----------------------------
# Old bug: always "network+2" which breaks when local is .2 (kharej side).
gre_peer_ip_from_cidr() {
  local cidr="$1"
  local ip mask
  ip="${cidr%/*}"
  mask="${cidr#*/}"

  valid_ipv4 "$ip" || return 1
  [[ "$mask" == "30" ]] || return 2

  IFS='.' read -r a b c d <<<"$ip"
  local base=$(( d & 252 ))
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

get_gre_cidr() {
  local id="$1"
  ip -4 addr show dev "gre${id}" 2>/dev/null | awk '/inet /{print $2}' | head -n1
}

# ----------------------------- LIST / SELECT GRE (FIX uninstall selection) -----------------------------
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

gre_id_exists() {
  local needle="$1"
  [[ "$needle" =~ ^[0-9]+$ ]] || return 1
  local id
  while IFS= read -r id; do
    [[ "$id" == "$needle" ]] && return 0
  done < <(get_gre_ids)
  return 1
}

select_gre_id() {
  # Prints selected id to stdout; returns 0 success / 1 back or none
  local -a ids=()
  mapfile -t ids < <(get_gre_ids)

  while true; do
    render
    echo "${C_BOLD}Select GRE ID${C_RESET}"
    echo
    if ((${#ids[@]}==0)); then
      echo "No GRE services found."
      echo
      read -r -p "Press ENTER to go back..." _
      return 1
    fi

    echo "Available GRE IDs:"
    echo
    local i
    for ((i=0; i<${#ids[@]}; i++)); do
      printf "  %d) GRE%s\n" $((i+1)) "${ids[$i]}"
    done
    echo "  0) Back"
    echo
    echo "Tip: You can also type GRE ID directly (example: 12)"
    echo

    local choice=""
    read -r -e -p "Select: " choice
    choice="$(trim "$choice")"

    [[ "$choice" == "0" ]] && return 1

    # direct id
    if [[ "$choice" =~ ^[0-9]+$ ]] && gre_id_exists "$choice"; then
      echo "$choice"
      return 0
    fi

    # index
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#ids[@]})); then
      echo "${ids[$((choice-1))]}"
      return 0
    fi

    add_log "Invalid selection: $choice"
  done
}

get_fw_units_for_id() {
  local id="$1"
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${id}-*.service" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E "^fw-gre${id}-[0-9]+\.service$" \
    | sort -V || true
}

get_all_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre*-*.service" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^fw-gre[0-9]+-[0-9]+\.service$' \
    | sort -V || true
}

# ----------------------------- LOCAL SETUP (GRE only) -----------------------------
# Separate from Tunnel/Forwarder
iran_local_setup() {
  local ID IRANIP KHAREJIP GREBASE MTU_VALUE=""
  ask_until_valid "GRE Number :" is_int ID

  ensure_packages || { die_soft "Package installation failed."; return 0; }

  # Auto detect local IP (Iran server)
  ask_local_ip_auto_or_manual "IRAN" IRANIP || { add_log "Cancelled."; return 0; }

  ask_until_valid "KHAREJ IP (remote) :" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP RANGE base (Example : 10.80.70.0):" valid_gre_base GREBASE

  MTU_VALUE="$(pick_mtu_smooth)" || { add_log "Cancelled."; return 0; }

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

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"

  apply_sysctl_tuning

  render
  echo "GRE IPs:"
  echo "  IRAN  : ${local_gre_ip}"
  echo "  KHAREJ: ${peer_gre_ip}"
  echo
  echo "Status:"
  show_unit_status_brief "gre${ID}.service"
  echo
  echo "${C_YELLOW}Next step:${C_RESET} Tunnel / Forwarder -> Add Tunnel Port (later)"
  pause_enter
}

kharej_local_setup() {
  local ID KHAREJIP IRANIP GREBASE MTU_VALUE=""
  ask_until_valid "GRE Number (Like IRAN PLEASE) :" is_int ID

  ensure_packages || { die_soft "Package installation failed."; return 0; }

  # Auto detect local IP (Kharej server)
  ask_local_ip_auto_or_manual "KHAREJ" KHAREJIP || { add_log "Cancelled."; return 0; }

  ask_until_valid "IRAN IP (remote) :" valid_ipv4 IRANIP
  ask_until_valid "GRE IP RANGE base (Example : 10.80.70.0) Like IRAN PLEASE:" valid_gre_base GREBASE

  MTU_VALUE="$(pick_mtu_smooth)" || { add_log "Cancelled."; return 0; }

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

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"

  apply_sysctl_tuning

  render
  echo "GRE IPs:"
  echo "  KHAREJ: ${local_gre_ip}"
  echo "  IRAN  : ${peer_gre_ip}"
  echo
  show_unit_status_brief "gre${ID}.service"
  echo
  echo "${C_YELLOW}Next step:${C_RESET} Tunnel / Forwarder -> Add Tunnel Port (later)"
  pause_enter
}

# ----------------------------- TUNNEL / FORWARDER (Add ports later) -----------------------------
add_tunnel_port() {
  local -a PORT_LIST=()
  local id cidr target_ip

  ensure_packages || { die_soft "Package installation failed."; return 0; }

  id="$(select_gre_id)" || return 0
  add_log "GRE selected: GRE${id}"

  ask_ports

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
    die_soft "Failed to compute peer target from: ${cidr}"
    return 0
  fi
  add_log "Peer target (computed): ${target_ip}"

  add_log "Creating forwarders for GRE${id}..."
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
  echo "GRE${id}:"
  echo "  inet   : ${cidr}"
  echo "  target : ${target_ip}"
  echo
  echo "Status:"
  for p in "${PORT_LIST[@]}"; do
    echo
    show_unit_status_brief "fw-gre${id}-${p}.service"
  done
  pause_enter
}

# ----------------------------- Ping Test (10 seconds) -----------------------------
ping_test_10s() {
  local id cidr peer
  ensure_packages || { die_soft "Package installation failed."; return 0; }

  id="$(select_gre_id)" || return 0
  cidr="$(get_gre_cidr "$id")"
  if [[ -z "$cidr" ]]; then
    die_soft "Cannot detect inet on gre${id}. Is gre${id} UP?"
    return 0
  fi
  peer="$(gre_peer_ip_from_cidr "$cidr")"
  if ! valid_ipv4 "$peer"; then
    die_soft "Failed to compute peer from ${cidr}"
    return 0
  fi

  render
  echo "${C_BOLD}Ping test (10 seconds)${C_RESET}"
  echo "GRE${id} -> peer: ${peer}"
  echo
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 ping -n "$peer"
  else
    ping -n -c 10 -i 1 "$peer"
  fi
  pause_enter
}

# ----------------------------- Services Management -----------------------------
service_action_menu() {
  local unit="$1"
  local action=""

  while true; do
    render
    echo "Selected: $unit"
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
    echo "Services ManageMent"
    echo
    echo "1) GRE"
    echo "2) Forwarder"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1)
        local id
        id="$(select_gre_id)" || continue
        add_log "GRE selected: GRE${id}"
        service_action_menu "gre${id}.service"
        ;;
      2)
        mapfile -t FW_UNITS < <(get_all_fw_units)
        if ((${#FW_UNITS[@]}==0)); then
          add_log "No forwarder services found."
          render
          pause_enter
          continue
        fi

        while true; do
          render
          echo "Forwarder Services"
          echo
          local i
          for ((i=0; i<${#FW_UNITS[@]}; i++)); do
            echo "$((i+1))) ${FW_UNITS[$i]}"
          done
          echo "0) Back"
          echo
          local ch=""
          read -r -p "Select: " ch
          ch="$(trim "$ch")"
          [[ "$ch" == "0" ]] && break
          if [[ "$ch" =~ ^[0-9]+$ ]] && ((ch>=1 && ch<=${#FW_UNITS[@]})); then
            service_action_menu "${FW_UNITS[$((ch-1))]}"
          else
            add_log "Invalid selection: $ch"
          fi
        done
        ;;
      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

# ----------------------------- Uninstall (FIXED selection) -----------------------------
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
  local id
  id="$(select_gre_id)" || return 0
  add_log "Uninstall target selected: GRE${id}"

  while true; do
    render
    echo "Uninstall & Clean"
    echo
    echo "Target: GRE${id}"
    echo "This will remove:"
    echo "  - /etc/systemd/system/gre${id}.service"
    echo "  - /etc/systemd/system/fw-gre${id}-*.service"
    echo "  - ALL autostart symlinks (*.wants) for gre${id} + fw-gre${id}-*"
    echo "  - cron + /usr/local/bin/sepehr-recreate-gre${id}.sh (if exists)"
    echo "  - /var/log/sepehr-gre${id}.log (if exists)"
    echo "  - /root/gre-backup/gre${id}.service (if exists)"
    echo "  - /root/gre-backup/fw-gre${id}-*.service (if exists)"
    echo "  - GRE interface + routes + neighbors + conntrack sessions (best effort)"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Uninstall cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  add_log "Stopping gre${id}.service (hard)"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  systemctl kill -s SIGKILL "gre${id}.service" >/dev/null 2>&1 || true
  add_log "Disabling gre${id}.service"
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "gre${id}.service" >/dev/null 2>&1 || true

  mapfile -t FW_UNITS < <(get_fw_units_for_id "$id")
  if ((${#FW_UNITS[@]} > 0)); then
    local u
    for u in "${FW_UNITS[@]}"; do
      add_log "Stopping $u (hard)"
      systemctl stop "$u" >/dev/null 2>&1 || true
      systemctl kill -s SIGKILL "$u" >/dev/null 2>&1 || true
      add_log "Disabling $u"
      systemctl disable "$u" >/dev/null 2>&1 || true
      systemctl reset-failed "$u" >/dev/null 2>&1 || true
    done
  else
    add_log "No forwarders found for GRE${id}"
  fi

  add_log "Flushing routes/addr/neigh/conntrack (best effort) for gre${id}"
  ip route flush dev "gre${id}" 2>/dev/null || true
  ip addr flush dev "gre${id}" 2>/dev/null || true
  ip link set "gre${id}" down 2>/dev/null || true
  ip tunnel del "gre${id}" 2>/dev/null || true
  ip link del "gre${id}" 2>/dev/null || true
  ip route flush cache 2>/dev/null || true
  ip neigh flush all 2>/dev/null || true

  if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -i "gre${id}" >/dev/null 2>&1 || true
    conntrack -D -o "gre${id}" >/dev/null 2>&1 || true
  fi

  sleep 1

  add_log "Removing unit files, drop-ins, and all autostart symlinks..."

  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  rm -rf "/etc/systemd/system/gre${id}.service.d" >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/fw-gre${id}-*.service >/dev/null 2>&1 || true
  rm -rf "/etc/systemd/system/fw-gre${id}-"*.service.d >/dev/null 2>&1 || true

  for d in /etc/systemd/system/*.wants /etc/systemd/system/*/*.wants; do
    rm -f "$d/gre${id}.service" >/dev/null 2>&1 || true
    rm -f "$d/fw-gre${id}-"*.service >/dev/null 2>&1 || true
  done

  rm -f "/run/systemd/generator"/*"gre${id}.service"* >/dev/null 2>&1 || true
  rm -f "/run/systemd/generator.late"/*"gre${id}.service"* >/dev/null 2>&1 || true
  rm -f "/run/systemd/generator"/*"fw-gre${id}-"*".service"* >/dev/null 2>&1 || true
  rm -f "/run/systemd/generator.late"/*"fw-gre${id}-"*".service"* >/dev/null 2>&1 || true

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  add_log "Removing automation (cron/script/log/backup) for GRE${id}..."
  remove_gre_automation_cron "$id"
  add_log "Cron entry removed (if existed)."

  local a_script a_log
  a_script="$(automation_script_path "$id")"
  a_log="$(automation_log_path "$id")"

  if [[ -f "$a_script" ]]; then
    rm -f "$a_script" >/dev/null 2>&1 || true
    add_log "Removed: $a_script"
  else
    add_log "No automation script found."
  fi

  if [[ -f "$a_log" ]]; then
    rm -f "$a_log" >/dev/null 2>&1 || true
    add_log "Removed: $a_log"
  else
    add_log "No automation log found."
  fi

  remove_gre_automation_backups "$id"

  add_log "Uninstall completed for GRE${id}"
  render
  pause_enter
}

# ----------------------------- Timezone helper (kept) -----------------------------
select_and_set_timezone() {
  local choice tz=""
  while true; do
    render
    echo "WARNING: You need set mutual Time to IRAN and Kharej Server"
    echo "select your server clock"
    echo
    echo "1) Germany (Europe/Berlin)"
    echo "2) Turkey (Europe/Istanbul)"
    echo "3) France (Europe/Paris)"
    echo "4) Netherlands (Europe/Amsterdam)"
    echo "5) Finland (Europe/Helsinki)"
    echo "6) England (Europe/London)"
    echo "7) Sweden (Europe/Stockholm)"
    echo "8) Russia (Europe/Moscow)"
    echo "9) USA (America/New_York)"
    echo "10) Canada (America/Toronto)"
    echo "11) UTC (Etc/UTC)"
    echo "0) Skip (no change)"
    echo

    read -r -p "Select: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) tz="Europe/Berlin" ;;
      2) tz="Europe/Istanbul" ;;
      3) tz="Europe/Paris" ;;
      4) tz="Europe/Amsterdam" ;;
      5) tz="Europe/Helsinki" ;;
      6) tz="Europe/London" ;;
      7) tz="Europe/Stockholm" ;;
      8) tz="Europe/Moscow" ;;
      9) tz="America/New_York" ;;
      10) tz="America/Toronto" ;;
      11) tz="Etc/UTC" ;;
      0) add_log "Timezone setup skipped."; return 0 ;;
      *) add_log "Invalid selection: $choice"; continue ;;
    esac

    add_log "Setting timezone: $tz"
    render

    timedatectl set-timezone "$tz" >/dev/null 2>&1 || { add_log "ERROR: failed set-timezone"; return 1; }
    timedatectl set-ntp true >/dev/null 2>&1 || { add_log "ERROR: failed set-ntp true"; return 1; }

    local now
    now="$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z')"
    add_log "Timezone set OK: $tz | Now: $now"
    return 0
  done
}

# ----------------------------- Automation (kept, minimal edits) -----------------------------
recreate_automation() {
  local id side mode val script cron_line

  id="$(select_gre_id)" || return 0

  while true; do
    render
    echo "Select Side"
    echo "1) IRAN SIDE"
    echo "2) KHAREJ SIDE"
    echo
    read -r -p "Select: " side
    case "$side" in
      1) side="IRAN"; break ;;
      2) side="KHAREJ"; break ;;
      *) add_log "Invalid side" ;;
    esac
  done

  select_and_set_timezone || { die_soft "Timezone/NTP setup failed."; return 0; }

  while true; do
    render
    echo "Time Mode"
    echo "1) Hourly time (1-12)"
    echo "2) Minute time (15-45)"
    echo
    read -r -p "Select: " mode
    [[ "$mode" == "1" || "$mode" == "2" ]] && break
    add_log "Invalid mode"
  done

  while true; do
    render
    read -r -p "how much time set for cron? " val
    if [[ "$mode" == "1" && "$val" =~ ^([1-9]|1[0-2])$ ]]; then break; fi
    if [[ "$mode" == "2" && "$val" =~ ^(1[5-9]|[2-3][0-9]|4[0-5])$ ]]; then break; fi
    add_log "Invalid time value"
  done

  script="/usr/local/bin/sepehr-recreate-gre${id}.sh"

  cat > "$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ID="__ID__"
SIDE="__SIDE__"

UNIT="/etc/systemd/system/gre${ID}.service"
LOG_FILE="/var/log/sepehr-gre${ID}.log"
TZ="Europe/Berlin"

mkdir -p /var/log >/dev/null 2>&1 || true
touch "$LOG_FILE" >/dev/null 2>&1 || true

log() {
  echo "[$(TZ="$TZ" date '+%Y-%m-%d %H:%M %Z')] $1" >> "$LOG_FILE"
}

list_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${ID}-*.service" 2>/dev/null | sort -V || true
}

[[ -f "$UNIT" ]] || { log "ERROR: GRE${ID} unit not found: $UNIT"; exit 1; }

DAY=$(TZ="$TZ" date +%d)
HOUR=$(TZ="$TZ" date +%H)
AMPM=$(TZ="$TZ" date +%p)

DAY_DEC=$((10#$DAY))
HOUR_DEC=$((10#$HOUR))
datetimecountnumber=$((DAY_DEC + HOUR_DEC))

old_ip=$(grep -oP 'ip addr add \K([0-9.]+)' "$UNIT" | head -n1 || true)
[[ -n "$old_ip" ]] || { log "ERROR: Cannot detect old IP in unit"; exit 1; }

IFS='.' read -r b1 oldblocknumb b3 b4 <<< "$old_ip"

if (( oldblocknumb > 230 )); then
  oldblock_calc=4
else
  oldblock_calc=$oldblocknumb
fi

if (( DAY_DEC <= 15 )); then
  if [[ "$AMPM" == "AM" ]]; then
    newblock=$((datetimecountnumber + oldblock_calc + 7))
  else
    newblock=$((datetimecountnumber + oldblock_calc - 13))
  fi
else
  if [[ "$AMPM" == "AM" ]]; then
    newblock=$((datetimecountnumber + oldblock_calc + 3))
  else
    newblock=$((datetimecountnumber + oldblock_calc - 5))
  fi
fi

(( newblock > 245 )) && newblock=245
(( newblock < 0 )) && newblock=0

new_ip="${b1}.${newblock}.${datetimecountnumber}.${b4}"

# NOTE: this automation assumes .2 is peer (works for IRAN local=.1). If you use KHAREJ local=.2, forwarder logic differs.
# Keeping your original behavior as requested (no breaking change).
peer_ip="${new_ip%.*}.2"

systemctl stop "gre${ID}.service" >/dev/null 2>&1 || true
systemctl kill -s SIGKILL "gre${ID}.service" >/dev/null 2>&1 || true
systemctl disable "gre${ID}.service" >/dev/null 2>&1 || true
systemctl reset-failed "gre${ID}.service" >/dev/null 2>&1 || true

if [[ "$SIDE" == "IRAN" ]]; then
  while IFS= read -r fw_path; do
    [[ -n "$fw_path" ]] || continue
    fw_unit="$(basename "$fw_path")"
    systemctl stop "$fw_unit" >/dev/null 2>&1 || true
    systemctl kill -s SIGKILL "$fw_unit" >/dev/null 2>&1 || true
    systemctl disable "$fw_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$fw_unit" >/dev/null 2>&1 || true
  done < <(list_fw_units)
fi

ip route flush dev "gre${ID}" 2>/dev/null || true
ip addr flush dev "gre${ID}" 2>/dev/null || true
ip link set "gre${ID}" down 2>/dev/null || true
ip route flush cache 2>/dev/null || true
ip neigh flush all 2>/dev/null || true

if command -v conntrack >/dev/null 2>&1; then
  conntrack -D -i "gre${ID}" >/dev/null 2>&1 || true
  conntrack -D -o "gre${ID}" >/dev/null 2>&1 || true
fi

sleep 1

sed -i.bak -E "s/ip addr add [0-9.]+\/30/ip addr add ${new_ip}\/30/" "$UNIT"

if [[ "$SIDE" == "IRAN" ]]; then
  while IFS= read -r fw_path; do
    [[ -n "$fw_path" ]] || continue
    sed -i.bak -E "s/(TCP4:)[0-9.]+(:[0-9]+)/\1${peer_ip}\2/g" "$fw_path"
  done < <(list_fw_units)
fi

systemctl daemon-reload >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf."gre${ID}".rp_filter=0 >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true

systemctl enable --now "gre${ID}.service" >/dev/null 2>&1 || true

if [[ "$SIDE" == "IRAN" ]]; then
  for fw_unit in /etc/systemd/system/fw-gre${ID}-*.service; do
    [[ -f "$fw_unit" ]] || continue
    systemctl enable --now "$(basename "$fw_unit")" >/dev/null 2>&1 || true
  done
fi

PORTS=""
if [[ "$SIDE" == "IRAN" ]]; then
  PORTS=$(
    find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${ID}-*.service" 2>/dev/null \
      | sed -n 's/.*-\([0-9]\+\)\.service/\1/p' \
      | sort -n \
      | paste -sd, - \
      || true
  )
fi

log "GRE${ID} | SIDE=$SIDE | OLD IP=$old_ip | NEW IP=$new_ip | PEER IP=$peer_ip | PORTS=$PORTS"
EOF

  sed -i "s/__ID__/${id}/g; s/__SIDE__/${side}/g" "$script"
  chmod +x "$script"

  if [[ "$mode" == "1" ]]; then
    cron_line="0 */${val} * * * ${script}"
  else
    cron_line="*/${val} * * * * ${script}"
  fi

  (crontab -l 2>/dev/null | grep -vF "$script" || true; echo "$cron_line") | crontab -

  add_log "Automation created for GRE${id}"
  add_log "Script: ${script}"
  add_log "Log   : /var/log/sepehr-gre${id}.log"
  add_log "Cron  : ${cron_line}"
  pause_enter
}

recreate_automation_mode() {
  # Your original rebuild-from-backup automation (kept as-is with only selection fix)
  local id side mode val script cron_line

  id="$(select_gre_id)" || return 0

  while true; do
    render
    echo "Select Side"
    echo "1) IRAN SIDE"
    echo "2) KHAREJ SIDE"
    echo
    read -r -p "Select: " side
    case "$side" in
      1) side="IRAN"; break ;;
      2) side="KHAREJ"; break ;;
      *) add_log "Invalid side" ;;
    esac
  done

  select_and_set_timezone || { die_soft "Timezone/NTP setup failed."; return 0; }

  while true; do
    render
    echo "Time Mode"
    echo "1) Hourly time (1-12)"
    echo "2) Minute time (15-45)"
    echo
    read -r -p "Select: " mode
    [[ "$mode" == "1" || "$mode" == "2" ]] && break
    add_log "Invalid mode"
  done

  while true; do
    render
    read -r -p "how much time set for cron? " val
    if [[ "$mode" == "1" && "$val" =~ ^([1-9]|1[0-2])$ ]]; then break; fi
    if [[ "$mode" == "2" && "$val" =~ ^(1[5-9]|[2-3][0-9]|4[0-5])$ ]]; then break; fi
    add_log "Invalid time value"
  done

  script="/usr/local/bin/sepehr-recreate-gre${id}.sh"

  cat > "$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ID="__ID__"
SIDE="__SIDE__"

UNIT="/etc/systemd/system/gre${ID}.service"
LOG_FILE="/var/log/sepehr-gre${ID}.log"
BACKUP_DIR="/root/gre-backup"
TZ="Europe/Berlin"

mkdir -p /var/log >/dev/null 2>&1 || true
touch "$LOG_FILE" >/dev/null 2>&1 || true
mkdir -p "$BACKUP_DIR" >/dev/null 2>&1 || true

log() { echo "[$(TZ="$TZ" date '+%Y-%m-%d %H:%M %Z')] $1" >> "$LOG_FILE"; }

list_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${ID}-*.service" 2>/dev/null | sort -V || true
}

if [[ ! -f "$UNIT" ]]; then
  log "ERROR: gre unit not found: $UNIT"
  exit 1
fi

GRE_BAK="$BACKUP_DIR/gre${ID}.service"
if [[ ! -f "$GRE_BAK" ]]; then
  cp -a "$UNIT" "$GRE_BAK"
  log "BACKUP created: $GRE_BAK"
else
  log "BACKUP exists: $GRE_BAK"
fi

FW_COUNT=0
if [[ "$SIDE" == "IRAN" ]]; then
  while IFS= read -r fw_path; do
    [[ -n "$fw_path" ]] || continue
    fw_base="$(basename "$fw_path")"
    fw_bak="$BACKUP_DIR/$fw_base"
    if [[ ! -f "$fw_bak" ]]; then
      cp -a "$fw_path" "$fw_bak"
      log "BACKUP created: $fw_bak"
    else
      log "BACKUP exists: $fw_bak"
    fi
    ((FW_COUNT++)) || true
  done < <(list_fw_units)
fi

systemctl stop "gre${ID}.service" >/dev/null 2>&1 || true
systemctl kill -s SIGKILL "gre${ID}.service" >/dev/null 2>&1 || true
systemctl disable "gre${ID}.service" >/dev/null 2>&1 || true
systemctl reset-failed "gre${ID}.service" >/dev/null 2>&1 || true
ip route flush dev "gre${ID}" 2>/dev/null || true
ip addr flush dev "gre${ID}" 2>/dev/null || true
ip link set "gre${ID}" down 2>/dev/null || true
ip tunnel del "gre${ID}" 2>/dev/null || true
ip link del "gre${ID}" 2>/dev/null || true
ip neigh flush all 2>/dev/null || true
ip route flush cache 2>/dev/null || true
if command -v conntrack >/dev/null 2>&1; then
  conntrack -D -i "gre${ID}" >/dev/null 2>&1 || true
  conntrack -D -o "gre${ID}" >/dev/null 2>&1 || true
fi

rm -f "/etc/systemd/system/gre${ID}.service" >/dev/null 2>&1 || true
for d in /etc/systemd/system/*.wants /etc/systemd/system/*/*.wants; do
  rm -f "$d/gre${ID}.service" >/dev/null 2>&1 || true
done
rm -rf "/etc/systemd/system/gre${ID}.service.d" >/dev/null 2>&1 || true

if [[ "$SIDE" == "IRAN" ]]; then
  while IFS= read -r fw_path; do
    [[ -n "$fw_path" ]] || continue
    fw_unit="$(basename "$fw_path")"
    systemctl stop "$fw_unit" >/dev/null 2>&1 || true
    systemctl disable "$fw_unit" >/dev/null 2>&1 || true
  done < <(list_fw_units)
fi

rm -f "$UNIT" >/dev/null 2>&1 || true

if [[ "$SIDE" == "IRAN" ]]; then
  rm -f /etc/systemd/system/fw-gre${ID}-*.service >/dev/null 2>&1 || true
  rm -rf "/etc/systemd/system/fw-gre${ID}-"*.service.d >/dev/null 2>&1 || true
  for d in /etc/systemd/system/*.wants /etc/systemd/system/*/*.wants; do
    rm -f "$d/fw-gre${ID}-"*.service >/dev/null 2>&1 || true
  done
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed  >/dev/null 2>&1 || true

if [[ ! -f "$GRE_BAK" ]]; then
  log "ERROR: missing gre backup: $GRE_BAK"
  exit 1
fi
cp -a "$GRE_BAK" "$UNIT"

RESTORED_FW=0
if [[ "$SIDE" == "IRAN" ]]; then
  for fw_bak in "$BACKUP_DIR"/fw-gre${ID}-*.service; do
    [[ -f "$fw_bak" ]] || continue
    cp -a "$fw_bak" "/etc/systemd/system/$(basename "$fw_bak")"
    ((RESTORED_FW++)) || true
  done
fi

systemctl daemon-reload >/dev/null 2>&1 || true

systemctl enable --now "gre${ID}.service" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf."gre${ID}".rp_filter=0 >/dev/null 2>&1 || true

if [[ "$SIDE" == "IRAN" ]]; then
  for fw_unit in /etc/systemd/system/fw-gre${ID}-*.service; do
    [[ -f "$fw_unit" ]] || continue
    systemctl enable --now "$(basename "$fw_unit")" >/dev/null 2>&1 || true
  done
fi

log "Rebuild OK | GRE${ID} | SIDE=$SIDE | restored gre + fw from backups | fw_backup_seen=$FW_COUNT | fw_restored=$RESTORED_FW"
EOF

  sed -i "s/__ID__/${id}/g; s/__SIDE__/${side}/g" "$script"
  chmod +x "$script"

  if [[ "$mode" == "1" ]]; then
    cron_line="0 */${val} * * * ${script}"
  else
    cron_line="*/${val} * * * * ${script}"
  fi

  (crontab -l 2>/dev/null | grep -vF "$script" || true; echo "$cron_line") | crontab -

  add_log "Automation created for GRE${id}"
  add_log "Script: ${script}"
  add_log "Backup: /root/gre-backup/ (gre${id}.service + fw-gre${id}-*.service)"
  add_log "Log   : /var/log/sepehr-gre${id}.log"
  add_log "Cron  : ${cron_line}"
  pause_enter
}

# ----------------------------- Change MTU -----------------------------
change_mtu() {
  local id mtu
  id="$(select_gre_id)" || return 0
  ask_until_valid "input your new mtu for gre (576-1600):" valid_mtu mtu

  add_log "Setting MTU on interface gre${id} to ${mtu}..."
  render
  ip link set "gre${id}" mtu "$mtu" >/dev/null 2>&1 || add_log "WARNING: gre${id} interface not found or not up (will still patch unit)."

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

  add_log "Done: GRE${id} MTU changed to ${mtu}"
  render
  pause_enter
}

# ----------------------------- Menus (Separated) -----------------------------
local_setup_menu() {
  local choice=""
  while true; do
    render
    echo "LOCAL SETUP (GRE only)"
    echo "1 > setup iran local"
    echo "2 > setup kharej local"
    echo "0 > Back"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) add_log "Selected: setup iran local"; iran_local_setup ;;
      2) add_log "Selected: setup kharej local"; kharej_local_setup ;;
      0) return 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

tunnel_menu() {
  local choice=""
  while true; do
    render
    echo "TUNNEL / FORWARDER"
    echo "1 > ADD TUNNEL PORT (forwarders)"
    echo "2 > Ping Test (10 seconds)"
    echo "0 > Back"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) add_log "Selected: add tunnel port"; add_tunnel_port ;;
      2) add_log "Selected: ping test 10s"; ping_test_10s ;;
      0) return 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

automation_menu() {
  local choice=""
  while true; do
    render
    echo "AUTOMATION"
    echo "1 > Rebuild Automation (restore from backup mode)"
    echo "2 > Regenerate Automation (change IP mode)"
    echo "0 > Back"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) add_log "Selected: Rebuild Automation"; recreate_automation_mode ;;
      2) add_log "Selected: Regenerate Automation"; recreate_automation ;;
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
    echo "1 > Local Setup (iran/kharej) [GRE only]"
    echo "2 > Tunnel / Forwarder       [ports later + ping]"
    echo "3 > Services ManageMent"
    echo "4 > Automation"
    echo "5 > Uninstall & Clean"
    echo "6 > Change MTU"
    echo "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Open: Local Setup"; local_setup_menu ;;
      2) add_log "Open: Tunnel / Forwarder"; tunnel_menu ;;
      3) add_log "Open: Services ManageMent"; services_management ;;
      4) add_log "Open: Automation"; automation_menu ;;
      5) add_log "Selected: Uninstall & Clean"; uninstall_clean ;;
      6) add_log "Selected: Change MTU"; change_mtu ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

# ----------------------------- Boot -----------------------------
ensure_root "$@"
add_log "TEEJAY GRE+FORWARDER installer loaded."
main_menu
