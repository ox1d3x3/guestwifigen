#!/bin/sh
# =============================================================================
# OpenWrt Guest Wi‑Fi Gen (v1.8.3) 
# =============================================================================
# Usage:
#   - Install:  ./GuestWifiGen_v1.8.3.sh [--ip <guest_ip>]
#   - Uninstall: ./GuestWifiGen_v1.8.3.sh uninstall


# --- Color helpers (portable) ---
ok()   { printf "\033[0;32m✅ %s\033[0m\n" "$1"; }
warn() { printf "\033[1;33m⚠️  %s\033[0m\n" "$1"; }
error(){ printf "\033[0;31m❌ %s\033[0m\n" "$1"; exit 1; }
step() { printf "\033[0;36m▶ %s\033[0m\n"  "$1"; }

# --- Static Configuration ---
GUEST_IP="192.168.10.1"
GUEST_NETMASK="255.255.255.0"
GUEST_CONFIG_NAME="guest" # Internal UCI section base name

ACTION=""

# --- Arg parsing (portable) ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ip)
      shift
      [ -n "${1:-}" ] || error "Missing value after --ip"
      GUEST_IP="$1"
      shift
      ;;
    uninstall|remove)
      ACTION="uninstall"
      shift
      ;;
    *)
      warn "Ignoring unknown argument: $1"
      shift
      ;;
  esac
done

# --- Safety checks ---
system_checks() {
  step "Running system pre-flight checks"
  [ -f /etc/openwrt_release ] || error "Not running OpenWrt."
  [ "$(id -u)" -eq 0 ] || error "Run as root."
  ok "OpenWrt detected and running as root."
  command -v uci >/dev/null 2>&1 || error "uci not available."
}

# --- Convert dotted IPv4 to int (portable) ---
ip_to_int() {
  local IFS=.
  set -- $1
  [ "$#" -eq 4 ] || error "Invalid IPv4: $1"
  for oct in "$@"; do
    case "$oct" in
      ''|*[!0-9]*) error "Invalid IPv4: $1" ;;
      *)
        [ "$oct" -ge 0 ] 2>/dev/null && [ "$oct" -le 255 ] 2>/dev/null \
          || error "Invalid octet in IPv4: $1"
        ;;
    esac
  done
  # shellcheck disable=SC2003
  echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

# --- IP overlap check vs LAN ---
check_ip_conflict() {
  step "Checking for IP address conflicts..."
  local lan_ip lan_mask lan_ip_i lan_mask_i guest_ip_i
  lan_ip="$(uci -q get network.lan.ipaddr)"
  lan_mask="$(uci -q get network.lan.netmask)"
  if [ -n "$lan_ip" ] && [ -n "$lan_mask" ]; then
    lan_ip_i=$(ip_to_int "$lan_ip")
    lan_mask_i=$(ip_to_int "$lan_mask")
    guest_ip_i=$(ip_to_int "$GUEST_IP")
    if [ $((lan_ip_i & lan_mask_i)) -eq $((guest_ip_i & lan_mask_i)) ]; then
      error "IP Conflict: LAN (${lan_ip}/${lan_mask}) overlaps with guest (${GUEST_IP}/${GUEST_NETMASK})."
    fi
  fi
  ok "No IP conflicts detected."
}

# --- Radio detection (robust across versions) ---
RADIO_2G=""
RADIO_5G=""
detect_radios() {
  step "Detecting wireless radios..."
  local radios r band hwmode htmode
  radios="$(uci -q show wireless | sed -n 's/^wireless\.\(radio[^=]*\)=wifi-device.*/\1/p')"
  [ -n "$radios" ] || error "No wifi-device sections found in /etc/config/wireless."

  for r in $radios; do
    band="$(uci -q get wireless."$r".band)"
    hwmode="$(uci -q get wireless."$r".hwmode)"
    htmode="$(uci -q get wireless."$r".htmode)"
    # Prefer explicit band if present
    case "$band" in
      2g|2G) [ -z "$RADIO_2G" ] && RADIO_2G="$r" ;;
      5g|5G|6g|6G) [ -z "$RADIO_5G" ] && RADIO_5G="$r" ;;
    esac
    # Fallback heuristics
    if [ -z "$band" ]; then
      if   echo "$hwmode" | grep -qiE '11b|11g'; then [ -z "$RADIO_2G" ] && RADIO_2G="$r"
      elif echo "$hwmode" | grep -qiE '11a|11ac|11ax|11n'; then [ -z "$RADIO_5G" ] && RADIO_5G="$r"
      elif echo "$htmode" | grep -qiE 'VHT|HE|EHT|160|80'; then [ -z "$RADIO_5G" ] && RADIO_5G="$r"
      fi
    fi
  done

  # Final fallbacks
  if [ -z "$RADIO_2G" ]; then
    # If only one radio exists, use it for 2.4 (some single-radio devices)
    set -- $radios
    [ -n "$1" ] && RADIO_2G="$1"
  fi

  [ -n "$RADIO_2G" ] || error "Could not find a suitable 2.4GHz-capable radio."
  ok "2.4GHz radio: $RADIO_2G"
  if [ -n "$RADIO_5G" ]; then
    ok "High-band radio (5/6GHz): $RADIO_5G"
  else
    warn "No 5/6GHz radio found. Will only set up a 2.4GHz network."
  fi
}

