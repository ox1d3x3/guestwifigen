#!/bin/sh
# =============================================================================
# OpenWrt Guest Wi‑Fi Gen (v2.0.1)
# Targeted OpenWrt: 24.xx/ 23.05 / 22.03 / 21.02 / 19.07
# =============================================================================

# --- Color helpers (portable) ---
ok()    { printf "\033[0;32m[OK]\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
error() { printf "\033[0;31m[ERR]\033[0m %s\n" "$1"; exit 1; }
step()  { printf "\033[0;36m[STEP]\033[0m %s\n" "$1"; }
info()  { printf "\033[0;34m[INFO]\033[0m %s\n" "$1"; }
alert() { printf "\033[0;31m[!]\033[0m %s\n" "$1"; }  # red notice

# --- Static Configuration ---
GUEST_IP="192.168.10.1"
GUEST_NETMASK="255.255.255.0"
GUEST_CONFIG_NAME="guest" # Internal UCI section base name
ACTION=""
REPLACE_MODE=0
REPLACE_SECTION=""

# --- Arg parsing (portable) ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ip) shift; [ -n "${1:-}" ] || error "Missing value after --ip"; GUEST_IP="$1"; shift ;;
    uninstall|remove) ACTION="uninstall"; shift ;;
    *) warn "Ignoring unknown argument: $1"; shift ;;
  esac
done

# --- Banner (preserved) ---
show_banner() {
  printf "%s\n" "   # #############################################################################"
  printf "%s\n" "   #                                  ___    __                                   "
  printf "%s\n" "   #                       ____  _  _<  /___/ /__                                 "
  printf "%s\n" "   #                      / __ \\| |/_/ / __  / _ \\                                "
  printf "%s\n" "   #                     / /_/ />  </ / /_/ /  __/                                "
  printf "%s\n" "   #                     \\____/_/|_/_/\\__,_/\\___/                                "
  printf "%s\n" "   #                                                                               "
  printf "%s\n" "   #                OpenWrt Guest Wi-Fi Generator (v2.0) Github@Ox1d3x3           "
  printf "%s\n" "   #                                                                               "
  printf "%s\n" "   # #############################################################################"
  printf "\n"
}

# --- Utility: timestamp ---
timestamp() { date +"%Y%m%d-%H%M%S" 2>/dev/null || date; }

# --- ask yes/no with default Y ---
ask_yn() {
  # $1 prompt
  local ans
  printf "%s [Y/n]: " "$1"
  read ans
  [ -z "$ans" ] && ans="Y"
  case "$ans" in Y|y) return 0 ;; *) return 1 ;; esac
}

# --- Safety checks ---
system_checks() {
  step "Running system pre-flight checks"
  [ -f /etc/openwrt_release ] || error "Not running OpenWrt."
  [ "$(id -u)" -eq 0 ] || error "Run as root."
  command -v uci >/dev/null 2>&1 || error "uci not available."
  [ -x /etc/init.d/dnsmasq ] || warn "dnsmasq init not found (custom DHCP daemon?)"
  [ -x /etc/init.d/firewall ] || warn "firewall init not found."
  [ -x /etc/init.d/network ]  || warn "network init not found."
  ok "OpenWrt detected and running as root."
}

# --- Convert dotted IPv4 to int (portable) ---
ip_to_int() {
  local IFS=.
  set -- $1
  [ "$#" -eq 4 ] || error "Invalid IPv4: $1"
  for oct in "$@"; do
    case "$oct" in ''|*[!0-9]*) error "Invalid IPv4: $1" ;; *) [ "$oct" -ge 0 ] 2>/dev/null && [ "$oct" -le 255 ] 2>/dev/null || error "Invalid octet in IPv4: $1" ;; esac
  done
  echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

# --- IP overlap check vs LAN ---
check_ip_conflict() {
  step "Checking for IP address conflicts..."
  local lan_ip lan_mask lan_ip_i lan_mask_i guest_ip_i guest_mask_i
  lan_ip="$(uci -q get network.lan.ipaddr)"
  lan_mask="$(uci -q get network.lan.netmask)"
  [ -n "$lan_ip" ] && [ -n "$lan_mask" ] || { ok "LAN ip/netmask not set via UCI; skipping overlap check."; return 0; }
  lan_ip_i=$(ip_to_int "$lan_ip")
  lan_mask_i=$(ip_to_int "$lan_mask")
  guest_ip_i=$(ip_to_int "$GUEST_IP")
  guest_mask_i=$(ip_to_int "$GUEST_NETMASK")
  if [ $((lan_ip_i & lan_mask_i)) -eq $((guest_ip_i & lan_mask_i)) ]; then
    error "IP Conflict: LAN (${lan_ip}/${lan_mask}) overlaps with guest (${GUEST_IP}/${GUEST_NETMASK})."
  fi
  if [ $((lan_ip_i & guest_mask_i)) -eq $((guest_ip_i & guest_mask_i)) ]; then
    warn "LAN and Guest subnets share the same guest mask; overlap unlikely but double-check."
  fi
  ok "No IP conflicts detected."
}

