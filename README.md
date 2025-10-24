# 🛡️ OpenWrt Guest Wi-Fi Generator

Robust ash/BusyBox shell script to quickly set up a **locked-down Guest Wi-Fi** on OpenWrt. Beginner-friendly, secure by default, and compatible with **19.07 / 21.02 / 22.03 / 23.05 / 24.xx**.

---

## ✨ Features

- 🔐 **WPA2-CCMP** guest SSID (2.4 GHz + optional 5/6 GHz)
- 🧱 Dedicated **guest firewall zone** (`input=REJECT`, `forward=REJECT`)
- 🔌 **Client isolation** at L2 (`isolate=1`) and L3 (firewall)
- 🧭 **DNS hijack** (forces all guest DNS to router; no bypass)
- 🏷️ **RFC1918 egress blocks** over WAN (`10/8`, `172.16/12`, `192.168/16`)
- 🚫 **WPS disabled** on guest SSIDs
- ❌ **IPv6 disabled** on guest interface (reduced attack surface)
- ♻️ Safe re-run: cleans old guest config before applying
- 📲 Optional **QR code** output if `qrencode` is installed
- 🧰 **Menu**: generator + full backup + restore

---

## 📦 Requirements

- ✅ Root shell (`ssh root@routerIP`)
- ✅ UCI (standard on OpenWrt)
- ✅ OpenWrt **19.07 / 21.02 / 22.03 / 23.05 /24.10**
- ✅ For QRcode Display - package require - qrencode: `opkg update && opkg install qrencode`

---

## 🚀 Installation

Upload the script (WinSCP is fine), then:

```sh
ssh root@routerIP
chmod +x GuestWifiGen_vX.sh
./GuestWifiGen_vX.sh
```

The script shows a menu.

### **Menu options**

1. **Run Guest Wi-Fi generator (fresh install)**
   - Makes a pre-change backup to `guestwifi-prechange-<TS>.tar.gz`
   - Prompts for SSID + password (≥ 8 chars)
   - Builds guest bridge, DHCP, firewall, SSIDs; enables radios; reloads services

2. **Perform full system backup (migration/upgrade safe)**
   - Uses `sysupgrade -b openwrt-backup-<TS>.tar.gz`
   - Falls back to `/etc` archive if needed

3. **Restore backup**
   - Auto-detects `./restore.tar.gz` or a single `restore*.tar.gz` in current dir
   - Uses `sysupgrade --restore-backup` / `-r` when available; else safe extract
   - Offers to reboot (recommended)

**Uninstall any time:**
```sh
./GuestWifiGen_vX.sh uninstall
```

---

## ⚙️ What It Does

- Creates `network.guest` **bridge** with default IP **192.168.10.1/24**
- Configures **DHCP** on `guest`
- **DNS**: guests use the router; optional upstream **1.1.1.1 / 8.8.8.8** via dnsmasq
- Creates a **guest firewall zone**:
  - **Allow**: DHCP (67–68/udp) and DNS (53/tcp,udp) to router
  - **Drop**: guest → lan
  - **DNS redirect** (DNAT) guest:53 → router:53 (prevents DNS bypass)
  - **Block RFC1918** subnets over WAN
- Adds **2.4 GHz** SSID; optionally adds **5/6 GHz** `-5G`
- Sets `isolate=1` and **disables WPS**
- Enables radios if disabled; reloads services

---

## Screenshots
<img width="869" height="509" alt="image" src="https://github.com/user-attachments/assets/bdd7bee9-a7d8-44a2-8911-d62b97119cb6" />
<img width="955" height="583" alt="image" src="https://github.com/user-attachments/assets/4927cf77-7220-4b11-a688-0eaa45b6a5fa" />




## 🔐 Security Notes

- Guest devices **cannot reach** the main LAN  
- Guest devices are **isolated from each other**  
- **DNS bypass is blocked** (all guest DNS forced to router)  
- Private upstream networks are blocked (**RFC1918 over WAN**)  
- **IPv6 disabled** on guest; enable later only if required

---

## 🧼 Re-run / Reconfigure

Re-running removes prior guest config and rebuilds cleanly with your new inputs.  
Pre-change backups are saved automatically when you choose **menu option 1**.

---

## 🛠️ Customisation

- Default Guest IP/Subnet (`GUEST_IP`, default **192.168.10.1/24**)
- Upstream DNS (choose custom when prompted)
- Optional high-band SSID (`-5G` suffix)
- QR code output if `qrencode` is present

---

## 🔄 Backups & Restore

- **Pre-change (option 1):** `guestwifi-prechange-<TS>.tar.gz`  
- **Full system (option 2):** `openwrt-backup-<TS>.tar.gz` via `sysupgrade -b`  
- **Restore (option 3):** use `restore.tar.gz` (or one `restore*.tar.gz`)  
  Reboot after restore for best results.

---

## ⚠️ Notes & Compatibility

- Built for **ash/BusyBox** (no bashisms)  
- UCI-only; works with **firewall3 (iptables)** and **firewall4 (nftables)**  
- Radios are auto-detected and enabled; **single-radio devices supported**

---

## 📜 License

GPL-3.0 — attribution appreciated.

> **Warning:** Back up first. While designed to be safe and undoable (with backups/uninstall), use at your own risk.