# --- Validate user input ---
user_input_checks() {
  step "Validating user input"
  [ -n "$GUEST_SSID" ] || error "SSID cannot be empty."
  if [ -z "$GUEST_PASSWORD" ]; then
    error "Password cannot be empty."
  fi
  [ "${#GUEST_PASSWORD}" -ge 8 ] || error "Password must be at least 8 characters."
  # Ensure SSID doesn't already exist (case-insensitive, exact match on value in UCI output)
  if uci show wireless | grep -iE "ssid='(${GUEST_SSID}|${GUEST_SSID}-5G)'" >/dev/null 2>&1; then
    error "SSID '${GUEST_SSID}' (or 5G variant) already exists. Choose another."
  fi
  ok "SSID & password look good."
}

# --- Cleanup / Uninstall ---
remove_guest_network() {
  step "Removing any existing guest network configurations..."
  uci -q delete network.${GUEST_CONFIG_NAME}
  uci -q delete dhcp.${GUEST_CONFIG_NAME}
  uci -q delete firewall.${GUEST_CONFIG_NAME}
  uci -q delete firewall.${GUEST_CONFIG_NAME}_wan
  uci -q delete firewall.${GUEST_CONFIG_NAME}_dhcp
  uci -q delete firewall.${GUEST_CONFIG_NAME}_dns
  uci -q delete firewall.${GUEST_CONFIG_NAME}_block_lan
  uci -q delete wireless.${GUEST_CONFIG_NAME}_2g
  uci -q delete wireless.${GUEST_CONFIG_NAME}_5g
  uci commit
  ok "Old guest configuration removed (if present)."
}

# --- Reload Services ---
reload_services() {
  step "Reloading services..."
  /etc/init.d/network reload || warn "Could not reload network."
  /etc/init.d/dnsmasq restart || warn "Could not restart dnsmasq."
  /etc/init.d/firewall restart || warn "Could not restart firewall."
  wifi reload || wifi up || warn "Could not reload wifi."
}

# --- Setup network ---
setup_network() {
  step "Creating guest network interface..."
  uci set network.${GUEST_CONFIG_NAME}="interface"
  uci set network.${GUEST_CONFIG_NAME}.proto="static"
  uci set network.${GUEST_CONFIG_NAME}.ipaddr="${GUEST_IP}"
  uci set network.${GUEST_CONFIG_NAME}.netmask="${GUEST_NETMASK}"
  uci set network.${GUEST_CONFIG_NAME}.ip6assign="60"
}

# --- Setup DHCP ---
setup_dhcp() {
  step "Setting up DHCP for guest network..."
  uci set dhcp.${GUEST_CONFIG_NAME}="dhcp"
  uci set dhcp.${GUEST_CONFIG_NAME}.interface="${GUEST_CONFIG_NAME}"
  uci set dhcp.${GUEST_CONFIG_NAME}.start="100"
  uci set dhcp.${GUEST_CONFIG_NAME}.limit="150"
  uci set dhcp.${GUEST_CONFIG_NAME}.leasetime="12h"

  # Prompt (portable — no read -p)
  printf "Use custom public DNS for guests (1.1.1.1, 8.8.8.8)? [Y/n]: "
  read use_custom_dns
  [ -z "$use_custom_dns" ] && use_custom_dns="Y"
  case "$use_custom_dns" in
    Y|y)
      uci set dhcp.${GUEST_CONFIG_NAME}.dhcp_option="6,1.1.1.1,8.8.8.8"
      ok "Custom public DNS will be used."
      ;;
    *)
      ok "Guests will use the router's default DNS."
      ;;
  esac
}

# --- Setup firewall ---
setup_firewall() {
  step "Configuring firewall rules..."
  uci set firewall.${GUEST_CONFIG_NAME}="zone"
  uci set firewall.${GUEST_CONFIG_NAME}.name="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}.input="REJECT"
  uci set firewall.${GUEST_CONFIG_NAME}.output="ACCEPT"
  uci set firewall.${GUEST_CONFIG_NAME}.forward="REJECT"
  uci add_list firewall.${GUEST_CONFIG_NAME}.network="${GUEST_CONFIG_NAME}"

  uci set firewall.${GUEST_CONFIG_NAME}_wan="forwarding"
  uci set firewall.${GUEST_CONFIG_NAME}_wan.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_wan.dest="wan"

  uci set firewall.${GUEST_CONFIG_NAME}_dhcp="rule"
  uci set firewall.${GUEST_CONFIG_NAME}_dhcp.name="Allow Guest DHCP"
  uci set firewall.${GUEST_CONFIG_NAME}_dhcp.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_dhcp.proto="udp"
  uci set firewall.${GUEST_CONFIG_NAME}_dhcp.dest_port="67-68"
  uci set firewall.${GUEST_CONFIG_NAME}_dhcp.target="ACCEPT"

  uci set firewall.${GUEST_CONFIG_NAME}_dns="rule"
  uci set firewall.${GUEST_CONFIG_NAME}_dns.name="Allow Guest DNS"
  uci set firewall.${GUEST_CONFIG_NAME}_dns.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_dns.proto="tcp udp"
  uci set firewall.${GUEST_CONFIG_NAME}_dns.dest_port="53"
  uci set firewall.${GUEST_CONFIG_NAME}_dns.target="ACCEPT"

  uci set firewall.${GUEST_CONFIG_NAME}_block_lan="rule"
  uci set firewall.${GUEST_CONFIG_NAME}_block_lan.name="Block Guest to LAN"
  uci set firewall.${GUEST_CONFIG_NAME}_block_lan.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_block_lan.dest="lan"
  uci set firewall.${GUEST_CONFIG_NAME}_block_lan.target="DROP"
}

