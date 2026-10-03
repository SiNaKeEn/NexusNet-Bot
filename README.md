[README.md](https://github.com/user-attachments/files/32991074/README.md)
# NexusNet Bot Manager

**v1.3.0** — Install, update, backup, restore and migrate NexusNet Bot.

---

## Quick install (manager only)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
```

Then run (no need to type `sudo`):

```bash
nexusnetmanager
```

---

## Menu overview

### Script Management
| # | Action | Description |
|---|--------|-------------|
| 1 | Install Manager | Copy manager to `/usr/local/bin/nexusnetmanager` |
| 2 | Update Manager | Download latest manager from GitHub and replace |
| 3 | Uninstall Manager | Remove the manager command only |

### Bot Management
| # | Action | Description |
|---|--------|-------------|
| 4 | Install Bot | Install bot from a local ZIP |
| 5 | Update Bot | Update bot from a local ZIP |
| 6 | Backup | Full or database-only backup |
| 7 | Restore | Restore from a previous backup |
| 8 | Migrate VPS | Export / Import package for another server |
| 9 | Service Management | Start / Stop / Restart / Logs |
| 10 | Diagnostics | Health checks |
| 11 | Uninstall Bot | Remove bot (optional keep backups) |
| 0 | Exit | |

---

## How to update the bot

1. Upload the ZIP to the server:

```bash
scp NexusNet-V1.3.2.zip root@YOUR_SERVER:/root/
```

2. Run:

```bash
nexusnetmanager
```

3. Choose **[5] Update Bot**

4. Select ZIP in one of these ways:

**Option A — type name / version (recommended)**

```
Choice [1]: 1
Filename / path / version: NexusNet-V1.3.2.zip
```

You can also type just the version:

```
Filename / path / version: 1.3.2
```

Or the full path:

```
Filename / path / version: /root/NexusNet-V1.3.2.zip
```

**Shortcut:** on the first prompt you can type the filename/version directly instead of `1` or `2`:

```
Choice [1]: 1.3.2
```

**Option B — scan and pick from list**

```
Choice [1]: 2
Select number: 1
```

---

## First install of the bot

1. Upload bot ZIP to `/root`
2. `nexusnetmanager` → **[4] Install Bot**
3. Edit `/opt/nexusnet/.env` (`BOT_TOKEN`, `CREDENTIAL_ENCRYPTION_KEY`, ...)
4. **[9] Service Management** → Start

Generate encryption key if needed:

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

---

## Migrate to another VPS

**On old server:**

- Menu **[8] → Export**
- Copy the file from `/root/nexusnet-migrate/` to the new VPS

**On new server:**

1. Install manager + install bot (same version ZIP)
2. Menu **[8] → Import** and give path to the migrate package

---

## Command line

```bash
nexusnetmanager                 # menu
nexusnetmanager update          # update bot (interactive ZIP)
nexusnetmanager update-manager  # update this script
nexusnetmanager backup
nexusnetmanager restore
nexusnetmanager start|stop|restart
nexusnetmanager doctor
nexusnetmanager logs
```

---

## Paths

| Item | Path |
|------|------|
| Manager binary | `/usr/local/bin/nexusnetmanager` |
| Bot install | `/opt/nexusnet` |
| Backups | `/root/nexusnet-backups` |
| Migrate packages | `/root/nexusnet-migrate` |
| Upload bot ZIP here | `/root/NexusNet-*.zip` |

---

## Notes

- Bot updates are **local ZIP only** (not from GitHub Releases).
- Manager updates come from the `Manager` branch on GitHub.
- The manager auto-elevates with `sudo` — you do not need to type `sudo` yourself.
- Always keep a backup before major updates.

---

Developed by **SiNa (KeEn)** · `nexusnetmanager` · v1.3.0