# --- Radio detection (robust across versions) ---
RADIO_2G=""; RADIO_HI=""
detect_radios() {
  step "Detecting wireless radios..."
  local radios r band hwmode htmode
  radios="$(uci -q show wireless | sed -n 's/^wireless\.\(radio[^=]*\)=wifi-device.*/\1/p')"
  [ -n "$radios" ] || error "No wifi-device sections found in /etc/config/wireless."

  for r in $radios; do
    band="$(uci -q get wireless."$r".band)"
    hwmode="$(uci -q get wireless."$r".hwmode)"
    htmode="$(uci -q get wireless."$r".htmode)"
    case "$band" in
      2g|2G) [ -z "$RADIO_2G" ] && RADIO_2G="$r" ;;
      5g|5G|6g|6G) [ -z "$RADIO_HI" ] && RADIO_HI="$r" ;;
    esac
    if [ -z "$band" ]; then
      if   echo "$hwmode" | grep -qiE '11b|11g'; then [ -z "$RADIO_2G" ] && RADIO_2G="$r"
      elif echo "$hwmode" | grep -qiE '11a|11ac|11ax|11n'; then [ -z "$RADIO_HI" ] && RADIO_HI="$r"
      elif echo "$htmode" | grep -qiE 'VHT|HE|EHT|160|80'; then [ -z "$RADIO_HI" ] && RADIO_HI="$r"
      fi
    fi
  done

  if [ -z "$RADIO_2G" ]; then set -- $radios; [ -n "$1" ] && RADIO_2G="$1"; fi
  [ -n "$RADIO_2G" ] || error "Could not find a suitable 2.4GHz-capable radio."
  ok "2.4GHz radio: $RADIO_2G"
  if [ -n "$RADIO_HI" ]; then ok "High-band radio (5/6GHz): $RADIO_HI"; else warn "No 5/6GHz radio found. Will only set up a 2.4GHz network."; fi
}

# --- Validate user input (length only; existence handled separately) ---
validate_creds_only() {
  step "Validating user input"
  [ -n "$GUEST_SSID" ] || error "SSID cannot be empty."
  if [ -z "$GUEST_PASSWORD" ]; then error "Password cannot be empty."; fi
  [ "${#GUEST_PASSWORD}" -ge 8 ] || error "Password must be at least 8 characters."
  ok "SSID & password look good."
}

# --- Check if any wifi-iface uses given SSID; print sections ---
ssid_exists() {
  # $1 SSID
  uci show wireless 2>/dev/null | sed -n "s/^wireless\.\(.*\)\.ssid='\(.*\)'/\1\t\2/p" | awk -F'\t' -v s="$1" 'tolower($2)==tolower(s) {print $1}'
}

# --- Choose which existing SSID section to replace (if multiple) ---
select_existing_ssid_section() {
  # $1 SSID
  local ss="$1" idx=1
  MATCHING_SECTIONS="$(ssid_exists "$ss")"
  [ -n "$MATCHING_SECTIONS" ] || return 1

  count=$(printf "%s\n" "$MATCHING_SECTIONS" | wc -l)
  if [ "$count" -eq 1 ]; then
    REPLACE_SECTION="$(printf "%s\n" "$MATCHING_SECTIONS")"
    return 0
  fi

  printf "\n"; alert "Multiple interfaces already use SSID '%s':" "$ss"
  printf "%s\n" "$MATCHING_SECTIONS" | nl -w1 -s') '
  printf "Select which interface to replace [1-%s] (or 0 to cancel): " "$count"
  read sel
  case "$sel" in
    ''|*[!0-9]*) warn "Invalid choice."; return 1 ;;
    0) return 1 ;;
    *)
      [ "$sel" -ge 1 ] && [ "$sel" -le "$count" ] || { warn "Out of range."; return 1; }
      REPLACE_SECTION="$(printf "%s\n" "$MATCHING_SECTIONS" | sed -n "${sel}p")"
      return 0
      ;;
  esac
}

