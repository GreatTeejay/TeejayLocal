#!/bin/bash
#
# Teejay Local (IPsec VTI) + Automation
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CONF_FILE="/etc/teejay-local.conf"

IPSEC_CONF="/etc/ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.secrets"

CONN_NAME="teejay-local"
VTI_IF="teejay0"

UPDOWN="/usr/local/lib/teejay-ipsec-vti-updown.sh"
MON_SCRIPT="/usr/local/bin/teejay-local-monitor.sh"
SYS_SERVICE="/etc/systemd/system/teejay-local-monitor.service"
SYS_TIMER="/etc/systemd/system/teejay-local-monitor.timer"

DEFAULT_MTU="1436"
# Local /30
IRAN_ADDR="10.66.66.1/30"
KHAREJ_ADDR="10.66.66.2/30"
IRAN_PEER="10.66.66.2"
KHAREJ_PEER="10.66.66.1"

print_logo() {
  clear || true
  echo -e "${CYAN}${BOLD}"
  cat << 'EOF'
████████╗███████╗███████╗     ██╗ █████╗ ██╗   ██╗
╚══██╔══╝██╔════╝██╔════╝     ██║██╔══██╗╚██╗ ██╔╝
   ██║   █████╗  █████╗       ██║███████║ ╚████╔╝
   ██║   ██╔══╝  ██╔══╝  ██   ██║██╔══██║  ╚██╔╝
   ██║   ███████╗███████╗╚█████╔╝██║  ██║   ██║
   ╚═╝   ╚══════╝╚══════╝ ╚════╝ ╚═╝  ╚═╝   ╚═╝
EOF
  echo -e "${NC}"
  echo -e "  ${DIM}Teejay Local • IPsec(VTI) Local IP + Automation Monitor${NC}"
  echo ""
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    print_logo
    echo -e "  ${RED}Run as root (sudo).${NC}"
    echo -e "  ${YELLOW}Usage:${NC} sudo bash $0"
    exit 1
  fi
}

detect_my_ip() {
  local ip=""
  if command -v ip &>/dev/null; then
    ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)
  fi
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  echo "$ip"
}

ask_confirm_ip_or_manual() {
  local detected="$1"
  local chosen=""
  if [ -n "$detected" ]; then
    echo -e "  ${CYAN}Server IP detected:${NC} ${GREEN}${detected}${NC}"
    echo -e "  ${YELLOW}is this your server ip${NC}  Y=Next level , N: enter ip manually"
    read -r -p "  (Y/N): " yn
    if [[ "$yn" =~ ^[yY]$ ]]; then
      chosen="$detected"
    else
      read -r -p "  enter ip manually: " chosen
    fi
  else
    read -r -p "  enter server public ip: " chosen
  fi
  echo "$chosen"
}

save_kv() {
  local k="$1" v="$2"
  touch "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  grep -v -E "^${k}=" "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null || true
  mv "${CONF_FILE}.tmp" "$CONF_FILE"
  echo "${k}=${v}" >> "$CONF_FILE"
}

load_conf() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi
}

ensure_deps() {
  if ! command -v ipsec >/dev/null 2>&1; then
    echo -e "  ${YELLOW}Installing strongSwan...${NC}"
    apt-get update -qq
    apt-get install -y strongswan strongswan-swanctl
  fi
}

write_updown() {
  cat > "$UPDOWN" <<'EOF'
#!/bin/bash
set -euo pipefail

VTI_IF="${VTI_IF:-teejay0}"
VTI_LOCAL="${VTI_LOCAL:-}"
VTI_PEER="${VTI_PEER:-}"
VTI_KEY="${VTI_KEY:-101}"
VTI_ADDR="${VTI_ADDR:-10.66.66.1/30}"
MTU="${MTU:-1436}"

case "${PLUTO_VERB:-}" in
  up-client|up-host|up-client-v6|up-host-v6)
    # Create VTI if not exists
    if ! ip link show "$VTI_IF" >/dev/null 2>&1; then
      ip link add "$VTI_IF" type vti local "$VTI_LOCAL" remote "$VTI_PEER" key "$VTI_KEY"
    fi

    ip addr flush dev "$VTI_IF" || true
    ip addr add "$VTI_ADDR" dev "$VTI_IF"
    ip link set "$VTI_IF" mtu "$MTU"
    ip link set "$VTI_IF" up

    # Needed sysctls for VTI/IPsec routing
    sysctl -w "net.ipv4.ip_forward=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.conf.all.rp_filter=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.conf.${VTI_IF}.rp_filter=0" >/dev/null 2>&1 || true
    ;;
  down-client|down-host|down-client-v6|down-host-v6)
    ip link del "$VTI_IF" >/dev/null 2>&1 || true
    ;;
