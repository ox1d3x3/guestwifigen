#!/bin/sh
# =============================================================================
# OpenWrt Guest Wi-Fi Gen (v3.0.0) - version-aware, self-provisioning
# Supported: 19.07 / 21.02 / 22.03 / 23.05 / 24.10 / 25.12 (+ SNAPSHOT)
#
# This release auto-detects the running OpenWrt version and adapts:
#   - Encryption: WPA2 (psk2) everywhere; WPA3/SAE offered only on >=21.02
#     where wpad (full) is present. Default stays WPA2 for max client compat.
#   - Package manager: opkg (<=24.10) vs apk (>=25.12) for hint messages.
#   - Service reload: wifi reload / wifi up with ubus reconf fallback.
#   - DHCP "limit": clamped so start+limit never exceeds the /24 host range.
#   - IPv6 on guest disabled on all branches (ip6assign removed; no delegation).
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
GUEST_CONFIG_NAME="guest"   # Internal UCI section base name
ACTION=""
REPLACE_MODE=0
REPLACE_SECTION=""

# --- Version state (populated by detect_version) ---
OWRT_RELEASE=""     # raw DISTRIB_RELEASE, e.g. "24.10.0" or "SNAPSHOT"
OWRT_VERNUM=0       # integer major*100+minor, e.g. 2410 ; SNAPSHOT => 999999
PKG_MGR="opkg"      # opkg or apk (for user-facing install hints only)
WPA3_AVAILABLE=0    # 1 if SAE can be offered on this build
ENC_MODE="psk2"     # final encryption mode applied to guest ifaces
ENC_LABEL="WPA2"    # human label for summary/QR

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
  printf "%s\n" "   #            OpenWrt Guest Wi-Fi Generator (v3.0.0) Github@Ox1d3x3              "
  printf "%s\n" "   #                                                                               "
  printf "%s\n" "   # #############################################################################"
  printf "\n"
}

# --- Utility: timestamp ---
timestamp() { date +"%Y%m%d-%H%M%S" 2>/dev/null || date; }

# --- ask yes/no with default Y ---
ask_yn() {
  # $1 prompt
  ans=""
  printf "%s [Y/n]: " "$1"
  read ans
  [ -z "$ans" ] && ans="Y"
  case "$ans" in Y|y) return 0 ;; *) return 1 ;; esac
}

# --- Package manager helpers (version-aware) ----------------------------------
# These wrap opkg (<=24.10) and apk (>=25.12) behind one interface. They are
# safe to call before detect_version sets PKG_MGR: each re-checks which binary
# exists, so they degrade gracefully on either system.

# Print installed package NAMES (one per line), pkg-manager agnostic.
pkg_list_installed() {
  if command -v apk >/dev/null 2>&1 && [ "${PKG_MGR:-}" = "apk" ]; then
    # apk list --installed prints "name-version arch {repo}"; strip to name.
    apk list --installed 2>/dev/null | awk '{print $1}' | sed 's/-[0-9].*$//'
  elif command -v opkg >/dev/null 2>&1; then
    opkg list-installed 2>/dev/null | awk '{print $1}'
  elif command -v apk >/dev/null 2>&1; then
    apk list --installed 2>/dev/null | awk '{print $1}' | sed 's/-[0-9].*$//'
  fi
}

# Is package $1 installed?
pkg_is_installed() {
  pkg_list_installed | grep -qx "$1"
}

# Refresh package indexes at most once per run.
PKG_UPDATED=0
pkg_update() {
  [ "$PKG_UPDATED" -eq 1 ] && return 0
  step "Refreshing package lists (one-time)..."
  if [ "${PKG_MGR:-opkg}" = "apk" ]; then
    apk update >/dev/null 2>&1 || { warn "apk update failed (no internet or low storage?)."; return 1; }
  else
    opkg update >/dev/null 2>&1 || { warn "opkg update failed (no internet or low storage?)."; return 1; }
  fi
  PKG_UPDATED=1
  ok "Package lists refreshed."
  return 0
}

