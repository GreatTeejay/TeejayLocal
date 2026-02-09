#!/usr/bin/env bash
set -euo pipefail

APP="teejay-local"
BASE_DIR="/etc/teejay-local"
WG_IF="wg0"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
WATCH_SCRIPT="/usr/local/bin/teejay-watchdog.sh"
SYSTEMD_SERVICE="/etc/systemd/system/teejay-watchdog.service"
SYSTEMD_TIMER="/etc/systemd/system/teejay-watchdog.timer"
CRON_FILE="/etc/cron.d/teejay-watchdog"

# ---------------- UI ----------------
logo() {
  clear || true
  cat <<'EOF'
████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗
╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝
   ██║   █████╗  █████╗       ██║███████║ ╚████╔╝ 
   ██║   ██╔══╝  ██╔══╝  ██   ██║██╔══██║  ╚██╔╝  
   ██║   ███████╗███████╗╚█████╔╝██║  ██║   ██║   
   ╚═╝   ╚══════╝╚══════╝ ╚════╝ ╚═╝  ╚═╝   ╚═╝   

                Teejay Local Tunnel Manager
EOF
  echo
}

pause() { read -r -p "Enter بزن برای ادامه..." _; }

die() { echo "❌ $*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "این اسکریپت باید با root اجرا بشه."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_src_ip() {
  # Best-effort "server IP" (source IP used to reach internet)
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
}

read_yesno() {
  local prompt="$1"
  local ans
  while true; do
    read -r -p "$prompt [Y/N]: " ans
    case "${ans,,}" in
      y|yes) echo "Y"; return ;;
      n|no)  echo "N"; return ;;
      *) echo "فقط Y یا N" ;;
    esac
  done
}

ensure_dirs() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"
}

install_wireguard() {
  if have_cmd wg && have_cmd wg-quick; then
    return
  fi
  echo "🔧 نصب WireGuard ..."
  if have_cmd apt-get; then
    apt-get update -y
    apt-get install -y wireguard wireguard-tools iproute2 iputils-ping
  elif have_cmd yum; then
    yum install -y epel-release || true
    yum install -y wireguard-tools iproute iputils
  elif have_cmd dnf; then
    dnf install -y wireguard-tools iproute iputils
  else
    die "پکیج منیجر شناخته نشد. دستی wireguard-tools نصب کن."
  fi
}

gen_keys_if_missing() {
  local priv="$BASE_DIR/privatekey"
  local pub="$BASE_DIR/publickey"
  if [[ ! -f "$priv" || ! -f "$pub" ]]; then
    umask 077
    wg genkey | tee "$priv" | wg pubkey > "$pub"
  fi
  chmod 600 "$priv" "$pub"
}

show_pubkey() {
  echo "🔑 PublicKey این سرور:"
  cat "$BASE_DIR/publickey"
  echo
}

write_sysctl_forwarding() {
  # Not strictly required for ping between tunnel IPs, but safe for routing later
  cat >/etc/sysctl.d/99-teejay-local.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl -q --system || true
}

stop_existing_wg() {
  if systemctl is-active --quiet "wg-quick@${WG_IF}.service" 2>/dev/null; then
    systemctl stop "wg-quick@${WG_IF}.service" || true
  fi
  if [[ -f "$WG_CONF" ]]; then
    wg-quick down "$WG_IF" >/dev/null 2>&1 || true
  fi
}

apply_wg_conf() {
  chmod 600 "$WG_CONF"
  systemctl enable "wg-quick@${WG_IF}.service" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IF}.service"
}

ping_check() {
  local target="$1"
  ping -c 2 -W 2 "$target" >/dev/null 2>&1
}

save_state() {
  cat >"$BASE_DIR/state.env" <<EOF
ROLE="$1"
LOCAL_IP="$2"
PEER_LOCAL_IP="$3"
PEER_PUBLIC_IP="$4"
WG_PORT="$5"
MTU="$6"
EOF
  chmod 600 "$BASE_DIR/state.env"
}

load_state() {
  [[ -f "$BASE_DIR/state.env" ]] || die "هیچ تنظیماتی پیدا نشد. اول Setup رو انجام بده."
  # shellcheck disable=SC1090
  source "$BASE_DIR/state.env"
}

setup_common_questions() {
  local detected ipconfirm pubip
  detected="$(detect_src_ip)"
  if [[ -n "${detected:-}" ]]; then
    echo "IP این سرور: $detected"
    ipconfirm="$(read_yesno "is this your server ip ?")"
    if [[ "$ipconfirm" == "Y" ]]; then
      pubip="$detected"
    else
      read -r -p "IP صحیح سرور را دستی وارد کن: " pubip
    fi
  else
    read -r -p "IP سرور را وارد کن: " pubip
  fi

  echo "$pubip"
}

