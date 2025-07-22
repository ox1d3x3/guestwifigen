
# 🛡️ OpenWrt Guest Wi-Fi Generator

An interactive shell script to quickly and safely set up an **isolated Guest Wi-Fi** network on OpenWrt. Designed to be beginner-friendly, secure by default, and compatible with most OpenWrt routers.

---

## ✨ Features

- 🔐 Secure WPA2 encryption (2.4GHz & optional 5GHz)
- 🔁 DHCP + DNS + Firewall zone isolation
- 🔍 Safety checks before applying changes
- 🚫 Prevents Guest devices from accessing main LAN
- ✅ Re-runnable: cleans old config before applying
- 🧹 Lightweight and dependency-free

---

## 📦 Requirements

- ✅ OpenWrt system
- ✅ Root access (`ssh root@your.router`)
- ✅ UCI (default on OpenWrt)

---

## 🚀 Installation

1. Upload the script to your OpenWrt router:

```scp GuestWifiGen.sh root@192.168.1.1:/root/``` (Easy way using WinSCP)
   
SSH into the router:

```ssh root@192.168.1.1```

Make the script executable:

```chmod +x GuestWifiGen.sh```

Run it:

```./GuestWifiGen.sh```

***Restart the router***


## ⚙️ What It Does

The script performs:

✅ Creates a new interface guest

✅ Assigns static IP (default: 192.168.10.1)

✅ Configures DHCP server

✅ Sets DNS servers (Cloudflare, Quad9, Google)

✅ Creates isolated firewall zone and rules

✅ Adds 2.4GHz SSID (radio0)

✅ Optionally adds 5GHz SSID (radio1)

✅ Ensures client isolation


## 🔐 Security Notes
Guest clients cannot access your main LAN

All guest clients are isolated from each other

Password must be at least 8 characters

Uses WPA2 + CCMP for encryption


## 🧼 To Re-run or Reconfigure
You can re-run the script anytime — it will:

Clean up previous guest interface, firewall rules, and SSIDs

Recreate them cleanly with your new inputs


## 🛠️ Customisation
You can tweak:

Default Guest IP/Subnet (GUEST_IP)

DNS servers

SSID naming pattern

Add VLAN tagging, MAC filtering, or bandwidth limits (future roadmap)

__________

📜 License
GPL-3.0 license — do whatever you like, but attribution is appreciated.
____________

