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
| **Windows Server** — online | *(coming soon)* | Yes |
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

### Windows Server (air-gapped)

1. Extract `localdroid-airgap-windows-*.zip` to a persistent folder (e.g. `C:\LocalDroid`).
2. Right-click **`install-windows-offline.ps1`** → **Run with PowerShell** (as Administrator).

Everything it needs (PostgreSQL, Mosquitto, the server, the web UI, the agents)
is inside the zip — no internet required.

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
