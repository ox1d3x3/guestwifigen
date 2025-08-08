#!/bin/sh
# =============================================================================
# OpenWrt Guest Wi-Fi Gen (v1.8.2)
# =============================================================================
# Usage:
#   - Install:  ./GuestWifiGen_v1.8.2.sh [--ip <guest_ip>]
#   - Uninstall: ./GuestWifiGen_v1.8.2.sh uninstall
# =============================================================================

# --- Colors ---
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"

# --- Static Configuration ---
GUEST_IP="192.168.10.1"
GUEST_NETMASK="255.255.255.0"
GUEST_CONFIG_NAME="guest" # Internal name for UCI sections
create_5g="" # Always defined

# --- Helper functions ---
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }
step()  { echo -e "${CYAN}▶ $1${NC}"; }

sleep 3

# --- Optional CLI argument for guest IP ---
for arg in "$@"; do
    case $arg in
        --ip)
            shift
            GUEST_IP="$1"
            ;;
    esac
done

# --- Convert IP to integer for comparison ---
ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo "$((a << 24 | b << 16 | c << 8 | d))"
}

# --- Radio Detection ---
detect_radios() {
    step "Detecting wireless radios..."
    RADIO_2G=""
    RADIO_5G=""
    for radio in $(uci show wireless | grep 'wifi-device' | cut -d'.' -f2 | cut -d'=' -f1); do
        local band=$(uci -q get wireless."${radio}".band)
        # Fallback to hwmode for older OpenWrt versions
        if [ -z "$band" ]; then
            local hwmode=$(uci -q get wireless."${radio}".hwmode)
            if echo "$hwmode" | grep -q "11g"; then band="2g"; fi
            if echo "$hwmode" | grep -q "11a"; then band="5g"; fi
        fi

        if [ "$band" = "2g" ] && [ -z "$RADIO_2G" ]; then
            RADIO_2G="$radio"
            ok "Found 2.4GHz radio: ${radio}"
        elif [ "$band" = "5g" ] && [ -z "$RADIO_5G" ]; then
            RADIO_5G="$radio"
            ok "Found 5GHz radio: ${radio}"
        fi
    done

    [ -n "$RADIO_2G" ] || error "Could not find a 2.4GHz radio."
    if [ -z "$RADIO_5G" ]; then
        warn "No 5GHz radio found. Will only set up a 2.4GHz network."
    fi
}

# --- Safety Checks ---
system_checks() {
    step "Running System pre-flight checks"
    [ -f /etc/openwrt_release ] || error "Not running OpenWrt."
    ok "System is OpenWrt."

    [ "$(id -u)" -eq 0 ] || error "Run as root."
    ok "Running with root privileges."
}

check_ip_conflict() {
    step "Checking for IP address conflicts..."
    local lan_ip=$(uci -q get network.lan.ipaddr)
    local lan_netmask=$(uci -q get network.lan.netmask)
    if [ -n "$lan_ip" ] && [ -n "$lan_netmask" ]; then
        local lan_ip_int=$(ip_to_int "$lan_ip")
        local lan_mask_int=$(ip_to_int "$lan_netmask")
        local guest_ip_int=$(ip_to_int "$GUEST_IP")

        if [ $((lan_ip_int & lan_mask_int)) -eq $((guest_ip_int & lan_mask_int)) ]; then
            error "IP Conflict: LAN (${lan_ip}/${lan_netmask}) overlaps with guest network (${GUEST_IP}/${GUEST_NETMASK})."
        fi
    fi
    ok "No IP conflicts detected."
}

