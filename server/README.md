# DataDonor Backend Server

This is the official local-first backend for the DataDonor iOS application. It is a high-performance Node.js Express server utilizing SQLite for lightning-fast, zero-config data ingestion, and PM2 for robust background monitoring.

## ⚠️ Critical Security Warning ⚠️
**DO NOT PORT-FORWARD THIS SERVER TO THE INTERNET.**
DataDonor is designed strictly as a local-network (LAN) appliance. It contains your highly sensitive biometric, cardiovascular, and location data. Exposing this server to the open internet (e.g., via router port-forwarding or reverse proxies like ngrok) puts your personal health data at extreme risk of interception or theft. 

**Always run this server on a local machine (like a Raspberry Pi or home NAS) behind a secure firewall, and only allow the iOS app to sync when connected to your private home Wi-Fi.**

---

## 1. Prerequisites
- [Node.js](https://nodejs.org/) (v16+)
- [PM2](https://pm2.keymetrics.io/) (Installed globally via `npm install -g pm2`)
- OpenSSL (Usually pre-installed on Linux/macOS)

## 2. Generating SSL Certificates
The iOS application communicates securely over HTTPS. Because this is a strictly local server, you must generate a self-signed certificate. The iOS app is specifically built to securely trust the certificate presented by the auto-discovered local mDNS host.

Run this command inside the `server/certs/` directory to generate a certificate valid for 10 years:
```bash
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -keyout certs/key.pem -out certs/cert.pem -days 3650 -nodes -subj "/CN=datadonor.local"
```

## 3. Configuration
On the very first run, the server will auto-generate a `config.json` file in the root directory and exit.
1. Run `node app.js` to generate the file.
2. Open `config.json` and change the `api_key` under `security` to a strong, random password.
3. Enter this exact API key into the Settings tab of the DataDonor iOS app.

## 4. Running the Server (PM2)
To run the server in the background and ensure it automatically restarts on crash or system reboot, use PM2:

**Start the server:**
```bash
pm2 start ecosystem.config.js
```

**View live logs:**
```bash
pm2 logs datadonor-server
```

**Save PM2 state so it boots on system startup:**
```bash
pm2 save
pm2 startup
```

## 5. Log Retention
Logs are managed by Winston and automatically rotate daily. By default, logs are retained for 7 days in the `/logs` directory. You can change this behavior in the `config.json`.
