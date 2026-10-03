#!/usr/bin/env bash
set -euo pipefail
REPO="SiNaKeEn/NexusNet-Bot"
BRANCH="Manager"
DEST="/usr/local/bin/nexusnetmanager"
CYAN=$'[1;36m'; GREEN=$'[1;32m'; RED=$'[1;31m'; NC=$'[0m'
if [[ "$(id -u)" -ne 0 ]]; then echo -e "${RED}[-] Run as root${NC}"; exit 1; fi
echo -e "${CYAN}[*] Installing NexusNet Bot Manager...${NC}"
TMP=$(mktemp)
curl -fsSL -o "$TMP" "https://raw.githubusercontent.com/${REPO}/${BRANCH}/nexus.sh" || { echo fail; exit 1; }
cp "$TMP" "$DEST"; chmod +x "$DEST"; rm -f "$TMP"
echo -e "${GREEN}[+] Installed -> $DEST${NC}"
echo "  nexusnetmanager"