user_input_checks() {
    step "Validating user input"
    [ -n "$GUEST_SSID" ] || error "SSID cannot be empty."
    ok "Guest SSID is set."

    [ ${#GUEST_PASSWORD} -ge 8 ] || error "Password must be at least 8 characters."
    ok "Secure password length confirmed."

    if uci show wireless | grep -iE "ssid='(${GUEST_SSID}|${GUEST_SSID}-5G)'" >/dev/null; then
        error "SSID '${GUEST_SSID}' (or 5G variant) already exists. Choose another."
    fi
}

# --- Cleanup / Uninstall ---
remove_guest_network() {
    step "Removing all guest network configurations..."
    set +e
    uci -q delete network.${GUEST_CONFIG_NAME}
    uci -q delete dhcp.${GUEST_CONFIG_NAME}
    uci -q delete firewall.${GUEST_CONFIG_NAME}
    uci -q delete firewall.${GUEST_CONFIG_NAME}_wan
    uci -q delete firewall.${GUEST_CONFIG_NAME}_dhcp
    uci -q delete firewall.${GUEST_CONFIG_NAME}_dns
    uci -q delete firewall.${GUEST_CONFIG_NAME}_block_lan
    uci -q delete wireless.${GUEST_CONFIG_NAME}_2g
    uci -q delete wireless.${GUEST_CONFIG_NAME}_5g
    set -e
    uci commit
    ok "Configuration sections removed."
}

# --- Reload Services ---
reload_services() {
    step "Reloading services..."
    /etc/init.d/network reload || warn "Could not reload network."
    /etc/init.d/dnsmasq restart || warn "Could not restart dnsmasq."
    /etc/init.d/firewall restart || warn "Could not restart firewall."
    wifi reload || warn "Could not reload wifi."
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

    read -p "Use custom public DNS for guests (1.1.1.1, 8.8.8.8)? (Y/n): " use_custom_dns
    use_custom_dns="${use_custom_dns:-Y}"
    if echo "$use_custom_dns" | grep -qi '^[Yy]'; then
        uci set dhcp.${GUEST_CONFIG_NAME}.dhcp_option="6,1.1.1.1,8.8.8.8"
        ok "Custom public DNS will be used."
    else
        ok "Guests will use the router's default DNS."
    fi
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

# --- Setup Wi-Fi ---
setup_wifi() {
    step "Setting up 2.4GHz Guest SSID..."
    uci set wireless.${GUEST_CONFIG_NAME}_2g="wifi-iface"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.device="${RADIO_2G}"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.mode="ap"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.network="${GUEST_CONFIG_NAME}"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.ssid="${GUEST_SSID}"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.encryption="psk2+ccmp"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.key="${GUEST_PASSWORD}"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.isolate="1"

    if [ -n "$RADIO_5G" ]; then
        read -p "Do you want to create a 5GHz guest SSID as well? (Y/n): " create_5g
        create_5g="${create_5g:-Y}"
        if echo "$create_5g" | grep -qi '^[Yy]'; then
            step "Creating 5GHz Guest SSID..."
            uci set wireless.${GUEST_CONFIG_NAME}_5g="wifi-iface"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.device="${RADIO_5G}"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.mode="ap"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.network="${GUEST_CONFIG_NAME}"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.ssid="${GUEST_SSID}-5G"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.encryption="psk2+ccmp"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.key="${GUEST_PASSWORD}"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.isolate="1"
        fi
    fi
}

# --- Apply changes ---
apply_changes() {
    step "Applying changes..."
    uci commit || error "Failed to commit changes."
    reload_services
    ok "Configuration applied successfully."
}

# --- Show QR Code ---
show_qr() {
    if command -v qrencode >/dev/null; then
        echo ""
        ok "Scan this QR Code to connect to the 2.4GHz network:"
        qrencode -t ANSIUTF8 "WIFI:T:WPA;S:${GUEST_SSID};P:${GUEST_PASSWORD};;"
    else
        warn "qrencode not installed. Skipping QR code display."
        warn "Install with: opkg update && opkg install qrencode"
    fi
}

# --- Banner ---
show_banner() {
    clear
    echo "   # #############################################################################    "
    echo "   #                                  ___    __                                       "
    echo "   #                       ____  _  _<  /___/ /__                                     "
    echo "   #                      / __ \| |/_/ / __  / _ \                                    "
    echo "   #                     / /_/ />  </ / /_/ /  __/                                    "
    echo "   #                     \____/_/|_/_/\__,_/\___/                                     "
    echo "   #                                                                                  "
    echo "   #                OpenWrt Guest Wi-Fi Generator (v1.8.2)                            "
    echo "   #                                                                                  "
    echo "   # #############################################################################    "
    echo ""
}

# --- Main Execution ---
main() {
    show_banner
    if [ "$1" = "uninstall" ] || [ "$1" = "remove" ]; then
        remove_guest_network
        reload_services
        ok "Guest network successfully removed."
        exit 0
    fi

    # --- Installation ---
    system_checks
    check_ip_conflict
    detect_radios

    echo ""
    step "Please provide the details for the new guest network."
    read -p "Enter the Guest Wi-Fi Name (SSID): " GUEST_SSID
    read -sp "Enter the Guest Wi-Fi Password (min 8 chars): " GUEST_PASSWORD
    echo ""
    echo ""

    user_input_checks
    remove_guest_network # Clean up any old configs first
    setup_network
    setup_dhcp
    setup_firewall
    setup_wifi
    apply_changes

    echo ""
    ok "Guest Wi-Fi Setup Complete!"
    echo "SSID: ${GUEST_SSID}"
    if [ -n "$RADIO_5G" ] && echo "$create_5g" | grep -qi '^[Yy]'; then
        echo "SSID (5GHz): ${GUEST_SSID}-5G"
    fi
    echo "Password: (hidden for security)"
    echo "Clients on this network are isolated from your main LAN and from each other."
    show_qr
}

# --- Run Script ---
main "$@"
