#!/usr/bin/env bash
# =============================================================================
# NexusNet Bootstrap Installer
# Downloads the Manager and installs it as: nexusnetmanager
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
# =============================================================================
set -euo pipefail

REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
INSTALL_DIR="${INSTALL_DIR:-/opt/nexusnet}"
MANAGER_PATH="/usr/local/bin/nexusnetmanager"

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
echo "Run:"
echo "  sudo nexusnetmanager              # Interactive menu"
echo "  sudo nexusnetmanager doctor       # Health check"
echo "  sudo nexusnetmanager update       # Update bot"
echo "  sudo nexusnetmanager backup       # Create backup"
echo "  sudo nexusnetmanager db-migrate   # SQLite → PostgreSQL"
echo
