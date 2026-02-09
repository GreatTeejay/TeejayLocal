# 🚀 TEEJAY Tunnel Manager

![Bash Script](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![System](https://img.shields.io/badge/System-Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg?style=for-the-badge)

**TEEJAY** is an advanced, menu-based Bash script designed to establish stable **GRE Tunnels** between servers (e.g., Iran & Abroad). It features built-in **Keepalive (Heartbeat)** mechanism to prevent connection timeouts and supports both **Socat** and **HAProxy** for port forwarding.

---

## ✨ Features (ویژگی‌ها)

- 🛡️ **Stable GRE Tunneling:** Easy setup for Layer 3 tunneling.
- 💓 **Auto Keepalive:** Built-in heartbeat service to prevent NAT timeouts and connection drops.
- ⚡ **Dual Mode Forwarding:**
  - **Socat:** Simple and lightweight.
  - **HAProxy:** Advanced TCP optimization and high performance.
- 🖥️ **Interactive Menu:** User-friendly UI/UX with neon styling.
- 🔍 **Diagnostic Tools:** Integrated Ping test to check tunnel health.
- 🔄 **Auto-Repair:** Services automatically restart on failure.

---

## 📥 Installation (نصب و اجرا)

To install and run TEEJAY, simply copy and paste the following command into your terminal:

```bash
bash <(curl -Ls [https://raw.githubusercontent.com/GreatTeejay/TeejayLocal/refs/heads/main/teejay.sh](https://raw.githubusercontent.com/GreatTeejay/TeejayLocal/refs/heads/main/teejay.sh))
