#!/usr/bin/env bash
# =============================================================================
# NexusNet Bootstrap Installer
# Downloads the Manager and runs it, or installs the bot.
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
# =============================================================================
set -euo pipefail

REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
INSTALL_DIR="${INSTALL_DIR:-/opt/nexusnet}"
MANAGER_PATH="/usr/local/bin/nexus"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'
BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; NC=$'\033[0m'

log()  { echo -e "${BLU}==>${NC} $*"; }
ok()   { echo -e "${GRN}✓${NC}  $*"; }
warn() { echo -e "${YLW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run with sudo: sudo bash $0"
  fi
}

echo -e "${CYN}"
cat << 'BANNER'
╔══════════════════════════════════════════════════╗
║         NexusNet Bootstrap Installer             ║
╚══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# Download manager script
log "Downloading NexusNet Manager..."
TMP_MANAGER="$(mktemp /tmp/nexus-manager-XXXXXX.sh)"
if ! curl -fsSL -o "${TMP_MANAGER}" \
  "https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/nexus.sh"; then
  die "Failed to download manager script from GitHub"
fi
ok "Manager downloaded"

# Install manager to system path
need_root
mkdir -p "$(dirname "${MANAGER_PATH}")"
cp "${TMP_MANAGER}" "${MANAGER_PATH}"
chmod +x "${MANAGER_PATH}"
ok "Manager installed → ${MANAGER_PATH}"

# Also keep a copy inside install dir if it exists
if [[ -d "${INSTALL_DIR}" ]]; then
  cp "${TMP_MANAGER}" "${INSTALL_DIR}/nexus.sh"
  chmod +x "${INSTALL_DIR}/nexus.sh"
fi

rm -f "${TMP_MANAGER}"

echo
echo -e "${GRN}Manager is ready!${NC}"
echo
echo "Run one of the following:"
echo "  sudo nexus                 # Interactive menu"
echo "  sudo nexus doctor          # Health check"
echo "  sudo nexus update          # Update bot"
echo "  sudo nexus backup          # Create backup"
echo
echo "Or for first-time bot installation, follow the project README."
echo