# --- Replace an existing wifi-iface section with guest settings ---
replace_existing_ssid_section() {
  # Uses REPLACE_SECTION, GUEST_SSID, GUEST_PASSWORD; assumes guest network/dhcp/firewall are/will be present
  step "Replacing existing interface wireless.%s with guest settings..." "$REPLACE_SECTION"
  # Ensure radios enabled for that device
  dev="$(uci -q get wireless.${REPLACE_SECTION}.device)"
  [ -n "$dev" ] && uci set wireless.${dev}.disabled='0'
  # Re-point this iface to guest network and set security
  uci set wireless.${REPLACE_SECTION}.mode="ap"
  uci set wireless.${REPLACE_SECTION}.network="${GUEST_CONFIG_NAME}"
  uci set wireless.${REPLACE_SECTION}.ssid="${GUEST_SSID}"
  uci set wireless.${REPLACE_SECTION}.encryption="psk2+ccmp"
  uci set wireless.${REPLACE_SECTION}.key="${GUEST_PASSWORD}"
  uci set wireless.${REPLACE_SECTION}.isolate="1"
  uci set wireless.${REPLACE_SECTION}.wps_pushbutton="0"
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
  uci -q delete firewall.${GUEST_CONFIG_NAME}_dns_hijack
  uci -q delete firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10
  uci -q delete firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172
  uci -q delete firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192
  uci -q delete firewall.${GUEST_CONFIG_NAME}_block_lan
  uci -q delete wireless.${GUEST_CONFIG_NAME}_2g
  uci -q delete wireless.${GUEST_CONFIG_NAME}_hi
  uci commit
  ok "Old guest configuration removed (if present)."
}

# --- Reload Services ---
reload_services() {
  step "Reloading services..."
  /etc/init.d/network reload || warn "Could not reload network."
  /etc/init.d/dnsmasq restart || warn "Could not restart dnsmasq."
  /etc/init.d/firewall restart || warn "Could not restart firewall."
  if command -v wifi >/dev/null 2>&1; then
    wifi reload 2>/dev/null || wifi up 2>/dev/null || warn "Could not reload wifi."
  else
    ubus call network reload 2>/dev/null || true
  fi
}

# --- Setup network ---
setup_network() {
  step "Creating guest network interface..."
  uci set network.${GUEST_CONFIG_NAME}="interface"
  uci set network.${GUEST_CONFIG_NAME}.proto="static"
  uci set network.${GUEST_CONFIG_NAME}.ipaddr="${GUEST_IP}"
  uci set network.${GUEST_CONFIG_NAME}.netmask="${GUEST_NETMASK}"
  uci set network.${GUEST_CONFIG_NAME}.ip6assign="0"   # disable IPv6 on guest
  uci set network.${GUEST_CONFIG_NAME}.type="bridge"
}

# --- Setup DHCP ---
setup_dhcp() {
  step "Setting up DHCP for guest network..."
  uci set dhcp.${GUEST_CONFIG_NAME}="dhcp"
  uci set dhcp.${GUEST_CONFIG_NAME}.interface="${GUEST_CONFIG_NAME}"
  uci set dhcp.${GUEST_CONFIG_NAME}.start="100"
  uci set dhcp.${GUEST_CONFIG_NAME}.limit="150"
  uci set dhcp.${GUEST_CONFIG_NAME}.leasetime="12h"

  printf "Use custom public DNS for guests (1.1.1.1, 8.8.8.8)? [Y/n]: "
  read use_custom_dns
  [ -z "$use_custom_dns" ] && use_custom_dns="Y"
  case "$use_custom_dns" in
    Y|y)
      ok "Custom public DNS will be used (router forwards to 1.1.1.1 & 8.8.8.8)."
      # Pin upstream servers once
      if ! uci show dhcp | grep -q "dnsmasq\\[0\\]\\.server='1.1.1.1'"; then uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'; fi
      if ! uci show dhcp | grep -q "dnsmasq\\[0\\]\\.server='8.8.8.8'"; then uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'; fi
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

  # Force all Guest DNS to router (prevent manual DNS bypass)
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack="redirect"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.name="Force Guest DNS to Router"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.proto="tcp udp"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.src_dport="53"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.dest_port="53"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.target="DNAT"
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.dest_ip="${GUEST_IP}"

  # Block RFC1918 over WAN
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10="rule"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10.name="Block Guest to 10.0.0.0/8 via WAN"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10.dest="wan"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10.dest_ip="10.0.0.0/8"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_10.target="REJECT"

  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172="rule"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172.name="Block Guest to 172.16.0.0/12 via WAN"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172.dest="wan"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172.dest_ip="172.16.0.0/12"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_172.target="REJECT"

  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192="rule"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192.name="Block Guest to 192.168.0.0/16 via WAN"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192.src="${GUEST_CONFIG_NAME}"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192.dest="wan"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192.dest_ip="192.168.0.0/16"
  uci set firewall.${GUEST_CONFIG_NAME}_block_rfc1918_192.target="REJECT"
}