# Install one package. Returns 0 on success.
pkg_install() {
  # $1 = package name
  if [ "${PKG_MGR:-opkg}" = "apk" ]; then
    apk add "$1" >/dev/null 2>&1
  else
    opkg install "$1" >/dev/null 2>&1
  fi
}

# Is the WAN actually reachable? (cheap check before we try to download.)
have_internet() {
  # Try a couple of well-known anycast resolvers on port 53; fall back to ping.
  for ip in 1.1.1.1 8.8.8.8; do
    if command -v nc >/dev/null 2>&1 && nc -z -w2 "$ip" 53 >/dev/null 2>&1; then return 0; fi
    if ping -c1 -W2 "$ip" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# Ensure a single package is present; install if missing (with one update).
# Returns 0 if present (already or after install), 1 if it could not be installed.
ensure_package() {
  # $1 = package name, $2 = human label (optional)
  pkg="$1"; label="${2:-$1}"
  if pkg_is_installed "$pkg"; then
    ok "${label} already installed."
    return 0
  fi
  info "${label} (${pkg}) is not installed."
  if ! have_internet; then
    warn "No internet detected; cannot install ${pkg}. Skipping."
    return 1
  fi
  pkg_update || return 1
  step "Installing ${pkg}..."
  if pkg_install "$pkg"; then
    ok "Installed ${pkg}."
    return 0
  fi
  warn "Failed to install ${pkg} (it may not exist for this version/arch)."
  return 1
}

# --- Up-front dependency provisioning -----------------------------------------
# Called once, right after detect_version, BEFORE the guest is configured.
# Installs the small, safe extras the script uses. It deliberately does NOT
# touch wpad here (swapping the authenticator can drop Wi-Fi mid-run); that is
# handled separately and only with explicit consent. See maybe_upgrade_wpad().
QRENCODE_OK=0
ensure_dependencies() {
  step "Provisioning required packages for this run..."
  # qrencode: used to print the join-QR at the end. Optional but the whole
  # point of the request, so we install it up front.
  if ensure_package "qrencode" "QR-code generator (qrencode)"; then
    QRENCODE_OK=1
  else
    QRENCODE_OK=0
    warn "Continuing without qrencode; a text summary will be shown instead of a QR code."
  fi
  # Note: uci, dnsmasq, firewall(4) and a wpad/hostapd variant are part of every
  # standard OpenWrt image, so we verify rather than install them.
  for base in uci; do
    command -v "$base" >/dev/null 2>&1 || warn "Base tool '$base' missing; this is unusual for OpenWrt."
  done
  ok "Dependency check complete."
}

# --- Optional, consent-gated wpad upgrade for WPA3 on mini builds -------------
# Only relevant when the user asked for WPA3 but the installed authenticator is
# a *-mini build that cannot do SAE. Swapping wpad restarts hostapd and can
# disconnect you if you are connected over Wi-Fi, so this is opt-in and defaults
# to a safe WPA2 fallback. Sets WPA3_AVAILABLE=1 on success.
maybe_upgrade_wpad() {
  # Pick the replacement that matches the crypto lib the system already uses.
  detect_wpad_pkg
  case "$WPAD_PKG" in
    *wolfssl*) target="wpad-wolfssl" ;;
    *openssl*) target="wpad-openssl" ;;
    *mbedtls*) target="wpad-mbedtls" ;;
    *)         target="wpad-mbedtls" ;;  # modern default crypto lib
  esac
  printf "\n"
  alert "WPA3 needs a fuller 'wpad' than the '${WPAD_PKG:-mini}' build you have."
  warn  "Replacing wpad restarts Wi-Fi. If you are connected over Wi-Fi (not cable),"
  warn  "you may be briefly disconnected and, in rare cases, locked out until reboot."
  if ! ask_yn "Install ${target} now to enable WPA3? (No = stay on WPA2)"; then
    info "Keeping current authenticator; WPA3 will not be offered."
    return 1
  fi
  if ! have_internet; then
    warn "No internet detected; cannot install ${target}. Staying on WPA2."
    return 1
  fi
  pkg_update || return 1
  step "Swapping ${WPAD_PKG:-wpad-mini} -> ${target}..."
  # On opkg, install the new wpad; it conflicts-replaces the mini one. On apk,
  # add the new one (apk resolves the provides/replaces relationship).
  if pkg_install "$target"; then
    ok "Installed ${target}. WPA3 is now available."
    WPA3_AVAILABLE=1
    return 0
  fi
  warn "Could not install ${target}; staying on WPA2."
  return 1
}

