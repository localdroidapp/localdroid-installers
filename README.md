# LocalDroid MDM — Installers

**LocalDroid MDM** is a self-hosted Mobile Device Management system for Android
(and Windows) devices. It runs on your own hardware — air-gapped local networks
or internet-connected — and it's **free**.

This repo hosts the ready-to-run **installers and agents**. There's no source
code here; the downloads are prebuilt so you don't need Go, Node, or a build
toolchain on the server.

> ⬇️ **Get the latest downloads on the [Releases page](../../releases/latest).**

## Which download do I need?

| Your server | Download | Internet during install? |
|---|---|---|
| **Linux (x86-64)** | `localdroid-native-linux-amd64-*.tar.gz` | Yes (installs deps via apt) |
| **Raspberry Pi (64-bit)** | `localdroid-native-linux-arm64-*.tar.gz` | Yes (installs deps via apt) |
| **Windows Server** — air-gapped | `localdroid-airgap-windows-*.zip` | No — fully offline |
| **Windows Server** — internet-connected (cloud) | `localdroid-airgap-windows-*.zip` + `install-windows-cloud.ps1` | Yes |
| **Linux / Pi** — fully air-gapped | *(coming soon: bundles all OS packages)* | No |

Device agents (also bundled inside each installer, and here as standalone
downloads):

| File | For |
|---|---|
| `localdroid-agent.apk` | Android devices |
| `localdroid-agent.exe` | Windows devices |

## Install

### Linux / Raspberry Pi

```bash
tar -xzf localdroid-native-linux-*.tar.gz
cd localdroid-native-*/
sudo ./install.sh
```

The installer asks whether this is an **air-gapped / local network** or an
**internet-connected** deployment and configures everything (PostgreSQL,
Mosquitto, the server, and — for internet mode — nginx + TLS) accordingly.

### Windows Server (air-gapped / local network)

1. Extract `localdroid-airgap-windows-*.zip` to a persistent folder (e.g. `C:\LocalDroid`).
2. Right-click **`install-windows-offline.ps1`** → **Run with PowerShell** (as Administrator).

Everything it needs (PostgreSQL, Mosquitto, the server, the web UI, the agents)
is inside the zip — no internet required.

### Windows Server (internet-connected / cloud)

Use this when devices connect over the internet rather than sitting on the same
LAN — a public domain name, HTTPS, and MQTT over TLS.

1. Extract `localdroid-airgap-windows-*.zip` to a persistent folder (e.g. `C:\LocalDroid`).
   It carries the prebuilt server, web UI, migrations and agents that the cloud
   installer needs.
2. Open PowerShell **as Administrator**, then drop
   [`install-windows-cloud.ps1`](install-windows-cloud.ps1) into that same folder,
   next to `install-windows-offline.ps1`:

   ```powershell
   cd C:\LocalDroid
   Invoke-WebRequest -UseBasicParsing `
     -Uri https://raw.githubusercontent.com/localdroidapp/localdroid-installers/main/install-windows-cloud.ps1 `
     -OutFile install-windows-cloud.ps1
   ```

3. Run it:

   ```powershell
   .\install-windows-cloud.ps1
   ```

**Do not** use `install-windows-offline.ps1` for a cloud deployment. Its
"Internet Connected" menu option only tags the config as cloud — it still asks
for a LAN IP, writes a plain-`http://` external URL, and sets up an anonymous
MQTT broker. `install-windows-cloud.ps1` is the one that asks for your public
domain and configures a real internet-facing server.

Before you start, have these ready:

- A **public domain name** for the server (e.g. `mdm.yourcompany.com`).
- A **public DNS A-record** for it pointing at the server's public IP.
  Split-horizon / LAN-only DNS is not enough — Let's Encrypt validates from
  the internet.
- **Port 80/tcp** reachable from the internet during install (certificate
  challenge), plus **443/tcp** and **8883/tcp** open for day-to-day traffic —
  on the Windows firewall *and* your router or cloud security group.

What it sets up beyond the air-gapped installer:

| | |
|---|---|
| **HTTPS** | Free Let's Encrypt certificates, issued during install and auto-renewed daily. Or bring your own PEM files, or terminate TLS on an existing reverse proxy. |
| **MQTT over TLS** | Public listener on 8883 with per-device credentials; the loopback listener stays anonymous for the server itself. |
| **Cloud config** | `CLOUD_MODE`, `ALLOW_REMOTE_ENROLLMENT`, `ALLOWED_ORIGINS`, `TRUST_PROXY`, `MQTT_AUTH_DIR` — what Zero-Touch enrollment and remote devices need. |
| **Runs as a service** | Scheduled task as SYSTEM: starts at boot, restarts on crash, no console window to keep open. |
| **Pre-flight + verify** | Checks public DNS, public IP and port availability first, then confirms HTTPS works end-to-end before reporting success. |

The install is resumable — fix whatever a step complains about and re-run it:

```powershell
.\install-windows-cloud.ps1 -ResetStep tls      # retry just the certificate step
.\install-windows-cloud.ps1 -Staging            # rehearse against Let's Encrypt staging
.\install-windows-cloud.ps1 -Fresh              # start over
```

> **Android remote control** over the internet also needs a TURN relay (coturn),
> which has no native Windows build — run it on a small Linux VPS. Windows
> device VNC is relayed over HTTPS and needs nothing extra. The installer prints
> the exact coturn command at the end.

## After install

- Open the web console (shown at the end of the installer) and sign in with the
  default admin credentials, then **change the password immediately**.
- Enroll devices: install the agent APK/EXE and scan the in-app QR code from
  **Devices → Enroll Device**. (Android Zero-Touch provisioning is available on
  internet-connected deployments with TLS.)

## Documentation

Full guides — enrollment, kiosk mode, remote control, groups, and more — are at
**[localdroid.app/docs](https://localdroid.app/docs)**.

## Need it managed?

The MDM is free to self-host. If you'd rather not run it yourself, we offer
**managed hosting, installation & setup, and customization** — see
[localdroid.app](https://localdroid.app) to get a quote.

## License

Proprietary — free to use, not to resell or reverse-engineer. See [LICENSE](LICENSE).