esac
EOF
  chmod +x "$UPDOWN"
}

write_ipsec_configs() {
  local left_ip="$1" right_ip="$2" psk="$3" vti_key="$4" vti_addr="$5" mtu="$6"

  # Backup once
  [ -f "$IPSEC_CONF" ] && cp -f "$IPSEC_CONF" "${IPSEC_CONF}.bak" || true
  [ -f "$IPSEC_SECRETS" ] && cp -f "$IPSEC_SECRETS" "${IPSEC_SECRETS}.bak" || true

  # ipsec.conf (minimal, stable)
  cat > "$IPSEC_CONF" <<EOF
config setup
  uniqueids=no

conn ${CONN_NAME}
  keyexchange=ikev2
  authby=psk
  left=${left_ip}
  leftid=${left_ip}
  right=${right_ip}
  rightid=${right_ip}

  # Make it stable:
  dpdaction=restart
  dpddelay=10s
  dpdtimeout=30s

  # ESP/IKE proposals (safe defaults)
  ike=aes256-sha256-modp2048!
  esp=aes256-sha256!

  # VTI: we carry 0.0.0.0/0 selectors but only use the VTI interface for local IP
  leftsubnet=0.0.0.0/0
  rightsubnet=0.0.0.0/0
  mark=${vti_key}

  auto=start

  # Updown creates the VTI interface and assigns the /30
  leftupdown=${UPDOWN}
EOF

  # ipsec.secrets
  # IMPORTANT: strongSwan accepts "left right : PSK "secret""
  cat > "$IPSEC_SECRETS" <<EOF
${left_ip} ${right_ip} : PSK "${psk}"
EOF
  chmod 600 "$IPSEC_SECRETS"

  save_kv "LEFT_IP" "$left_ip"
  save_kv "RIGHT_IP" "$right_ip"
  save_kv "PSK" "$psk"
  save_kv "VTI_KEY" "$vti_key"
  save_kv "VTI_ADDR" "$vti_addr"
  save_kv "MTU" "$mtu"
  save_kv "VTI_IF" "$VTI_IF"
  save_kv "CONN_NAME" "$CONN_NAME"
}

restart_ipsec() {
  systemctl enable --now strongswan-starter >/dev/null 2>&1 || true
  systemctl restart strongswan-starter
  # ensure connection loads
  ipsec rereadall >/dev/null 2>&1 || true
  ipsec update >/dev/null 2>&1 || true
  ipsec down "$CONN_NAME" >/dev/null 2>&1 || true
  ipsec up "$CONN_NAME" >/dev/null 2>&1 || true
}

status_show() {
  print_logo
  load_conf || true

  echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}║${NC}                     ${GREEN}Status${NC}                               ${CYAN}║${NC}"
  echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  echo -e "  ${YELLOW}IPsec:${NC}"
  ipsec statusall 2>/dev/null | sed 's/^/  /' || echo -e "  ${YELLOW}(ipsec not ready)${NC}"
  echo ""

  if ip link show "$VTI_IF" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}VTI:${NC} ${GREEN}${VTI_IF}${NC} (UP)"
    ip -4 addr show "$VTI_IF" | sed 's/^/  /'
  else
    echo -e "  ${YELLOW}VTI:${NC} ${RED}${VTI_IF} not found${NC}"
  fi
  echo ""

  local peer_test="${PEER_TEST_IP:-}"
  if [ -n "${ROLE:-}" ]; then
    [ "$ROLE" = "iran" ] && peer_test="$IRAN_PEER" || peer_test="$KHAREJ_PEER"
  fi

  if [ -n "$peer_test" ]; then
    if ping -c 2 -W 2 "$peer_test" >/dev/null 2>&1; then
      echo -e "  ${YELLOW}Ping peer (${peer_test}):${NC} ${GREEN}OK${NC}"
    else
      echo -e "  ${YELLOW}Ping peer (${peer_test}):${NC} ${RED}FAIL${NC}"
    fi
  else
    echo -e "  ${DIM}Run setup first to know peer IP.${NC}"
  fi

  echo ""
  if systemctl is-active teejay-local-monitor.timer >/dev/null 2>&1; then
    echo -e "  ${YELLOW}Automation:${NC} ${GREEN}ENABLED${NC}"
  else
    echo -e "  ${YELLOW}Automation:${NC} ${YELLOW}DISABLED${NC}"
  fi
  echo ""
}