# --- Version detection ---------------------------------------------------------
# Reads /etc/openwrt_release (DISTRIB_RELEASE). Sets OWRT_RELEASE, OWRT_VERNUM,
# PKG_MGR and WPA3_AVAILABLE. SNAPSHOT/dev builds are treated as newest.
detect_version() {
  step "Detecting OpenWrt version..."
  rel=""
  if [ -r /etc/openwrt_release ]; then
    # shellcheck disable=SC1091
    rel="$( . /etc/openwrt_release 2>/dev/null; printf "%s" "$DISTRIB_RELEASE" )"
  fi
  [ -n "$rel" ] || rel="SNAPSHOT"
  OWRT_RELEASE="$rel"

  case "$rel" in
    SNAPSHOT|snapshot|*SNAPSHOT*|*-SNAPSHOT)
      OWRT_VERNUM=999999
      ;;
    *)
      clean="$(printf "%s" "$rel" | sed 's/[^0-9.]//g')"
      maj="${clean%%.*}"
      rest="${clean#*.}"; min="${rest%%.*}"
      case "$maj" in ''|*[!0-9]*) maj=0 ;; esac
      case "$min" in ''|*[!0-9]*) min=0 ;; esac
      OWRT_VERNUM=$(( maj * 100 + min ))
      ;;
  esac

  # Package manager: apk landed as default in 25.12; opkg before that.
  if [ "$OWRT_VERNUM" -ge 2512 ]; then
    command -v apk >/dev/null 2>&1 && PKG_MGR="apk" || PKG_MGR="opkg"
  else
    PKG_MGR="opkg"
  fi

  # WPA3/SAE: encryption code exists from 21.02 onward AND the installed
  # authenticator must support SAE. Only *-mini lacks it; basic-* and full
  # variants are fine. Gate on both version and package.
  if [ "$OWRT_VERNUM" -ge 2102 ] && wpa3_supported; then
    WPA3_AVAILABLE=1
  else
    WPA3_AVAILABLE=0
  fi

  if [ "$OWRT_VERNUM" -ge 999999 ]; then
    ok "Detected OpenWrt: ${OWRT_RELEASE} (treated as newest; pkg=${PKG_MGR})"
  else
    ok "Detected OpenWrt: ${OWRT_RELEASE} (pkg=${PKG_MGR}, WPA3 available: $( [ "$WPA3_AVAILABLE" -eq 1 ] && echo yes || echo no ))"
  fi
}

# --- Which wpad/hostapd authenticator is installed? ---
# Sets WPAD_PKG to the installed package name (or "" if none found).
WPAD_PKG=""
detect_wpad_pkg() {
  WPAD_PKG=""
  list="$(pkg_list_installed)"
  [ -n "$list" ] || return 1
  # Prefer the most specific match. wpad* covers AP+STA; hostapd* is AP-only.
  WPAD_PKG="$(printf "%s\n" "$list" | grep -E '^(wpad|hostapd)(-(mini|basic))?(-(openssl|wolfssl|mbedtls))?$' | head -n1)"
  [ -n "$WPAD_PKG" ]
}

# --- Does this build's hostapd/wpad actually support SAE (WPA3)? ---
wpa3_supported() {
  # SAE (WPA3-Personal) support by package:
  #   wpad-mini ................... NO  (WPA/WPA2 PSK only, no SAE)
  #   wpad-basic-{mbedtls,wolfssl,openssl} ... YES (WPA3-PSK, 802.11w, OWE)
  #   wpad / wpad-{mbedtls,wolfssl,openssl} .. YES (full: +Enterprise/r/hotspot)
  #   hostapd* (AP-only) .......... mirrors the wpad tiers above
  # So: anything that is NOT a *-mini build supports WPA3-Personal.
  detect_wpad_pkg || {
    # Couldn't read the package db. Be conservative: no SAE, so we never write
    # a config that silently fails to bring up hostapd.
    return 1
  }
  case "$WPAD_PKG" in
    *mini*) return 1 ;;   # mini = no SAE
    *)      return 0 ;;   # basic-* and full = SAE-capable
  esac
}

