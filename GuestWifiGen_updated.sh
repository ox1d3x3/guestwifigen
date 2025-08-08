#!/bin/sh
# =============================================================================
# OpenWrt Guest Wi-Fi Configurator (v1.8.0)
# =============================================================================
# Author: X1 
# Description: Creates or removes an isolated guest Wi-Fi network.
#              Features optional 5GHz, QR code display, and custom DNS.
#
# Usage:
#   - To create a guest network: ./GuestWifiGen_v1.8.0.sh
#   - To remove the guest network: ./GuestWifiGen_v1.8.0.sh uninstall
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

# --- Helper functions ---
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }
step()  { echo -e "${CYAN}▶ $1${NC}"; }

# --- Safety Checks ---
preflight_checks() {
    step "Running Pre-flight Safety Checks"
    [ -f /etc/openwrt_release ] || error "Not running OpenWrt."
    ok "System is OpenWrt."

    [ "$(id -u)" -eq 0 ] || error "Run as root."
    ok "Running with root privileges."

    [ -n "$GUEST_SSID" ] || error "SSID cannot be empty."
    ok "Guest SSID is set."

    [ ${#GUEST_PASSWORD} -ge 8 ] || error "Password must be at least 8 characters."
    ok "Secure password length confirmed."

    # Assumption: radio0 is 2.4GHz and radio1 is 5GHz. This is common but not guaranteed.
    uci -q get wireless.radio0 >/dev/null || error "No 2.4GHz radio (radio0) found."
    ok "2.4GHz radio found."

    if uci -q get wireless.radio1 >/dev/null; then
        ok "5GHz radio found."
        HAS_5G="yes"
    else
        warn "5GHz radio not found. Skipping 5GHz setup."
        HAS_5G="no"
    fi

    if uci show wireless | grep -q "ssid='${GUEST_SSID}'"; then
        error "SSID '${GUEST_SSID}' already exists. Choose another."
    fi
}

# --- Cleanup / Uninstall ---
remove_guest_network() {
    step "Removing all guest network configurations..."
    set +e # Continue even if a section doesn't exist
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
    step "Reloading services to apply removal..."
    /etc/init.d/network reload || warn "Could not reload network."
    /etc/init.d/dnsmasq restart || warn "Could not restart dnsmasq."
    /etc/init.d/firewall restart || warn "Could not restart firewall."
    wifi reload || warn "Could not reload wifi."
    ok "Guest network successfully removed."
}

# --- Setup network ---
setup_network() {
    step "Creating guest network interface..."
    uci set network.${GUEST_CONFIG_NAME}='interface'
    uci set network.${GUEST_CONFIG_NAME}.proto='static'
    uci set network.${GUEST_CONFIG_NAME}.ipaddr="${GUEST_IP}"
    uci set network.${GUEST_CONFIG_NAME}.netmask="${GUEST_NETMASK}"
    uci set network.${GUEST_CONFIG_NAME}.ip6assign='60'
}

# --- Setup DHCP ---
setup_dhcp() {
    step "Setting up DHCP for guest network..."
    uci set dhcp.${GUEST_CONFIG_NAME}='dhcp'
    uci set dhcp.${GUEST_CONFIG_NAME}.interface='${GUEST_CONFIG_NAME}'
    uci set dhcp.${GUEST_CONFIG_NAME}.start='100'
    uci set dhcp.${GUEST_CONFIG_NAME}.limit='150'
    uci set dhcp.${GUEST_CONFIG_NAME}.leasetime='12h'

    read -p "Use custom public DNS for guests (1.1.1.1, 8.8.8.8)? (Y/n): " use_custom_dns
    use_custom_dns="${use_custom_dns:-Y}"
    if echo "$use_custom_dns" | grep -qi '^[Yy]'; then
        # This pushes public DNS servers to guests, bypassing local resolvers.
        uci set dhcp.${GUEST_CONFIG_NAME}.dhcp_option='6,1.1.1.1,8.8.8.8'
        ok "Custom public DNS will be used."
    else
        ok "Guests will use the router's default DNS."
    fi
}

# --- Setup firewall ---
setup_firewall() {
    step "Configuring firewall rules..."
    uci set firewall.${GUEST_CONFIG_NAME}='zone'
    uci set firewall.${GUEST_CONFIG_NAME}.name='${GUEST_CONFIG_NAME}'
    uci set firewall.${GUEST_CONFIG_NAME}.input='REJECT'
    uci set firewall.${GUEST_CONFIG_NAME}.output='ACCEPT'
    uci set firewall.${GUEST_CONFIG_NAME}.forward='REJECT'
    uci add_list firewall.${GUEST_CONFIG_NAME}.network='${GUEST_CONFIG_NAME}'

    uci set firewall.${GUEST_CONFIG_NAME}_wan='forwarding'
    uci set firewall.${GUEST_CONFIG_NAME}_wan.src='${GUEST_CONFIG_NAME}'
    uci set firewall.${GUEST_CONFIG_NAME}_wan.dest='wan'

    uci set firewall.${GUEST_CONFIG_NAME}_dhcp='rule'
    uci set firewall.${GUEST_CONFIG_NAME}_dhcp.name='Allow Guest DHCP'
    uci set firewall.${GUEST_CONFIG_NAME}_dhcp.src='${GUEST_CONFIG_NAME}'
    uci set firewall.${GUEST_CONFIG_NAME}_dhcp.proto='udp'
    uci set firewall.${GUEST_CONFIG_NAME}_dhcp.dest_port='67-68'
    uci set firewall.${GUEST_CONFIG_NAME}_dhcp.target='ACCEPT'

    uci set firewall.${GUEST_CONFIG_NAME}_dns='rule'
    uci set firewall.${GUEST_CONFIG_NAME}_dns.name='Allow Guest DNS'
    uci set firewall.${GUEST_CONFIG_NAME}_dns.src='${GUEST_CONFIG_NAME}'
    uci set firewall.${GUEST_CONFIG_NAME}_dns.proto='tcp udp'
    uci set firewall.${GUEST_CONFIG_NAME}_dns.dest_port='53'
    uci set firewall.${GUEST_CONFIG_NAME}_dns.target='ACCEPT'

    uci set firewall.${GUEST_CONFIG_NAME}_block_lan='rule'
    uci set firewall.${GUEST_CONFIG_NAME}_block_lan.name='Block Guest to LAN'
    uci set firewall.${GUEST_CONFIG_NAME}_block_lan.src='${GUEST_CONFIG_NAME}'
    uci set firewall.${GUEST_CONFIG_NAME}_block_lan.dest='lan'
    uci set firewall.${GUEST_CONFIG_NAME}_block_lan.target='DROP'
}

# --- Setup Wi-Fi ---
setup_wifi() {
    step "Setting up 2.4GHz Guest SSID..."
    uci set wireless.${GUEST_CONFIG_NAME}_2g='wifi-iface'
    uci set wireless.${GUEST_CONFIG_NAME}_2g.device='radio0'
    uci set wireless.${GUEST_CONFIG_NAME}_2g.mode='ap'
    uci set wireless.${GUEST_CONFIG_NAME}_2g.network='${GUEST_CONFIG_NAME}'
    uci set wireless.${GUEST_CONFIG_NAME}_2g.ssid="${GUEST_SSID}"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.encryption='psk2+ccmp'
    uci set wireless.${GUEST_CONFIG_NAME}_2g.key="${GUEST_PASSWORD}"
    uci set wireless.${GUEST_CONFIG_NAME}_2g.isolate='1'

    if [ "$HAS_5G" = "yes" ]; then
        read -p "Do you want to create a 5GHz guest SSID as well? (Y/n): " create_5g
        create_5g="${create_5g:-Y}"
        if echo "$create_5g" | grep -qi '^[Yy]'; then
            step "Creating 5GHz Guest SSID..."
            uci set wireless.${GUEST_CONFIG_NAME}_5g='wifi-iface'
            uci set wireless.${GUEST_CONFIG_NAME}_5g.device='radio1'
            uci set wireless.${GUEST_CONFIG_NAME}_5g.mode='ap'
            uci set wireless.${GUEST_CONFIG_NAME}_5g.network='${GUEST_CONFIG_NAME}'
            uci set wireless.${GUEST_CONFIG_NAME}_5g.ssid="${GUEST_SSID}-5G"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.encryption='psk2+ccmp'
            uci set wireless.${GUEST_CONFIG_NAME}_5g.key="${GUEST_PASSWORD}"
            uci set wireless.${GUEST_CONFIG_NAME}_5g.isolate='1'
        fi
    fi
}

# --- Apply changes ---
apply_changes() {
    step "Applying changes..."
    uci commit || error "Failed to commit changes."
    /etc/init.d/network reload || error "Network reload failed."
    /etc/init.d/dnsmasq restart || error "DNSMasq restart failed."
    /etc/init.d/firewall restart || error "Firewall restart failed."
    wifi reload || error "Wi-Fi reload failed."
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
    echo "   #              OpenWrt Guest Wi-Fi Configurator (v1.8.0)                           "
    echo "   #                                                                                  "
    echo "   # #############################################################################    "
    echo ""
    echo ""
}

# --- Main Execution ---
main() {
    show_banner
    if [ "$1" = "uninstall" ] || [ "$1" = "remove" ]; then
        remove_guest_network
        exit 0
    fi

    # Run installation
    remove_guest_network # Clean up old configs first to ensure a clean slate
    echo "Please provide the details for the new guest network."
    read -p "Enter the Guest Wi-Fi Name (SSID): " GUEST_SSID
    read -sp "Enter the Guest Wi-Fi Password (min 8 chars): " GUEST_PASSWORD
    echo ""

    preflight_checks
    setup_network
    setup_dhcp
    setup_firewall
    setup_wifi
    apply_changes

    echo ""
    ok "Guest Wi-Fi Setup Complete!"
    echo "SSID: ${GUEST_SSID}"
    if [ "$HAS_5G" = "yes" ] && echo "$create_5g" | grep -qi '^[Yy]'; then
        echo "SSID (5GHz): ${GUEST_SSID}-5G"
    fi
    echo "Password: (hidden for security)"
    echo "Clients on this network are isolated from your main LAN and from each other."
    show_qr
}

# --- Run Script ---
main "$@"

```