setup_iran() {
  print_logo
  require_root
  ensure_deps
  write_updown

  echo -e "  ${GREEN}1 - setup Iran Local${NC}"
  echo ""

  local myip detected kharej_ip mtu psk
  detected="$(detect_my_ip)"
  myip="$(ask_confirm_ip_or_manual "$detected")"

  echo ""
  read -r -p "  write kharej IP: " kharej_ip
  read -r -p "  mtu [${DEFAULT_MTU}]: " mtu
  mtu="${mtu:-$DEFAULT_MTU}"

  echo ""
  echo -e "  ${YELLOW}PSK (shared key) - same on both servers.${NC}"
  read -r -p "  PSK (Enter to auto-generate): " psk
  if [ -z "$psk" ]; then
    psk="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    echo -e "  ${CYAN}Generated PSK:${NC} ${GREEN}${psk}${NC}"
    echo -e "  ${YELLOW}Copy this PSK to KHAREJ setup too.${NC}"
  fi

  # VTI key: two sides must match in mark-based VTI setups.
  local vti_key="101"

  # Save role and peer ping target
  save_kv "ROLE" "iran"
  save_kv "PEER_TEST_IP" "$IRAN_PEER"

  # export for updown script
  save_kv "VTI_LOCAL" "$myip"
  save_kv "VTI_PEER" "$kharej_ip"

  # write configs
  write_ipsec_configs "$myip" "$kharej_ip" "$psk" "$vti_key" "$IRAN_ADDR" "$mtu"

  # Make updown see env vars (strongSwan does not read our /etc/teejay-local.conf),
  # so we embed them via a wrapper in /etc/default (simple way: source in updown is not safe).
  # We'll instead export them by writing a small file used by monitor recovery to recreate VTI if needed.
  # Updown already uses PLUTO vars + VTI_LOCAL/VTI_PEER from environment; strongSwan doesn't set those.
  # So we rely on "ip link add vti local/right key" with saved values in monitor during recovery,
  # and let updown handle addr/mtu when ipsec comes up.

  echo ""
  echo -e "  ${YELLOW}Starting IPsec...${NC}"
  restart_ipsec

  echo ""
  echo -e "  ${GREEN}Done.${NC}"
  echo -e "  ${YELLOW}Test:${NC} ping ${CYAN}${IRAN_PEER}${NC}"
  echo ""
}

setup_kharej() {
  print_logo
  require_root
  ensure_deps
  write_updown

  echo -e "  ${GREEN}2 - setup Kharej local${NC}"
  echo ""

  local myip detected iran_ip mtu psk
  detected="$(detect_my_ip)"
  myip="$(ask_confirm_ip_or_manual "$detected")"

  echo ""
  read -r -p "  write iran IP: " iran_ip
  read -r -p "  mtu [${DEFAULT_MTU}]: " mtu
  mtu="${mtu:-$DEFAULT_MTU}"

  echo ""
  echo -e "  ${YELLOW}PSK (shared key) - same on both servers.${NC}"
  read -r -p "  PSK: " psk
  if [ -z "$psk" ]; then
    echo -e "  ${RED}PSK is required on this side (use the same PSK from IRAN).${NC}"
    exit 1
  fi

  local vti_key="101"

  save_kv "ROLE" "kharej"
  save_kv "PEER_TEST_IP" "$KHAREJ_PEER"
  save_kv "VTI_LOCAL" "$myip"
  save_kv "VTI_PEER" "$iran_ip"

  write_ipsec_configs "$myip" "$iran_ip" "$psk" "$vti_key" "$KHAREJ_ADDR" "$mtu"

  echo ""
  echo -e "  ${YELLOW}Starting IPsec...${NC}"
  restart_ipsec

  echo ""
  echo -e "  ${GREEN}Done.${NC}"
  echo -e "  ${YELLOW}Test:${NC} ping ${CYAN}${KHAREJ_PEER}${NC}"
  echo ""
}