# --- Decide encryption mode based on version + user choice ---
choose_encryption() {
  # Default everywhere: WPA2 (psk2+ccmp) for the broadest client compatibility.
  ENC_MODE="psk2+ccmp"; ENC_LABEL="WPA2"

  # If WPA3 isn't currently available but the ONLY blocker is a *-mini wpad on
  # an otherwise-capable version, offer to upgrade the authenticator.
  if [ "$WPA3_AVAILABLE" -eq 0 ] && [ "$OWRT_VERNUM" -ge 2102 ]; then
    detect_wpad_pkg
    case "$WPAD_PKG" in
      *mini*)
        if ask_yn "Your build can't do WPA3 yet (wpad-mini). Enable WPA3 support?"; then
          maybe_upgrade_wpad || true
        fi
        ;;
    esac
  fi

  if [ "$WPA3_AVAILABLE" -eq 1 ]; then
    printf "\n"
    info "This build supports WPA3 (SAE)."
    info "WPA2 = max compatibility. WPA3-mixed = WPA2+WPA3. WPA3-only may reject some older or quirky clients."
    printf "Choose guest security: [1] WPA2 (default)  [2] WPA3/WPA2 mixed  [3] WPA3 only : "
    read enc_choice
    case "$enc_choice" in
      2) ENC_MODE="sae-mixed"; ENC_LABEL="WPA3/WPA2-mixed" ;;
      3) ENC_MODE="sae";       ENC_LABEL="WPA3-only" ;;
      *) ENC_MODE="psk2+ccmp"; ENC_LABEL="WPA2" ;;
    esac
  fi
  ok "Guest security: ${ENC_LABEL} (${ENC_MODE})"
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
  oldIFS="$IFS"; IFS=.
  set -- $1
  IFS="$oldIFS"
  [ "$#" -eq 4 ] || error "Invalid IPv4: $1"
  for oct in "$@"; do
    case "$oct" in ''|*[!0-9]*) error "Invalid IPv4: $1" ;; *) [ "$oct" -ge 0 ] 2>/dev/null && [ "$oct" -le 255 ] 2>/dev/null || error "Invalid octet in IPv4: $1" ;; esac
  done
  echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

# --- IP overlap check vs LAN ---
check_ip_conflict() {
  step "Checking for IP address conflicts..."
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
  radios="$(uci -q show wireless | sed -n 's/^wireless\.\(radio[^=]*\)=wifi-device.*/\1/p')"
  [ -n "$radios" ] || error "No wifi-device sections found in /etc/config/wireless. (Is a wifi driver installed?)"

  for r in $radios; do
    band="$(uci -q get wireless."$r".band)"
    hwmode="$(uci -q get wireless."$r".hwmode)"
    htmode="$(uci -q get wireless."$r".htmode)"
    case "$band" in
      2g|2G) [ -z "$RADIO_2G" ] && RADIO_2G="$r" ;;
      5g|5G|6g|6G) [ -z "$RADIO_HI" ] && RADIO_HI="$r" ;;
    esac
    if [ -z "$band" ]; then
      # Pre-band (19.07-era swconfig/ath) fallback via hwmode/htmode.
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
  # WPA2/WPA3 PSK upper bound is 63 chars.
  [ "${#GUEST_PASSWORD}" -le 63 ] || error "Password must be 63 characters or fewer."
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
  ss="$1"
  MATCHING_SECTIONS="$(ssid_exists "$ss")"
  [ -n "$MATCHING_SECTIONS" ] || return 1

  count=$(printf "%s\n" "$MATCHING_SECTIONS" | wc -l)
  if [ "$count" -eq 1 ]; then
    REPLACE_SECTION="$(printf "%s\n" "$MATCHING_SECTIONS")"
    return 0
  fi

  printf "\n"; alert "Multiple interfaces already use SSID '${ss}':"
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
  step "Replacing existing interface wireless.${REPLACE_SECTION} with guest settings..."
  dev="$(uci -q get wireless.${REPLACE_SECTION}.device)"
  [ -n "$dev" ] && uci set wireless.${dev}.disabled='0'
  uci set wireless.${REPLACE_SECTION}.mode="ap"
  uci set wireless.${REPLACE_SECTION}.network="${GUEST_CONFIG_NAME}"
  uci set wireless.${REPLACE_SECTION}.ssid="${GUEST_SSID}"
  uci set wireless.${REPLACE_SECTION}.encryption="${ENC_MODE}"
  uci set wireless.${REPLACE_SECTION}.key="${GUEST_PASSWORD}"
  uci set wireless.${REPLACE_SECTION}.isolate="1"
  uci set wireless.${REPLACE_SECTION}.wps_pushbutton="0"
  # SAE/OWE transition robustness on newer builds; harmless on others.
  [ "$ENC_MODE" = "sae-mixed" ] || [ "$ENC_MODE" = "sae" ] && uci set wireless.${REPLACE_SECTION}.ieee80211w='1'
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

