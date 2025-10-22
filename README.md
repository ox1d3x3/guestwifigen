🛡️ OpenWrt Guest Wi-Fi Generator (v2.0.0)

Robust ash/BusyBox shell script to quickly set up a locked-down Guest Wi-Fi on OpenWrt. Beginner-friendly, secure by default, and compatible with 19.07 / 21.02 / 22.03 / 23.05.

✨ Features

🔐 WPA2-CCMP guest SSID (2.4 GHz + optional 5/6 GHz)

🧱 Dedicated guest firewall zone (input/forward = REJECT)

🔌 Client isolation at L2 (isolate=1) and L3 (firewall)

🧭 DNS hijack (forces all guest DNS to router; no bypass)

🏷️ RFC1918 egress blocks over WAN (10/8, 172.16/12, 192.168/16)

🚫 WPS disabled on guest SSIDs

❌ IPv6 disabled on guest interface (reduced attack surface)

♻️ Safe re-run: cleans old guest config before applying

📲 Optional QR code output if qrencode is installed

🧰 Menu: generator + full backup + restore

📦 Requirements

✅ Root shell (ssh root@routerIP)

✅ UCI (standard on OpenWrt)

✅ Tested logic for OpenWrt 19.07 / 21.02 / 22.03 / 23.05

🚀 Installation

Upload the script (example using WinSCP), then:

ssh root@routerIP
chmod +x GuestWifiGen_v2.0.0.sh
./GuestWifiGen_v2.0.0.sh


The script shows a menu after your banner.

Menu options

Run Guest Wi-Fi generator (fresh install)

Makes a pre-change backup of key configs to guestwifi-prechange-<TS>.tar.gz

Asks for SSID + password (≥8 chars)

Builds guest bridge, DHCP, firewall, SSIDs; enables radios; reloads services

Perform full system backup (migration/upgrade safe)

Uses sysupgrade -b openwrt-backup-<TS>.tar.gz

Falls back to /etc archive if needed

Restore backup

Auto-detects ./restore.tar.gz or a single restore*.tar.gz in current dir

Uses sysupgrade --restore-backup/-r when available; else safe extract

Offers to reboot (recommended)

Uninstall any time:

./GuestWifiGen_v2.0.0.sh uninstall

⚙️ What It Does

Creates network.guest (bridge), default IP 192.168.10.1/24

Configures DHCP on guest

Sets DNS: by default guests use the router; optional upstream 1.1.1.1 / 8.8.8.8 via dnsmasq

Creates a guest firewall zone with:

Allow: DHCP (67–68/udp) and DNS (53/tcp,udp) to router

Drop: guest → lan

DNS redirect (DNAT) guest:53 → router:53

Block RFC1918 subnets over WAN

Adds 2.4 GHz SSID; optionally adds 5/6 GHz -5G

Sets isolate=1 and disables WPS on guest SSIDs

Enables radios if disabled; reloads services

🔐 Security Notes

Guest devices cannot reach the main LAN

Guest devices are isolated from each other

DNS bypass is blocked (all guest DNS forced to router)

Private upstream networks are blocked (RFC1918 over WAN)

IPv6 disabled on guest; enable later if you specifically need v6

🧼 Re-run / Reconfigure

Running the script again will remove prior guest config and rebuild cleanly with your new inputs. Pre-change backups are saved automatically when you choose option 1.

🛠️ Customisation

Default Guest IP/Subnet (GUEST_IP, default 192.168.10.1/24)

Upstream DNS (choose custom when prompted)

Optional high-band SSID (-5G suffix)

QR code output if qrencode is present

🔄 Backups & Restore

Pre-change (option 1): guestwifi-prechange-<TS>.tar.gz

Full system (option 2): openwrt-backup-<TS>.tar.gz via sysupgrade -b

Restore (option 3): supply restore.tar.gz (or one restore*.tar.gz)
Reboot after restore for best results.

⚠️ Notes & Compatibility

Built for ash/BusyBox (no bashisms).

Uses UCI only; works with firewall3 (iptables) and firewall4 (nftables).

Radios are auto-detected and enabled; single-radio devices supported.

📜 License

GPL-3.0 — attribution appreciated.

Warning: Back up first. While designed to be safe and undoable (with backups/uninstall), use at your own risk.
