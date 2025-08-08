#!/bin/sh
# =============================================================================
# OpenWrt Guest Wi-Fi Configurator (v1.7.5)
# =============================================================================
# Author: Mahabub X (Enhanced by GPT-5)
# Description: Creates an isolated guest Wi-Fi network with optional 5GHz and
#              QR code display for quick mobile connection.
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

# --- Banner ---
clear
echo "#############################################################################"
echo "    ___    __                                                                "
echo "  ____  _  _<  /___/ /__                                                      "
echo " / __ \| |/_/ / __  / _ \                                                     "
echo "/ /_/ />  </ / /_/ /  __/                                                     "
echo "\____/_/|_/_/\__,_/\___/                                                      "
echo "                                                                               "
echo "          OpenWrt Guest Wi-Fi Configurator (v1.7.5)                           "
echo "#############################################################################"
echo ""

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

    uci -q get wireless.radio0 >/dev/null || error "No 2.4GHz radio found."
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

# --- Cleanup old configs ---
cleanup_old() {
    step "Cleaning up old guest network configurations..."
    set +e
    uci -q delete network.guest
    uci -q delete dhcp.guest
    uci -q delete firewall.guest
    uci -q delete firewall.guest_wan
    uci -q delete firewall.guest_dhcp
    uci -q delete firewall.guest_dns
    uci -q delete firewall.guest_block_lan
    uci -q delete wireless.guest_2g
    uci -q delete wireless.guest_5g
    set -e
    uci commit
    ok "Cleanup complete."
}

# --- Setup network ---
setup_network() {
    step "Creating guest network interface..."
    uci set network.guest='interface'
    uci set network.guest.proto='static'
    uci set network.guest.ipaddr="${GUEST_IP}"
    uci set network.guest.netmask="${GUEST_NETMASK}"
    uci set network.guest.ip6assign='60'
}

# --- Setup DHCP ---
setup_dhcp() {
    step "Setting up DHCP for guest network..."
    uci set dhcp.guest='dhcp'
    uci set dhcp.guest.interface='guest'
    uci set dhcp.guest.start='100'
    uci set dhcp.guest.limit='150'
    uci set dhcp.guest.leasetime='12h'
    uci set dhcp.guest.dhcp_option='6,1.1.1.1,9.9.9.9,8.8.8.8'
}

# --- Setup firewall ---
setup_firewall() {
    step "Configuring firewall rules..."
    uci set firewall.guest='zone'
    uci set firewall.guest.name='guest'
    uci set firewall.guest.input='REJECT'
    uci set firewall.guest.output='ACCEPT'
    uci set firewall.guest.forward='REJECT'
    uci add_list firewall.guest.network='guest'

    uci set firewall.guest_wan='forwarding'
    uci set firewall.guest_wan.src='guest'
    uci set firewall.guest_wan.dest='wan'

    uci set firewall.guest_dhcp='rule'
    uci set firewall.guest_dhcp.name='Allow Guest DHCP'
    uci set firewall.guest_dhcp.src='guest'
    uci set firewall.guest_dhcp.proto='udp'
    uci set firewall.guest_dhcp.dest_port='67-68'
    uci set firewall.guest_dhcp.target='ACCEPT'

    uci set firewall.guest_dns='rule'
    uci set firewall.guest_dns.name='Allow Guest DNS'
    uci set firewall.guest_dns.src='guest'
    uci set firewall.guest_dns.proto='tcp udp'
    uci set firewall.guest_dns.dest_port='53'
    uci set firewall.guest_dns.target='ACCEPT'

    uci set firewall.guest_block_lan='rule'
    uci set firewall.guest_block_lan.name='Block Guest to LAN'
    uci set firewall.guest_block_lan.src='guest'
    uci set firewall.guest_block_lan.dest='lan'
    uci set firewall.guest_block_lan.target='DROP'
}

# --- Setup Wi-Fi ---
setup_wifi() {
    step "Setting up 2.4GHz Guest SSID..."
    uci set wireless.guest_2g='wifi-iface'
    uci set wireless.guest_2g.device='radio0'
    uci set wireless.guest_2g.mode='ap'
    uci set wireless.guest_2g.network='guest'
    uci set wireless.guest_2g.ssid="${GUEST_SSID}"
    uci set wireless.guest_2g.encryption='psk2+ccmp'
    uci set wireless.guest_2g.key="${GUEST_PASSWORD}"
    uci set wireless.guest_2g.isolate='1'

    if [ "$HAS_5G" = "yes" ]; then
        read -p "Do you want to create a 5GHz guest SSID as well? (Y/n): " create_5g
        create_5g="${create_5g:-Y}"
        if echo "$create_5g" | grep -qi '^[Yy]'; then
            step "Creating 5GHz Guest SSID..."
            uci set wireless.guest_5g='wifi-iface'
            uci set wireless.guest_5g.device='radio1'
            uci set wireless.guest_5g.mode='ap'
            uci set wireless.guest_5g.network='guest'
            uci set wireless.guest_5g.ssid="${GUEST_SSID}-5G"
            uci set wireless.guest_5g.encryption='psk2+ccmp'
            uci set wireless.guest_5g.key="${GUEST_PASSWORD}"
            uci set wireless.guest_5g.isolate='1'
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
        ok "Scan this QR Code to connect:"
        qrencode -t ANSIUTF8 "WIFI:T:WPA;S:${GUEST_SSID};P:${GUEST_PASSWORD};;"
    else
        warn "qrencode not installed. Skipping QR code."
    fi
}

# --- Main Execution ---
echo ""
echo "Please provide the details for the new guest network."
read -p "Enter the Guest Wi-Fi Name (SSID): " GUEST_SSID
read -sp "Enter the Guest Wi-Fi Password (min 8 chars): " GUEST_PASSWORD
echo ""

preflight_checks
cleanup_old
setup_network
setup_dhcp
setup_firewall
setup_wifi
apply_changes

echo ""
ok "Guest Wi-Fi Setup Complete!"
echo "SSID: ${GUEST_SSID}"
[ "$HAS_5G" = "yes" ] && [ "$create_5g" != "n" ] && echo "SSID (5GHz): ${GUEST_SSID}-5G"
echo "Password: (hidden)"
echo "Clients on this network are isolated from your main LAN and from each other."
show_qr