create_iran_conf() {
  local my_pubip peer_pubip peer_pubkey mtu port
  my_pubip="$(setup_common_questions)"

  read -r -p "Kharej IP (Public): " peer_pubip
  read -r -p "MTU (مثلا 1420 / 1380): " mtu
  read -r -p "WireGuard Port (پیشنهادی 51820): " port
  port="${port:-51820}"

  echo
  echo "الان باید PublicKey سرور خارج رو وارد کنی."
  read -r -p "Kharej PublicKey: " peer_pubkey

  gen_keys_if_missing

  stop_existing_wg

  cat >"$WG_CONF" <<EOF
[Interface]
Address = 10.10.10.1/30
ListenPort = ${port}
PrivateKey = $(cat "$BASE_DIR/privatekey")
MTU = ${mtu}

# Optional: keepalive helps NAT paths
PostUp = iptables -I INPUT -p udp --dport ${port} -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${port} -j ACCEPT

[Peer]
PublicKey = ${peer_pubkey}
AllowedIPs = 10.10.10.2/32
Endpoint = ${peer_pubip}:${port}
PersistentKeepalive = 25
EOF

  write_sysctl_forwarding
  apply_wg_conf

  save_state "IRAN" "10.10.10.1" "10.10.10.2" "$peer_pubip" "$port" "$mtu"

  echo
  echo "✅ Iran local setup done."
  echo "📌 حالا PublicKey این سرور رو بردار بده به سرور خارج:"
  show_pubkey
  echo "🔎 تست پینگ به 10.10.10.2 ..."
  if ping_check "10.10.10.2"; then
    echo "✅ Ping OK"
  else
    echo "⚠️ Ping هنوز OK نیست. اول سمت خارج رو هم ست کن."
  fi
}

create_kharej_conf() {
  local my_pubip peer_pubip peer_pubkey mtu port
  my_pubip="$(setup_common_questions)"

  read -r -p "Iran IP (Public): " peer_pubip
  read -r -p "MTU (مثلا 1420 / 1380): " mtu
  read -r -p "WireGuard Port (پیشنهادی 51820): " port
  port="${port:-51820}"

  echo
  echo "الان باید PublicKey سرور ایران رو وارد کنی."
  read -r -p "Iran PublicKey: " peer_pubkey

  gen_keys_if_missing

  stop_existing_wg

  cat >"$WG_CONF" <<EOF
[Interface]
Address = 10.10.10.2/30
ListenPort = ${port}
PrivateKey = $(cat "$BASE_DIR/privatekey")
MTU = ${mtu}

PostUp = iptables -I INPUT -p udp --dport ${port} -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${port} -j ACCEPT

[Peer]
PublicKey = ${peer_pubkey}
AllowedIPs = 10.10.10.1/32
Endpoint = ${peer_pubip}:${port}
PersistentKeepalive = 25
EOF

  write_sysctl_forwarding
  apply_wg_conf

  save_state "KHAREJ" "10.10.10.2" "10.10.10.1" "$peer_pubip" "$port" "$mtu"

  echo
  echo "✅ Kharej local setup done."
  echo "📌 PublicKey این سرور رو بردار بده به سرور ایران:"
  show_pubkey
  echo "🔎 تست پینگ به 10.10.10.1 ..."
  if ping_check "10.10.10.1"; then
    echo "✅ Ping OK"
  else
    echo "⚠️ Ping هنوز OK نیست. سمت ایران هم چک کن."
  fi
}

install_watchdog_script() {
  cat >"$WATCH_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/teejay-local"
WG_IF="wg0"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
LOG="/var/log/teejay-watchdog.log"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >/dev/null
}

ping_ok() {
  local ip="$1"
  ping -c 2 -W 2 "$ip" >/dev/null 2>&1
}

restart_tunnel() {
  log "Restarting WireGuard..."
  systemctl restart "wg-quick@${WG_IF}.service" >/dev/null 2>&1 || true
  sleep 2
}

