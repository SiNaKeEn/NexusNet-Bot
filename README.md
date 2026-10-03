<div align="center">

# NexusNet Bot Manager

**Simple control panel for NexusNet Bot** — install, update, backup, restore.

[![Version](https://img.shields.io/badge/manager-v1.0.0-blue?style=for-the-badge)](#)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](#)

</div>

---

## Install Manager

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
```

This only installs the **manager** command. It does **not** install the bot.

After install:

```bash
sudo nexusnetmanager
```

---

## Menu

| # | Action | Description |
|---|--------|-------------|
| 1 | **Install Bot** | Install from a ZIP file placed in `/root` |
| 2 | **Update Manager** | Pull latest manager script from GitHub |
| 3 | **Update Bot** | Update bot from a local ZIP in `/root` |
| 4 | **Backup** | Full or database-only backup |
| 5 | **Restore** | Restore from a previous backup |
| 6 | **Service Management** | Start / Stop / Restart / Logs |
| 7 | **Diagnostics** | Health check |
| 8 | **Uninstall** | Remove bot (optional: keep backups) |
| 0 | Exit | |

---

## How to update the bot

1. Upload the new ZIP to the server:

```bash
scp NexusNet-V1.3.2.zip root@YOUR_SERVER:/root/
```

2. Run the manager and choose **3) Update Bot**  
   (or: `sudo nexusnetmanager update`)

The manager will:
- Detect ZIP files in `/root`
- Create a backup
- Stop the service
- Replace code (keep `.env`, `storage`, `data`, `.venv`)
- Write the new version
- Start the service
- Offer rollback if start fails

---

## First-time bot install

1. Upload bot ZIP to `/root`
2. `sudo nexusnetmanager` → **1) Install Bot**
3. Edit `/opt/nexusnet/.env` (BOT_TOKEN, CREDENTIAL_ENCRYPTION_KEY, ...)
4. Service Management → Start

---

## Command mode

```bash
sudo nexusnetmanager install
sudo nexusnetmanager update
sudo nexusnetmanager update-manager
sudo nexusnetmanager backup
sudo nexusnetmanager restore
sudo nexusnetmanager doctor
sudo nexusnetmanager start | stop | restart
sudo nexusnetmanager logs
sudo nexusnetmanager status
```

---

## Paths

| Item | Path |
|------|------|
| Bot install | `/opt/nexusnet` |
| Backups | `/root/nexusnet-backups` |
| Manager binary | `/usr/local/bin/nexusnetmanager` |
| Bot ZIP (upload here) | `/root/NexusNet-*.zip` |

---

## Notes

- **Bot updates are local-ZIP only** — no GitHub Releases required for the bot package.
- **Manager updates** come from the `Manager` branch on GitHub.
- Always keep a recent backup before major updates.
- Generate encryption key if needed:

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Put it in `.env` as `CREDENTIAL_ENCRYPTION_KEY=...`

---

<div align="center">

Developed by **SiNa (KeEn)** · `nexusnetmanager` · v1.0.0

</div>
