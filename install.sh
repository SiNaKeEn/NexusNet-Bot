#!/usr/bin/env bash
# NexusNet Bot Manager — Bootstrap (does NOT install the bot)
# bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
set -euo pipefail

REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
MANAGER_PATH="/usr/local/bin/nexusnetmanager"

CYAN=$'\033[1;36m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; NC=$'\033[0m'

if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}[-] Please run as root (sudo).${NC}"
  exit 1
fi

echo -e "${CYAN}[*] Installing NexusNet Bot Manager...${NC}"

TMP="$(mktemp /tmp/nexus-manager-XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsSL -o "${TMP}" \
  "https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/nexus.sh"; then
  echo -e "${RED}[-] Failed to download from GitHub.${NC}"
  exit 1
fi

cp "${TMP}" "${MANAGER_PATH}"
chmod +x "${MANAGER_PATH}"

echo -e "${GREEN}[+] Installed -> ${MANAGER_PATH}${NC}"
echo
echo "  sudo nexusnetmanager"
echo
