[README.md](https://github.com/user-attachments/files/32990866/README.md)
# NexusNet Bot Manager v1.1.0

## Install Manager

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
```

```bash
sudo nexusnetmanager
```

## Menu

### Script Management
| # | Action |
|---|--------|
| 1 | Install Manager |
| 2 | Update Manager |
| 3 | Uninstall Manager |

### Bot Management
| # | Action |
|---|--------|
| 4 | Install Bot |
| 5 | Update Bot (local ZIP) |
| 6 | Backup |
| 7 | Restore |
| 8 | Service Management |
| 9 | Diagnostics |
| 10 | Uninstall Bot |
| 0 | Exit |

## Update Bot

Upload ZIP to `/root`:

```bash
scp NexusNet-V1.3.2.zip root@SERVER:/root/
```

Then menu **[5]** — pick the **list number** (or paste full path).