# --- Setup Wi‑Fi ---
setup_wifi() {
  step "Setting up 2.4GHz Guest SSID..."
  # Ensure radios are enabled
  uci set wireless.${RADIO_2G}.disabled='0'
  if [ -n "$RADIO_5G" ]; then
    uci set wireless.${RADIO_5G}.disabled='0'
  fi

  uci set wireless.${GUEST_CONFIG_NAME}_2g="wifi-iface"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.device="${RADIO_2G}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.mode="ap"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.network="${GUEST_CONFIG_NAME}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.ssid="${GUEST_SSID}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.encryption="psk2+ccmp"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.key="${GUEST_PASSWORD}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.isolate="1"

  if [ -n "$RADIO_5G" ]; then
    printf "Also create a 5/6GHz guest SSID? [Y/n]: "
    read create_5g
    [ -z "$create_5g" ] && create_5g="Y"
    case "$create_5g" in
      Y|y)
        step "Creating high-band (5/6GHz) Guest SSID..."
        uci set wireless.${GUEST_CONFIG_NAME}_5g="wifi-iface"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.device="${RADIO_5G}"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.mode="ap"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.network="${GUEST_CONFIG_NAME}"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.ssid="${GUEST_SSID}-5G"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.encryption="psk2+ccmp"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.key="${GUEST_PASSWORD}"
        uci set wireless.${GUEST_CONFIG_NAME}_5g.isolate="1"
        ;;
    esac
  fi
}

# --- Apply changes ---
apply_changes() {
  step "Applying changes..."
  uci commit || error "Failed to commit UCI changes."
  reload_services
  ok "Configuration applied successfully."
}

# --- Show QR (optional) ---
show_qr() {
  if command -v qrencode >/dev/null 2>&1; then
    printf "\n"
    ok "Scan this QR Code to connect (2.4GHz):"
    qrencode -t ANSIUTF8 "WIFI:T:WPA;S:${GUEST_SSID};P:${GUEST_PASSWORD};;"
  else
    warn "qrencode not installed. Install with: opkg update && opkg install qrencode"
  fi
}

# --- Banner ---
show_banner() {
  printf "%s\n" "   # #############################################################################    "
  printf "%s\n" "   #                                  ___    __                                       "
  printf "%s\n" "   #                       ____  _  _<  /___/ /__                                     "
  printf "%s\n" "   #                      / __ \| |/_/ / __  / _ \                                    "
  printf "%s\n" "   #                     / /_/ />  </ / /_/ /  __/                                    "
  printf "%s\n" "   #                     \____/_/|_/_/\__,_/\___/                                     "
  printf "%s\n" "   #                                                                                  "
  printf "%s\n" "   #                OpenWrt Guest Wi‑Fi Generator (v1.8.3)                            "
  printf "%s\n" "   #                                                                                  "
  printf "%s\n" "   # #############################################################################    "
  printf "\n"
}

# --- Main ---
main() {
  show_banner

  if [ "$ACTION" = "uninstall" ]; then
    remove_guest_network
    reload_services
    ok "Guest network successfully removed."
    exit 0
  fi

  system_checks
  check_ip_conflict
  detect_radios

  printf "\n"
  step "Please provide details for the new guest network."
  printf "Enter the Guest Wi‑Fi Name (SSID): "
  read GUEST_SSID

  # Portable silent password entry (use stty if available)
  if command -v stty >/dev/null 2>&1; then
    printf "Enter the Guest Wi‑Fi Password (min 8 chars): "
    stty -echo
    read GUEST_PASSWORD
    stty echo
    printf "\n"
  else
    warn "stty not available; password will be echoed."
    printf "Enter the Guest Wi‑Fi Password (min 8 chars): "
    read GUEST_PASSWORD
  fi
  printf "\n"

  user_input_checks
  remove_guest_network # Clean up any old configs first
  setup_network
  setup_dhcp
  setup_firewall
  setup_wifi
  apply_changes

  printf "\n"
  ok "Guest Wi‑Fi Setup Complete!"
  printf "SSID: %s\n" "$GUEST_SSID"
  if [ -n "$RADIO_5G" ]; then
    printf "SSID (5/6GHz): %s-5G\n" "$GUEST_SSID"
  fi
  printf "Password: (hidden)\n"
  printf "Clients on this network are isolated from your main LAN and from each other.\n"
  show_qr
}

main "$@"