main() {
  [[ -f "$BASE_DIR/state.env" ]] || exit 0
  # shellcheck disable=SC1090
  source "$BASE_DIR/state.env"

  # basic sanity
  [[ -f "$WG_CONF" ]] || { log "No wg conf found."; exit 0; }

  if ping_ok "$PEER_LOCAL_IP"; then
    exit 0
  fi

  log "Ping to $PEER_LOCAL_IP failed. Trying recovery..."

  # Try multiple times until ping returns (bounded)
  for i in {1..6}; do
    restart_tunnel
    if ping_ok "$PEER_LOCAL_IP"; then
      log "Recovered. Ping OK."
      exit 0
    fi
    log "Attempt $i failed. Retrying..."
    sleep 3
  done

  log "Recovery failed after retries."
  exit 0
}

main "$@"
EOF
  chmod +x "$WATCH_SCRIPT"
}

enable_systemd_timer() {
  install_watchdog_script

  cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Teejay WireGuard Watchdog

[Service]
Type=oneshot
ExecStart=${WATCH_SCRIPT}
EOF

  cat >"$SYSTEMD_TIMER" <<EOF
[Unit]
Description=Run Teejay Watchdog every 30 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now teejay-watchdog.timer
  systemctl disable --now teejay-watchdog.service >/dev/null 2>&1 || true

  # Ensure no cron duplicate
  rm -f "$CRON_FILE" >/dev/null 2>&1 || true

  echo "✅ Automation فعال شد (systemd timer هر 30 ثانیه)."
}

enable_cron_job() {
  install_watchdog_script
  cat >"$CRON_FILE" <<EOF
* * * * * root ${WATCH_SCRIPT} >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"

  # Disable systemd timer if exists
  systemctl disable --now teejay-watchdog.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  echo "✅ Automation فعال شد (cron هر 1 دقیقه)."
}

automation_menu() {
  echo "1) systemd timer (هر 30 ثانیه) - پیشنهاد"
  echo "2) cron (هر 1 دقیقه)"
  echo "3) disable automation"
  read -r -p "انتخاب: " a
  case "$a" in
    1) enable_systemd_timer ;;
    2) enable_cron_job ;;
    3)
      systemctl disable --now teejay-watchdog.timer >/dev/null 2>&1 || true
      rm -f "$CRON_FILE" "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      echo "✅ Automation غیرفعال شد."
      ;;
    *) echo "نامعتبر" ;;
  esac
}

status_menu() {
  if [[ -f "$BASE_DIR/state.env" ]]; then
    # shellcheck disable=SC1090
    source "$BASE_DIR/state.env"
    echo "Role: ${ROLE:-?}"
    echo "Local IP: ${LOCAL_IP:-?}"
    echo "Peer Local IP: ${PEER_LOCAL_IP:-?}"
    echo "Peer Public IP: ${PEER_PUBLIC_IP:-?}"
    echo "Port: ${WG_PORT:-?}"
    echo "MTU: ${MTU:-?}"
    echo
  else
    echo "⚠️ هنوز state ذخیره نشده."
  fi

  echo "=== wg show ==="
  if have_cmd wg; then
    wg show "$WG_IF" || true
  else
    echo "wg نصب نیست."
  fi
  echo

  if [[ -f "$BASE_DIR/state.env" ]]; then
    echo "=== ping peer local ==="
    if ping -c 3 -W 2 "$PEER_LOCAL_IP"; then
      echo "✅ Ping OK"
    else
      echo "❌ Ping FAIL"
    fi
  fi
}

uninstall_all() {
  echo "🧹 Uninstall..."
  systemctl disable --now "wg-quick@${WG_IF}.service" >/dev/null 2>&1 || true
  wg-quick down "$WG_IF" >/dev/null 2>&1 || true

  systemctl disable --now teejay-watchdog.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" "$CRON_FILE" "$WATCH_SCRIPT" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -f "$WG_CONF" >/dev/null 2>&1 || true
  rm -rf "$BASE_DIR" >/dev/null 2>&1 || true

  echo "✅ حذف شد. (اگر خواستی خود WireGuard رو هم پاک کنی: apt remove wireguard-tools)"
}

main_menu() {
  need_root
  ensure_dirs
  install_wireguard
  gen_keys_if_missing

  while true; do
    logo
    echo "1 - setup Iran Local"
    echo "2 - setup Kharej Local"
    echo "3 - automation"
    echo "4 - status (ping / wg)"
    echo "5 - uninstall"
    echo "6 - exit"
    echo
    read -r -p "انتخاب کن: " choice
    case "$choice" in
      1) create_iran_conf; pause ;;
      2) create_kharej_conf; pause ;;
      3) automation_menu; pause ;;
      4) status_menu; pause ;;
      5) uninstall_all; pause ;;
      6) exit 0 ;;
      *) echo "گزینه نامعتبر"; pause ;;
    esac
  done
}

main_menu