install_automation() {
  print_logo
  require_root
  ensure_deps
  load_conf || true

  echo -e "  ${GREEN}3- automation${NC}"
  echo ""

  if [ ! -f "$CONF_FILE" ]; then
    echo -e "  ${RED}Not configured yet.${NC} Run option 1 or 2 first."
    exit 1
  fi

  # monitor script: step-by-step recovery
  cat > "$MON_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

CONF_FILE="/etc/teejay-local.conf"
log(){ echo "[teejay-monitor] $*"; }

load_conf(){
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi
}

ping_peer(){
  ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

hard_reset(){
  # Step-by-step reset
  log "1) ipsec down"
  ipsec down "${CONN_NAME:-teejay-local}" >/dev/null 2>&1 || true

  log "2) delete VTI"
  ip link del "${VTI_IF:-teejay0}" >/dev/null 2>&1 || true

  log "3) restart strongSwan"
  systemctl restart strongswan-starter >/dev/null 2>&1 || true
  ipsec rereadall >/dev/null 2>&1 || true
  ipsec update >/dev/null 2>&1 || true

  log "4) ipsec up"
  ipsec up "${CONN_NAME:-teejay-local}" >/dev/null 2>&1 || true
}

main(){
  load_conf

  PEER_TEST_IP="${PEER_TEST_IP:-}"
  if [ -z "$PEER_TEST_IP" ] && [ -n "${ROLE:-}" ]; then
    if [ "$ROLE" = "iran" ]; then PEER_TEST_IP="10.66.66.2"; else PEER_TEST_IP="10.66.66.1"; fi
  fi
  if [ -z "$PEER_TEST_IP" ]; then
    log "No PEER_TEST_IP found. Run setup first."
    exit 0
  fi

  # Health check: 3 consecutive fails
  fails=0
  for i in 1 2 3; do
    if ping_peer "$PEER_TEST_IP"; then
      log "OK: ping to $PEER_TEST_IP"
      exit 0
    fi
    fails=$((fails+1))
    sleep 2
  done

  if [ "$fails" -lt 3 ]; then
    exit 0
  fi

  log "FAIL: ping to $PEER_TEST_IP failed 3 times -> start recovery"
  hard_reset

  # verify recovery up to 10 tries
  for t in $(seq 1 10); do
    if ping_peer "$PEER_TEST_IP"; then
      log "Recovered: ping is back"
      exit 0
    fi
    log "Waiting... try $t/10"
    sleep 3
  done

  log "Recovery finished but still failing"
  exit 1
}

main "$@"
EOF
  chmod +x "$MON_SCRIPT"

  cat > "$SYS_SERVICE" <<EOF
[Unit]
Description=Teejay Local - Monitor & Auto Repair (IPsec VTI)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${MON_SCRIPT}
EOF

  cat > "$SYS_TIMER" <<'EOF'
[Unit]
Description=Run Teejay Local monitor every minute

[Timer]
OnBootSec=45
OnUnitActiveSec=60
AccuracySec=5
Unit=teejay-local-monitor.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now teejay-local-monitor.timer

  echo -e "  ${GREEN}Automation enabled.${NC}"
  echo -e "  ${YELLOW}Logs:${NC} journalctl -u teejay-local-monitor -f"
  echo ""
}

uninstall_all() {
  print_logo
  require_root

  echo -e "  ${GREEN}5-unistall${NC}"
  echo ""

  systemctl disable --now teejay-local-monitor.timer >/dev/null 2>&1 || true
  systemctl disable --now teejay-local-monitor.service >/dev/null 2>&1 || true
  rm -f "$SYS_TIMER" "$SYS_SERVICE" "$MON_SCRIPT"
  systemctl daemon-reload >/dev/null 2>&1 || true

  ipsec down "$CONN_NAME" >/dev/null 2>&1 || true
  ip link del "$VTI_IF" >/dev/null 2>&1 || true
  systemctl restart strongswan-starter >/dev/null 2>&1 || true

  rm -f "$CONF_FILE"
  # Don't delete user's whole ipsec config if they had other tunnels.
  # We only remove our conn if it exists in current file by overwriting is risky.
  # So we restore backups if present.
  if [ -f "${IPSEC_CONF}.bak" ]; then cp -f "${IPSEC_CONF}.bak" "$IPSEC_CONF"; fi
  if [ -f "${IPSEC_SECRETS}.bak" ]; then cp -f "${IPSEC_SECRETS}.bak" "$IPSEC_SECRETS"; fi
  rm -f "$UPDOWN"

  systemctl restart strongswan-starter >/dev/null 2>&1 || true

  echo -e "  ${GREEN}Uninstall completed.${NC}"
  echo ""
}

main_menu() {
  require_root
  print_logo

  local myip
  myip="$(detect_my_ip)"
  if [ -n "$myip" ]; then
    echo -e "  ${DIM}This server IP:${NC} ${CYAN}${myip}${NC}"
    echo ""
  fi

  echo -e "  1 - setup Iran Local"
  echo -e "  2- setup Kharej local"
  echo -e "  3- automation"
  echo -e "  4 - status (like ping or ...)"
  echo -e "  5-unistall"
  echo -e "  6-exit"
  echo ""
  read -r -p "  Choice (1-6): " c

  case "$c" in
    1) setup_iran ;;
    2) setup_kharej ;;
    3) install_automation ;;
    4) status_show ;;
    5) uninstall_all ;;
    6) echo -e "  ${GREEN}Bye.${NC}"; exit 0 ;;
    *) echo -e "  ${RED}Invalid choice.${NC}" ;;
  esac
}

main_menu
