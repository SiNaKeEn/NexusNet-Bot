#!/usr/bin/env bash
set -euo pipefail
REPO="SiNaKeEn/NexusNet-Bot"
BRANCH="Manager"
DEST="/usr/local/bin/nxt-bm"
LEGACY="/usr/local/bin/nexusnetmanager"
CYAN=$'\033[1;36m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; NC=$'\033[0m'

if [[ "$(id -u)" -ne 0 ]]; then echo -e "${RED}[-] Run as root${NC}"; exit 1; fi
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

echo -e "${CYAN}[*] Installing NexusNet Bot Manager...${NC}"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -fsSL --connect-timeout 15 --max-time 60 -o "$TMP" \
  "https://raw.githubusercontent.com/${REPO}/${BRANCH}/nexus.sh" \
  || { echo -e "${RED}[-] Download failed${NC}"; exit 1; }
grep -q 'MANAGER_VERSION=' "$TMP" || { echo -e "${RED}[-] Invalid manager file${NC}"; exit 1; }
bash -n "$TMP" || { echo -e "${RED}[-] Manager file has syntax errors${NC}"; exit 1; }
install -m 755 "$TMP" "$DEST"
[[ -e "$LEGACY" || -L "$LEGACY" ]] && ln -sf "$DEST" "$LEGACY"
echo -e "${GREEN}[+] Installed -> ${DEST}${NC}"
echo "  Run:  nxt-bm"
