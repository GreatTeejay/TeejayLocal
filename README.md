

# 🚀 TEEJAY Tunnel Manager

![Bash Script](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![System](https://img.shields.io/badge/System-Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Network](https://img.shields.io/badge/Network-GRE%20Tunnel-blue?style=for-the-badge)

**TEEJAY** is the ultimate script to establish a stable **GRE Tunnel** between two servers (Iran & Abroad). It features a built-in **Heartbeat System** to prevent connection drops and supports advanced **HAProxy** forwarding.

---

## 📥 Installation Command (دستور نصب)

Copy and paste this command into your terminal on **BOTH** servers (Iran & Kharej):

```bash
bash <(curl -Ls https://raw.githubusercontent.com/GreatTeejay/TeejayLocal/refs/heads/main/teejay.sh)
```

> **Note:** Run this command as `root`. If you don't have curl, install it: `apt update && apt install curl -y`

---

## ⚡ Quick Tutorial (آموزش سریع)

### 🌍 Step 1: Kharej Server (اول سرور خارج)

1. Run the installation command.
2. Type **`2`** and press Enter (Select `KHAREJ SETUP`).
3. **GRE ID:** Enter a number (e.g., `1`).
4. **KHAREJ IP:** Enter this server's Public IP.
5. **IRAN IP:** Enter the Iran server's Public IP.
6. **GRE Range:** Enter a local IP range (e.g., `10.10.10.0`).
7. **MTU:** Press Enter for default.
8. ✅ **Done!** You will see the "Kharej Setup Complete" message.

### 🇮🇷 Step 2: Iran Server (دوم سرور ایران)

1. Run the installation command.
2. Type **`1`** and press Enter (Select `IRAN SETUP`).
3. **GRE ID:** Enter the **SAME** ID as Kharej (e.g., `1`).
4. **IRAN IP:** Enter this server's Public IP.
5. **KHAREJ IP:** Enter the Kharej server's Public IP.
6. **GRE Range:** Enter the **SAME** range (e.g., `10.10.10.0`).
7. **Forwarding Mode:**
* Select `1` for **Socat** (Simple).
* Select `2` for **HAProxy** (Recommended / Better Speed).


8. **Ports:** Enter the ports you want to tunnel (e.g., `443` or `2083` or ranges like `2050-2060`).
9. ✅ **Done!** The tunnel is now active.

---

## 🔥 Features (ویژگی‌ها)

| Feature | Description |
| --- | --- |
| **💓 Auto Keepalive** | Automatically pings the tunnel every few seconds to prevent timeouts/drops. |
| **🛡️ HAProxy Support** | Optimized TCP forwarding for better stability and performance. |
| **📶 Ping Test** | Built-in tool to check connectivity between tunnels directly from the menu. |
| **🔄 Auto-Restart** | Services automatically restart if they crash. |
| **🎨 TEEJAY UI** | A clean, neon-styled terminal interface. |

---

## ⚙️ Menu Options

* **`1 > IRAN SETUP`**: Configure the tunnel and forwarding on the local server.
* **`2 > KHAREJ SETUP`**: Configure the tunnel endpoint on the remote server.
* **`3 > Connectivity Check`**: Ping the other side of the tunnel to check health.
* **`4 > Uninstall & Clean`**: Remove all services and configs created by TEEJAY.
* **`5 > ADD TUNNEL PORT`**: Add new ports to an existing tunnel without reinstalling.

---

## ❓ Troubleshooting

**Q: The ping stops after a few hours?**

> **A:** TEEJAY installs a `keepalive` service automatically to fix this. If it stops, check if the server rebooted or run option `3` to wake it up.

**Q: "Syntax error near unexpected token" when installing?**

> **A:** Do not copy the brackets `[]` or `()` from the URL. Just copy the code block inside the "Installation Command" section above.

**Q: Which ports should I forward?**

> **A:** Forward the ports that your VPN config uses (e.g., if your V2Ray config is on port 2083, forward 2083).

---

<p align="center">
Made with ❤️ by <b>TEEJAY</b>
</p>

```

```
