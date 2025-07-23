#!/bin/sh

echo "   # #############################################################################    "
echo "   #                                  ___    __                                       "
echo "   #                       ____  _  _<  /___/ /__                                     "
echo "   #                      / __ \| |/_/ / __  / _ \                                    "
echo "   #                     / /_/ />  </ / /_/ /  __/                                    "
echo "   #                     \____/_/|_/_/\__,_/\___/                                     "
echo "   #                                                                                  "
echo "   #              OpenWrt Guest Wi-Fi Configurator (v1.6.6 QRcode Edition)            "
echo "   #                                                                                  "
echo "   # #############################################################################    "
echo "                                                                                      "

# --- Static Configuration ---
GUEST_IP="192.168.10.1"
GUEST_NETMASK="255.255.255.0"

# --- User Input ---
echo ""
echo "Please provide the details for the new guest network."
read -p "Enter the Guest Wi-Fi Name (SSID): " GUEST_SSID
read -sp "Enter the Guest Wi-Fi Password (at least 8 characters): " GUEST_PASSWORD
echo ""
echo ""

# --- Safety Checks ---
set -e
echo "\n┌───────────────────────────────────┐"
echo "│  Running Pre-flight Safety Checks │"
echo "└───────────────────────────────────┘"

[ -f /etc/openwrt_release ] || { echo "❌ ERROR: Not OpenWrt."; exit 1; }
echo "✅ System is OpenWrt."

[ "$(id -u)" -eq 0 ] || { echo "❌ ERROR: Run as root."; exit 1; }
echo "✅ Running with root privileges."

[ -n "$GUEST_SSID" ] || { echo "❌ ERROR: SSID cannot be empty."; exit 1; }
echo "✅ Guest SSID is set."

[ ${#GUEST_PASSWORD} -ge 8 ] || { echo "❌ ERROR: Password too short."; exit 1; }
echo "✅ Secure password length confirmed."

uci -q get wireless.radio0 >/dev/null || { echo "❌ ERROR: No 2.4GHz radio."; exit 1; }
echo "✅ 2.4GHz radio (radio0) found."

if uci -q get wireless.radio1 >/dev/null; then
    echo "✅ 5GHz radio (radio1) found."
    HAS_5G="yes"
else
    echo "⚠️ WARNING: 5GHz radio not found. Will skip 5GHz setup."
    HAS_5G="no"
fi

echo "\n--- All safety checks passed. Proceeding with configuration. ---\n"

# --- Cleanup ---
echo "🧹 Cleaning up previous guest config..."
set +e
uci -q delete network.guest
uci -q delete dhcp.guest
uci -q delete firewall.guest
uci -q delete firewall.guest_wan
uci -q delete firewall.guest_dhcp
uci -q delete firewall.guest_dns
uci -q delete wireless.guest_2g
uci -q delete wireless.guest_5g
set -e
uci commit
echo "✅ Cleanup complete."

# --- Configure Network ---
echo "1. Creating guest network..."
uci set network.guest='interface'
uci set network.guest.proto='static'
uci set network.guest.ipaddr="$GUEST_IP"
uci set network.guest.netmask="$GUEST_NETMASK"
uci set network.guest.ip6assign='60'

# --- Configure DHCP ---
echo "2. Configuring DHCP..."
uci set dhcp.guest='dhcp'
uci set dhcp.guest.interface='guest'
uci set dhcp.guest.start='100'
uci set dhcp.guest.limit='150'
uci set dhcp.guest.leasetime='12h'
uci set dhcp.guest.dhcp_option='6,1.1.1.1,9.9.9.9,8.8.8.8'

# --- Configure Firewall ---
echo "3. Setting up firewall..."
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

# --- Configure Wi-Fi ---
echo "4. Creating 2.4GHz SSID..."
uci set wireless.guest_2g='wifi-iface'
uci set wireless.guest_2g.device='radio0'
uci set wireless.guest_2g.mode='ap'
uci set wireless.guest_2g.network='guest'
uci set wireless.guest_2g.ssid="$GUEST_SSID"
uci set wireless.guest_2g.encryption='psk2+ccmp'
uci set wireless.guest_2g.key="$GUEST_PASSWORD"
uci set wireless.guest_2g.isolate='1'

if [ "$HAS_5G" = "yes" ]; then
    read -p "Do you want to create a 5GHz guest SSID as well? (Y/n): " create_5g
    create_5g="${create_5g:-Y}"
    if echo "$create_5g" | grep -qi '^[Yy]'; then
        echo "   Creating 5GHz SSID..."
        uci set wireless.guest_5g='wifi-iface'
        uci set wireless.guest_5g.device='radio1'
        uci set wireless.guest_5g.mode='ap'
        uci set wireless.guest_5g.network='guest'
        uci set wireless.guest_5g.ssid="${GUEST_SSID}-5G"
        uci set wireless.guest_5g.encryption='psk2+ccmp'
        uci set wireless.guest_5g.key="$GUEST_PASSWORD"
        uci set wireless.guest_5g.isolate='1'
    fi
fi

# --- Apply and Restart ---
echo "5. Applying configuration..."
uci commit
/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
wifi reload

# --- QR Code ---
echo "\n6. Generating QR code for quick mobile access..."
WIFI_QR="WIFI:S:${GUEST_SSID};T:WPA;P:${GUEST_PASSWORD};;"
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t PNG -o /www/guest_wifi.png "$WIFI_QR"
    echo "✅ PNG QR available at: http://<router-ip>/guest_wifi.png"
    qrencode -t ANSIUTF8 "$WIFI_QR"
else
    echo "⚠️ qrencode not installed. Install with: opkg update && opkg install qrencode"
fi

# --- Done ---
echo "\n┌───────────────────────────────────┐"
echo "│    ✅ Guest Wi-Fi Setup Complete!   │"
echo "└───────────────────────────────────┘"
echo "SSID:         ${GUEST_SSID}"
[ "$HAS_5G" = "yes" ] && echo "$create_5g" | grep -qi '^[Yy]' && echo "SSID (5GHz):  ${GUEST_SSID}-5G"
echo "Password:     (Hidden)"
echo "Clients on this network are isolated from your main LAN."
echo "Configuration has been applied successfully."
echo ""