# --- Setup Wi‑Fi (fresh creation path) ---
setup_wifi() {
  step "Setting up Guest SSID(s)..."
  # Ensure radios are enabled
  uci set wireless.${RADIO_2G}.disabled='0'
  [ -n "$RADIO_HI" ] && uci set wireless.${RADIO_HI}.disabled='0'

  uci set wireless.${GUEST_CONFIG_NAME}_2g="wifi-iface"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.device="${RADIO_2G}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.mode="ap"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.network="${GUEST_CONFIG_NAME}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.ssid="${GUEST_SSID}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.encryption="psk2+ccmp"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.key="${GUEST_PASSWORD}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.isolate="1"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.wps_pushbutton="0"

  if [ -n "$RADIO_HI" ]; then
    printf "Also create a 5/6GHz guest SSID? [Y/n]: "
    read create_hi
    [ -z "$create_hi" ] && create_hi="Y"
    case "$create_hi" in
      Y|y)
        step "Creating high-band (5/6GHz) Guest SSID..."
        uci set wireless.${GUEST_CONFIG_NAME}_hi="wifi-iface"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.device="${RADIO_HI}"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.mode="ap"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.network="${GUEST_CONFIG_NAME}"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.ssid="${GUEST_SSID}-5G"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.encryption="psk2+ccmp"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.key="${GUEST_PASSWORD}"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.isolate="1"
        uci set wireless.${GUEST_CONFIG_NAME}_hi.wps_pushbutton="0"
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
    printf "\n"; ok "Scan this QR Code to connect (2.4GHz):"
    qrencode -t ANSIUTF8 "WIFI:T:WPA;S:${GUEST_SSID};P:${GUEST_PASSWORD};;"
  else
    warn "qrencode not installed. Install with: opkg update && opkg install qrencode"
  fi
}

# --- Backup helpers ---
backup_configs_light() {
  step "Creating pre-change backup of key configs..."
  local ts out files existing f
  ts="$(timestamp)"; out="guestwifi-prechange-${ts}.tar.gz"
  files="/etc/config/network /etc/config/wireless /etc/config/dhcp /etc/config/firewall /etc/config/system"
  existing=""; for f in $files; do [ -f "$f" ] && existing="$existing $f"; done
  if [ -n "$existing" ]; then
    tar -czf "$out" $existing 2>/dev/null || { warn "tar failed creating pre-change backup."; return 1; }
    ok "Pre-change backup saved: $out"
  else
    warn "No config files found to back up (unexpected)."
  fi
}
full_backup() {
  step "Creating full system backup for migration..."
  local ts out; ts="$(timestamp)"; out="openwrt-backup-${ts}.tar.gz"
  if command -v sysupgrade >/dev/null 2>&1; then
    sysupgrade -b "$out" >/dev/null 2>&1 || { warn "sysupgrade -b failed; falling back to /etc archive."; (cd / && tar -czf "$PWD/$out" etc) || error "Fallback backup failed."; }
  else
    warn "sysupgrade not found; using /etc archive fallback."; (cd / && tar -czf "$PWD/$out" etc) || error "Fallback backup failed."
  fi
  ok "Backup saved: $out"
}
restore_backup() {
  step "Restore backup selected."
  local file
  if [ -f "./restore.tar.gz" ]; then file="./restore.tar.gz"
  else set -- ./restore*.tar.gz; [ -e "$1" ] && [ ! -e "$2" ] && file="$1"
  fi
  if [ -z "$file" ]; then printf "Enter path to backup tar.gz to restore: "; read file; fi
  [ -f "$file" ] || error "File not found: $file"
  local help; help="$(sysupgrade -h 2>&1)"
  if echo "$help" | grep -q -- "--restore-backup"; then
    step "Restoring via: sysupgrade --restore-backup \"$file\""; sysupgrade --restore-backup "$file" || error "Restore failed."
  elif echo "$help" | grep -q -- "-r "; then
    step "Restoring via: sysupgrade -r \"$file\""; sysupgrade -r "$file" || error "Restore failed."
  else
    warn "No sysupgrade restore flag detected; attempting safe manual extract."; tar -xzf "$file" -C / || error "Manual extract failed."
  fi
  if ask_yn "Restore complete. Reboot now to ensure all services apply?"; then sync; sleep 1; reboot; else reload_services; ok "Restored config reloaded without reboot (some changes may still require reboot)."; fi
}