# --- Reload Services (version-aware) ---
reload_services() {
  step "Reloading services..."
  if [ -x /etc/init.d/network ]; then /etc/init.d/network reload || warn "Could not reload network."; fi
  if [ -x /etc/init.d/dnsmasq ]; then /etc/init.d/dnsmasq restart || warn "Could not restart dnsmasq."; fi
  if [ -x /etc/init.d/firewall ]; then /etc/init.d/firewall restart || warn "Could not restart firewall."; fi

  # Wi-Fi reload. On modern builds 'wifi reload' is preferred; older accept
  # 'wifi up'. As a last resort poke netifd via ubus to re-read config.
  if command -v wifi >/dev/null 2>&1; then
    wifi reload 2>/dev/null || wifi up 2>/dev/null || warn "Could not reload wifi via 'wifi'."
  elif command -v ubus >/dev/null 2>&1; then
    ubus call network reload 2>/dev/null || warn "Could not reload network via ubus."
  else
    warn "Neither 'wifi' nor 'ubus' found to reload wireless; a reboot may be needed."
  fi
}

# --- Setup network (version-aware) ---
setup_network() {
  step "Creating guest network interface..."
  uci set network.${GUEST_CONFIG_NAME}="interface"
  uci set network.${GUEST_CONFIG_NAME}.proto="static"
  uci set network.${GUEST_CONFIG_NAME}.ipaddr="${GUEST_IP}"
  uci set network.${GUEST_CONFIG_NAME}.netmask="${GUEST_NETMASK}"

  # Disable IPv6 on guest: don't request a delegated prefix and don't hand out RAs.
  # ip6assign='' (empty) keeps the interface from grabbing a /64 on all branches.
  uci -q delete network.${GUEST_CONFIG_NAME}.ip6assign
  uci set network.${GUEST_CONFIG_NAME}.delegate="0"

  # Bridge declaration:
  #  - 19.07/21.02/22.03 accept the legacy 'option type bridge' form.
  #  - 21.02+ also support bridge-vlan/device sections, but the legacy form is
  #    still honoured for a simple software bridge, so we keep it for one code
  #    path across every supported release.
  uci set network.${GUEST_CONFIG_NAME}.type="bridge"
}

