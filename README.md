# NexusNet Bot Manager

Simple control panel for NexusNet Bot.

## Install Manager

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
```

Then:

```bash
sudo nexusnetmanager
```

## Menu

| # | Action |
|---|--------|
| 1 | Install Bot (from ZIP in `/root`) |
| 2 | Update Manager (GitHub) |
| 3 | Update Bot (local ZIP) |
| 4 | Backup |
| 5 | Restore |
| 6 | Service Management |
| 7 | Diagnostics |
| 8 | Uninstall |
| 0 | Exit |

## Update Bot

```bash
scp NexusNet-V1.3.2.zip root@SERVER:/root/
sudo nexusnetmanager
# choose [3]
```

The menu lists ZIP files found in `/root`. Enter the **list number** (1, 2, 3...), not the version string.

## Paths

| Item | Path |
|------|------|
| Bot | `/opt/nexusnet` |
| Backups | `/root/nexusnet-backups` |
| Manager | `/usr/local/bin/nexusnetmanager` |