# --- Existing guest notice (printed before the menu) ---
existing_guest_note() {
  local found=0
  uci -q get network.${GUEST_CONFIG_NAME}.proto >/dev/null 2>&1 && found=1
  uci -q get wireless.${GUEST_CONFIG_NAME}_2g.device >/dev/null 2>&1 && found=1
  uci -q get wireless.${GUEST_CONFIG_NAME}_hi.device >/dev/null 2>&1 && found=1
  if [ "$found" -eq 1 ]; then
    alert "Guest network already exists — choose option 1 to re-deploy cleanly (a pre-change backup will be made)."
  fi
}

# --- Menu ---
show_menu() {
  printf "\n"
  printf "1) Run Guest Wi‑Fi generator (fresh install / re-deploy)\n"
  printf "2) Perform full system backup (migration/upgrade safe)\n"
  printf "3) Restore backup (looks for ./restore*.tar.gz)\n"
  printf "4) Exit\n"
  printf "Select [1-4]: "
}

# --- Main ---
main() {
  show_banner
  existing_guest_note

  if [ "$ACTION" = "uninstall" ]; then
    remove_guest_network
    reload_services
    ok "Guest network successfully removed."
    exit 0
  fi

  while :; do
    show_menu
    read choice
    case "$choice" in
      1)
        system_checks
        check_ip_conflict
        detect_radios

        # Confirm proceed to Wi-Fi configuration (user may want to go back to menu)
        if ! ask_yn "Pre-flight checks complete. Configure/replace Guest Wi‑Fi now?"; then
          info "Returning to main menu."; continue
        fi

        printf "\n"
        step "Please provide details for the Guest Wi‑Fi."
        printf "Enter the Guest Wi‑Fi Name (SSID): "
        read GUEST_SSID

        if command -v stty >/dev/null 2>&1; then
          printf "Enter the Guest Wi‑Fi Password (min 8 chars): "
          stty -echo; read GUEST_PASSWORD; stty echo; printf "\n"
        else
          warn "stty not available; password will be echoed."
          printf "Enter the Guest Wi‑Fi Password (min 8 chars): "
          read GUEST_PASSWORD
        fi
        printf "\n"

        validate_creds_only

        # If SSID exists, offer to replace one interface using that SSID
        EXISTING="$(ssid_exists "$GUEST_SSID")"
        if [ -n "$EXISTING" ]; then
          alert "SSID '%s' already exists on this router." "$GUEST_SSID"
          if ask_yn "Replace one of the existing interfaces using '${GUEST_SSID}' with a Guest interface?"; then
            if select_existing_ssid_section "$GUEST_SSID"; then
              REPLACE_MODE=1
              info "Will replace wireless.%s" "$REPLACE_SECTION"
            else
              warn "No interface selected for replacement. Returning to main menu."
              continue
            fi
          else
            info "User declined to replace existing SSID. Returning to main menu."
            continue
          fi
        fi

        backup_configs_light || true

        # Ensure guest L3/L4 exists
        setup_network
        setup_dhcp
        setup_firewall

        if [ "$REPLACE_MODE" -eq 1 ] && [ -n "$REPLACE_SECTION" ]; then
          replace_existing_ssid_section
        else
          # Fresh creation path (create new guest SSIDs)
          setup_wifi
        fi

        apply_changes

        printf "\n"
        ok "Guest Wi‑Fi Setup Complete!"
        printf "SSID: %s\n" "$GUEST_SSID"
        [ "$REPLACE_MODE" -eq 0 ] && [ -n "$RADIO_HI" ] && printf "SSID (5/6GHz): %s-5G\n" "$GUEST_SSID"
        printf "Password: (hidden)\n"
        printf "Clients on this network are isolated from your main LAN and from each other.\n"
        show_qr
        REPLACE_MODE=0; REPLACE_SECTION=""
        ;;
      2)
        system_checks
        full_backup
        printf "\n"
        ;;
      3)
        system_checks
        restore_backup
        ;;
      4)
        ok "Bye."
        exit 0
        ;;
      *)
        warn "Invalid selection. Please choose 1-4."
        ;;
    esac
  done
}

main "$@"