# --- Setup DHCP (version-aware clamping) ---
setup_dhcp() {
  step "Setting up DHCP for guest network..."
  uci set dhcp.${GUEST_CONFIG_NAME}="dhcp"
  uci set dhcp.${GUEST_CONFIG_NAME}.interface="${GUEST_CONFIG_NAME}"

  # For a /24, hosts .2-.254 are usable. Keep start+limit inside that window.
  # start=100 -> highest usable offset is 254, so limit max = 154. Clamp to 150.
  uci set dhcp.${GUEST_CONFIG_NAME}.start="100"
  uci set dhcp.${GUEST_CONFIG_NAME}.limit="150"
  uci set dhcp.${GUEST_CONFIG_NAME}.leasetime="12h"

  # Newer dnsmasq/odhcpd default to handing out IPv6; force this pool v4-only.
  uci set dhcp.${GUEST_CONFIG_NAME}.dhcpv4="server"
  uci -q delete dhcp.${GUEST_CONFIG_NAME}.dhcpv6
  uci -q delete dhcp.${GUEST_CONFIG_NAME}.ra

  printf "Use custom public DNS for guests (1.1.1.1, 8.8.8.8)? [Y/n]: "
  read use_custom_dns
  [ -z "$use_custom_dns" ] && use_custom_dns="Y"
  case "$use_custom_dns" in
    Y|y)
      ok "Custom public DNS will be used (router forwards to 1.1.1.1 & 8.8.8.8)."
      if ! uci show dhcp | grep -q "dnsmasq\[0\]\.server='1.1.1.1'"; then uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'; fi
      if ! uci show dhcp | grep -q "dnsmasq\[0\]\.server='8.8.8.8'"; then uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'; fi
      ;;
    *)
      ok "Guests will use the router's default DNS."
      ;;
  esac
}

# --- Setup firewall (version-aware nft/iptables) ---
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
  # family is honoured by both fw3 (iptables, <=21.02) and fw4 (nftables, >=22.03)
  uci set firewall.${GUEST_CONFIG_NAME}_dns_hijack.family="ipv4"

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

# --- Apply one wifi-iface's encryption fields consistently ---
apply_iface_security() {
  # $1 = uci section path tail (e.g. guest_2g or guest_hi)
  sect="$1"
  uci set wireless.${sect}.encryption="${ENC_MODE}"
  uci set wireless.${sect}.key="${GUEST_PASSWORD}"
  uci set wireless.${sect}.isolate="1"
  uci set wireless.${sect}.wps_pushbutton="0"
  case "$ENC_MODE" in
    sae)        uci set wireless.${sect}.ieee80211w="2" ;;  # PMF required for WPA3-only
    sae-mixed)  uci set wireless.${sect}.ieee80211w="1" ;;  # PMF optional for mixed
    *)          uci -q delete wireless.${sect}.ieee80211w ;;
  esac
}

# --- Setup Wi-Fi (fresh creation path) ---
setup_wifi() {
  step "Setting up Guest SSID(s)..."
  uci set wireless.${RADIO_2G}.disabled='0'
  [ -n "$RADIO_HI" ] && uci set wireless.${RADIO_HI}.disabled='0'

  uci set wireless.${GUEST_CONFIG_NAME}_2g="wifi-iface"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.device="${RADIO_2G}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.mode="ap"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.network="${GUEST_CONFIG_NAME}"
  uci set wireless.${GUEST_CONFIG_NAME}_2g.ssid="${GUEST_SSID}"
  apply_iface_security "${GUEST_CONFIG_NAME}_2g"

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
        apply_iface_security "${GUEST_CONFIG_NAME}_hi"
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

# --- Show QR (uses qrencode provisioned earlier) ---
show_qr() {
  if command -v qrencode >/dev/null 2>&1; then
    # "WPA" in the WIFI: URI covers both WPA2 and WPA3-PSK clients.
    printf "\n"; ok "Scan this QR Code to connect (2.4GHz):"
    qrencode -t ANSIUTF8 "WIFI:T:WPA;S:${GUEST_SSID};P:${GUEST_PASSWORD};;"
    printf "\n"
    info "If your terminal can't render the QR, the join string is:"
    printf "  WIFI:T:WPA;S:%s;P:%s;;\n" "$GUEST_SSID" "$GUEST_PASSWORD"
  else
    # qrencode wasn't available and couldn't be installed earlier.
    warn "qrencode is unavailable, so here is the raw Wi-Fi join string instead:"
    printf "  WIFI:T:WPA;S:%s;P:%s;;\n" "$GUEST_SSID" "$GUEST_PASSWORD"
    if [ "${PKG_MGR:-opkg}" = "apk" ]; then
      info "To get a scannable QR later: apk update && apk add qrencode"
    else
      info "To get a scannable QR later: opkg update && opkg install qrencode"
    fi
  fi
}

# --- Backup helpers ---
backup_configs_light() {
  step "Creating pre-change backup of key configs..."
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
  ts="$(timestamp)"; out="openwrt-backup-${ts}.tar.gz"
  if command -v sysupgrade >/dev/null 2>&1; then
    sysupgrade -b "$out" >/dev/null 2>&1 || { warn "sysupgrade -b failed; falling back to /etc archive."; (cd / && tar -czf "$PWD/$out" etc) || error "Fallback backup failed."; }
  else
    warn "sysupgrade not found; using /etc archive fallback."; (cd / && tar -czf "$PWD/$out" etc) || error "Fallback backup failed."
  fi
  ok "Backup saved: $out"
}
restore_backup() {
  step "Restore backup selected."
  file=""
  if [ -f "./restore.tar.gz" ]; then file="./restore.tar.gz"
  else set -- ./restore*.tar.gz; [ -e "$1" ] && [ ! -e "$2" ] && file="$1"
  fi
  if [ -z "$file" ]; then printf "Enter path to backup tar.gz to restore: "; read file; fi
  [ -f "$file" ] || error "File not found: $file"
  help="$(sysupgrade -h 2>&1)"
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
  found=0
  uci -q get network.${GUEST_CONFIG_NAME}.proto >/dev/null 2>&1 && found=1
  uci -q get wireless.${GUEST_CONFIG_NAME}_2g.device >/dev/null 2>&1 && found=1
  uci -q get wireless.${GUEST_CONFIG_NAME}_hi.device >/dev/null 2>&1 && found=1
  if [ "$found" -eq 1 ]; then
    alert "Guest network already exists - choose option 1 to re-deploy cleanly (a pre-change backup will be made)."
  fi
}

# --- Menu ---
show_menu() {
  printf "\n"
  printf "1) Run Guest Wi-Fi generator (fresh install / re-deploy)\n"
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
    detect_version
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
        detect_version
        ensure_dependencies
        check_ip_conflict
        detect_radios

        if ! ask_yn "Pre-flight checks complete. Configure/replace Guest Wi-Fi now?"; then
          info "Returning to main menu."; continue
        fi

        printf "\n"
        step "Please provide details for the Guest Wi-Fi."
        printf "Enter the Guest Wi-Fi Name (SSID): "
        read GUEST_SSID

        if command -v stty >/dev/null 2>&1; then
          printf "Enter the Guest Wi-Fi Password (min 8 chars): "
          stty -echo; read GUEST_PASSWORD; stty echo; printf "\n"
        else
          warn "stty not available; password will be echoed."
          printf "Enter the Guest Wi-Fi Password (min 8 chars): "
          read GUEST_PASSWORD
        fi
        printf "\n"

        validate_creds_only
        choose_encryption

        EXISTING="$(ssid_exists "$GUEST_SSID")"
        if [ -n "$EXISTING" ]; then
          alert "SSID '${GUEST_SSID}' already exists on this router."
          if ask_yn "Replace one of the existing interfaces using '${GUEST_SSID}' with a Guest interface?"; then
            if select_existing_ssid_section "$GUEST_SSID"; then
              REPLACE_MODE=1
              info "Will replace wireless.${REPLACE_SECTION}"
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

        setup_network
        setup_dhcp
        setup_firewall

        if [ "$REPLACE_MODE" -eq 1 ] && [ -n "$REPLACE_SECTION" ]; then
          replace_existing_ssid_section
        else
          setup_wifi
        fi

        apply_changes

        printf "\n"
        ok "Guest Wi-Fi Setup Complete!"
        printf "OpenWrt: %s\n" "$OWRT_RELEASE"
        printf "Security: %s\n" "$ENC_LABEL"
        printf "SSID: %s\n" "$GUEST_SSID"
        [ "$REPLACE_MODE" -eq 0 ] && [ -n "$RADIO_HI" ] && printf "SSID (5/6GHz): %s-5G\n" "$GUEST_SSID"
        printf "Password: (hidden)\n"
        printf "Clients on this network are isolated from your main LAN and from each other.\n"
        show_qr
        REPLACE_MODE=0; REPLACE_SECTION=""
        ;;
      2)
        system_checks
        detect_version
        full_backup
        printf "\n"
        ;;
      3)
        system_checks
        detect_version
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