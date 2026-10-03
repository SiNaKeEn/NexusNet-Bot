#!/usr/bin/env bash
# =============================================================================
# NexusNet Manager  —  Advanced Control Script
# Supports: Install | Update (with rollback) | Backup | Restore | Migrate |
#           Repair | Diagnostics | Service | Config | Version Manager
# =============================================================================
# Usage:
#   bash nexus.sh                  → Interactive Menu
#   sudo bash nexus.sh <command>   → Command Mode
# =============================================================================
set -euo pipefail

# ======================== Defaults (override via env) ========================
INSTALL_DIR="${INSTALL_DIR:-/opt/nexusnet}"
SERVICE_NAME="${SERVICE_NAME:-nexusnet}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/nexusnet-backups}"
MIGRATE_ROOT="${MIGRATE_ROOT:-/root/nexusnet-migrate}"
SERVICE_USER="${SERVICE_USER:-nexusnet}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"

# Colors
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'
BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'

# ======================== Helpers ========================
log()  { echo -e "${BLU}==>${NC} $*"; }
ok()   { echo -e "${GRN}✓${NC}  $*"; }
warn() { echo -e "${YLW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "${CYN}ℹ${NC}  $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "این دستور را با root اجرا کن: sudo bash $0 $*"
  fi
}

stamp() { date +%Y%m%d_%H%M%S; }
human_date() { date '+%Y-%m-%d %H:%M'; }

confirm() {
  local msg="${1:-ادامه؟}"
  if [[ "${ASSUME_YES}" == "1" ]]; then return 0; fi
  read -r -p "$(echo -e "${YLW}${msg} [y/N] ${NC}")" ans
  [[ "${ans}" == "y" || "${ans}" == "Y" || "${ans}" == "yes" ]]
}

pause() {
  if [[ "${ASSUME_YES}" != "1" ]]; then
    read -r -p "Enter برای ادامه..."
  fi
}

has_cmd() { command -v "$1" &>/dev/null; }

# ======================== Service Helpers ========================
has_service() {
  systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE_NAME}\.service" \
    || [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]
}

service_stop() {
  if has_service && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" || warn "stop failed (continuing)"
  else
    log "Service not running (skip stop)"
  fi
}

service_start() {
  if has_service; then
    log "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}"
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      ok "Service started"
    else
      err "Service failed to start"
      systemctl --no-pager -l status "${SERVICE_NAME}" || true
      return 1
    fi
  else
    warn "Service unit not found — start manually"
  fi
}

service_restart() {
  if has_service; then
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    systemctl --no-pager -l status "${SERVICE_NAME}" || true
  else
    warn "Service unit not found"
  fi
}

fix_perms() {
  if id "${SERVICE_USER}" &>/dev/null; then
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}" 2>/dev/null || true
    mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups" 2>/dev/null || true
  fi
}

run_preflight() {
  local py="${INSTALL_DIR}/.venv/bin/python"
  local pf="${INSTALL_DIR}/deploy/preflight.py"
  if [[ -x "${py}" && -f "${pf}" ]]; then
    log "Running preflight..."
    if ! "${py}" "${pf}"; then
      warn "Preflight reported problems"
      return 1
    fi
    ok "Preflight passed"
    return 0
  fi
  warn "Preflight skipped (.venv or deploy/preflight.py missing)"
  return 0
}

get_installed_version() {
  if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
    cat "${INSTALL_DIR}/VERSION" | tr -d '[:space:]'
  else
    echo "unknown"
  fi
}

# ======================== GitHub / Version Helpers ========================
github_api() {
  local endpoint="$1"
  curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/${endpoint}" 2>/dev/null || true
}

get_latest_release() {
  github_api "releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1
}

list_releases() {
  github_api "releases?per_page=15" | grep -oP '"tag_name":\s*"\K[^"]+' || true
}

download_release() {
  local tag="$1"
  local dest="$2"
  local asset_url
  # Try to find a zip asset, fallback to source zip
  asset_url=$(github_api "releases/tags/${tag}" | grep -oP '"browser_download_url":\s*"\K[^"]+\.zip' | head -1)
  if [[ -z "${asset_url}" ]]; then
    asset_url="https://github.com/${REPO}/archive/refs/tags/${tag}.zip"
  fi
  log "Downloading ${tag} ..."
  if ! curl -fsSL -o "${dest}" "${asset_url}"; then
    die "Download failed: ${asset_url}"
  fi
  ok "Downloaded → ${dest}"
}

verify_checksum() {
  local file="$1"
  local expected="$2"
  if [[ -z "${expected}" ]]; then
    warn "No checksum provided — skipping verification"
    return 0
  fi
  local actual
  actual=$(sha256sum "${file}" | awk '{print $1}')
  if [[ "${actual}" == "${expected}" ]]; then
    ok "Checksum verified"
    return 0
  else
    err "Checksum mismatch!"
    echo "  Expected: ${expected}"
    echo "  Got:      ${actual}"
    return 1
  fi
}

# ======================== Disk / Health ========================
check_disk_space() {
  local need_mb="${1:-500}"
  local avail
  avail=$(df -m "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "${avail}" && "${avail}" -lt "${need_mb}" ]]; then
    err "Disk space low: ${avail}MB available, need ~${need_mb}MB"
    return 1
  fi
  ok "Disk space OK (${avail:-?}MB free)"
}

health_check() {
  log "Health check..."
  local fail=0
  if has_service; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      ok "Service is active"
    else
      err "Service is NOT active"
      fail=1
    fi
  fi
  if [[ -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
    ok "Python venv OK"
  else
    err "Python venv missing"
    fail=1
  fi
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    ok ".env present"
  else
    err ".env missing"
    fail=1
  fi
  run_preflight || fail=1
  return ${fail}
}

# ======================== Backup ========================
create_manifest() {
  local dest="$1"
  local mode="$2"
  local version
  version="$(get_installed_version)"
  cat > "${dest}/manifest.json" <<EOF
{
  "timestamp": "$(stamp)",
  "human_time": "$(human_date)",
  "hostname": "$(hostname)",
  "install_dir": "${INSTALL_DIR}",
  "version": "${version}",
  "mode": "${mode}",
  "service": "${SERVICE_NAME}"
}
EOF
}

do_backup() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Install dir not found: ${INSTALL_DIR}"

  local mode="${1:-full}"
  local ts; ts="$(stamp)"
  local dest="${BACKUP_ROOT}/${ts}"
  mkdir -p "${dest}"

  log "Creating backup → ${dest} (mode=${mode})"

  # Always backup .env
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    cp -a "${INSTALL_DIR}/.env" "${dest}/.env"
  else
    warn "No .env found"
  fi

  case "${mode}" in
    full)
      [[ -d "${INSTALL_DIR}/storage" ]] && cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
      [[ -d "${INSTALL_DIR}/data" ]]    && cp -a "${INSTALL_DIR}/data"    "${dest}/data"
      [[ -d "${INSTALL_DIR}/backups" ]] && cp -a "${INSTALL_DIR}/backups" "${dest}/backups"
      [[ -f "${INSTALL_DIR}/VERSION" ]] && cp -a "${INSTALL_DIR}/VERSION" "${dest}/VERSION"
      ;;
    db|database)
      mkdir -p "${dest}/database"
      if [[ -d "${INSTALL_DIR}/storage" ]]; then
        find "${INSTALL_DIR}/storage" -maxdepth 2 \( -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' \) \
          -exec cp -a {} "${dest}/database/" \; 2>/dev/null || true
        # fallback full storage if needed
        if [[ ! "$(ls -A "${dest}/database" 2>/dev/null)" ]]; then
          cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
        fi
      fi
      ;;
    config)
      [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${dest}/.env"
      [[ -f "${INSTALL_DIR}/VERSION" ]] && cp -a "${INSTALL_DIR}/VERSION" "${dest}/VERSION"
      ;;
    storage)
      [[ -d "${INSTALL_DIR}/storage" ]] && cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
      ;;
    *)
      die "Unknown backup mode: ${mode} (use: full|db|config|storage)"
      ;;
  esac

  create_manifest "${dest}" "${mode}"

  # Create tarball
  mkdir -p "${BACKUP_ROOT}"
  local tar_path="${BACKUP_ROOT}/nexusnet-backup-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${BACKUP_ROOT}" "${ts}"
  ok "Folder : ${dest}"
  ok "Archive: ${tar_path}"

  # Prune old archives
  local n
  n="$(ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${n}" -gt "${KEEP_BACKUPS}" ]]; then
    ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
    log "Pruned old backups (kept last ${KEEP_BACKUPS})"
  fi

  echo "${tar_path}"
}

# ======================== Restore ========================
list_backups() {
  ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | head -20 || true
}

do_restore() {
  need_root
  local src="${1:-}"

  # Interactive selection if no arg
  if [[ -z "${src}" ]]; then
    echo
    echo -e "${BLD}Available Backups:${NC}"
    local backups=()
    local i=1
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      backups+=("$b")
      local name; name=$(basename "$b")
      local ver="?"
      [[ -f "${b}/manifest.json" ]] && ver=$(grep -oP '"version":\s*"\K[^"]+' "${b}/manifest.json" 2>/dev/null || echo "?")
      local mode="?"
      [[ -f "${b}/manifest.json" ]] && mode=$(grep -oP '"mode":\s*"\K[^"]+' "${b}/manifest.json" 2>/dev/null || echo "?")
      printf "  %2d) %s  (v%s · %s)\n" "$i" "$name" "$ver" "$mode"
      ((i++))
    done < <(list_backups)

    if [[ ${#backups[@]} -eq 0 ]]; then
      die "No backups found in ${BACKUP_ROOT}"
    fi

    echo
    read -r -p "Select backup number: " choice
    if ! [[ "${choice}" =~ ^[0-9]+$ ]] || [[ "${choice}" -lt 1 || "${choice}" -gt ${#backups[@]} ]]; then
      die "Invalid selection"
    fi
    src="${backups[$((choice-1))]}"
  fi

  local work="${src}"
  local tmp=""
  if [[ -f "${src}" && "${src}" == *.tar.gz ]]; then
    tmp="$(mktemp -d /tmp/nexusnet_restore_XXXXXX)"
    tar -xzf "${src}" -C "${tmp}"
    work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${work}" ]] || die "Backup path not found: ${src}"

  echo
  info "Restore from: ${work}"
  [[ -f "${work}/manifest.json" ]] && cat "${work}/manifest.json"
  echo

  # What to restore
  local restore_mode="everything"
  if [[ "${ASSUME_YES}" != "1" ]]; then
    echo "What do you want to restore?"
    echo "  1) Everything"
    echo "  2) Database only"
    echo "  3) Config only (.env)"
    echo "  4) Storage only"
    read -r -p "Choice [1]: " rchoice
    case "${rchoice:-1}" in
      2) restore_mode="db" ;;
      3) restore_mode="config" ;;
      4) restore_mode="storage" ;;
      *) restore_mode="everything" ;;
    esac
  fi

  confirm "⚠ این عملیات روی ${INSTALL_DIR} اعمال می‌شود. سرویس متوقف خواهد شد." || die "Cancelled"

  # Safety backup
  log "Creating safety backup of current state..."
  ASSUME_YES=1 do_backup full >/dev/null || true

  service_stop

  case "${restore_mode}" in
    everything)
      [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok "Restored .env"
      if [[ -d "${work}/storage" ]]; then
        rm -rf "${INSTALL_DIR}/storage"
        cp -a "${work}/storage" "${INSTALL_DIR}/storage"
        ok "Restored storage"
      elif [[ -d "${work}/database" ]]; then
        mkdir -p "${INSTALL_DIR}/storage"
        cp -a "${work}/database/"* "${INSTALL_DIR}/storage/" 2>/dev/null || true
        ok "Restored database files"
      fi
      [[ -d "${work}/data" ]] && rm -rf "${INSTALL_DIR}/data" && cp -a "${work}/data" "${INSTALL_DIR}/data" && ok "Restored data"
      ;;
    db)
      if [[ -d "${work}/storage" ]]; then
        rm -rf "${INSTALL_DIR}/storage"
        cp -a "${work}/storage" "${INSTALL_DIR}/storage"
        ok "Restored storage/database"
      elif [[ -d "${work}/database" ]]; then
        mkdir -p "${INSTALL_DIR}/storage"
        cp -a "${work}/database/"* "${INSTALL_DIR}/storage/" 2>/dev/null || true
        ok "Restored database"
      fi
      ;;
    config)
      [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok "Restored .env"
      ;;
    storage)
      [[ -d "${work}/storage" ]] && rm -rf "${INSTALL_DIR}/storage" && cp -a "${work}/storage" "${INSTALL_DIR}/storage" && ok "Restored storage"
      ;;
  esac

  fix_perms
  run_preflight || true
  service_start
  [[ -n "${tmp}" ]] && rm -rf "${tmp}"
  ok "Restore completed"
}

# ======================== Update (with Rollback) ========================
do_update() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Install dir not found: ${INSTALL_DIR}"

  local target_version="${1:-}"
  local current_version
  current_version="$(get_installed_version)"

  echo
  info "Installed version : ${current_version}"

  if [[ -z "${target_version}" ]]; then
    log "Checking GitHub for latest release..."
    target_version="$(get_latest_release)"
    if [[ -z "${target_version}" ]]; then
      warn "Could not fetch latest release from GitHub"
      echo
      echo "Available releases:"
      list_releases | head -10 | nl
      echo
      read -r -p "Enter target version/tag (or path to local zip): " target_version
      [[ -n "${target_version}" ]] || die "No version specified"
    fi
  fi

  info "Target version    : ${target_version}"

  if [[ "${current_version}" == "${target_version}" ]]; then
    warn "Already on ${target_version}"
    confirm "Force reinstall?" || die "Cancelled"
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo
    echo -e "${BLD}── Dry Run ──────────────────────────────${NC}"
    echo "Current : ${current_version}"
    echo "Target  : ${target_version}"
    echo "Actions that WOULD be performed:"
    echo "  • Create full backup"
    echo "  • Download release ${target_version}"
    echo "  • Stop service"
    echo "  • Replace code (keep .env / storage / data / .venv)"
    echo "  • Run preflight"
    echo "  • Start service + health check"
    echo "  • Rollback on failure"
    echo -e "${BLD}─────────────────────────────────────────${NC}"
    echo "No changes were made."
    return 0
  fi

  confirm "آپدیت به ${target_version} انجام شود؟" || die "Cancelled"

  # 1. Backup
  log "Creating pre-update backup..."
  local backup_path
  backup_path="$(ASSUME_YES=1 do_backup full)"
  ok "Backup: ${backup_path}"

  # 2. Check disk
  check_disk_space 400 || die "Not enough disk space"

  # 3. Download or use local zip
  local zip_path=""
  local tmp_dl=""
  if [[ -f "${target_version}" ]]; then
    zip_path="${target_version}"
    log "Using local zip: ${zip_path}"
  else
    tmp_dl="$(mktemp /tmp/nexusnet_release_XXXXXX.zip)"
    download_release "${target_version}" "${tmp_dl}"
    zip_path="${tmp_dl}"
  fi

  # 4. Extract
  local tmp_extract; tmp_extract="$(mktemp -d /tmp/nexusnet_upgrade_XXXXXX)"
  trap 'rm -rf "'"${tmp_extract}"'" "${tmp_dl:-}"' RETURN

  unzip -q "${zip_path}" -d "${tmp_extract}"
  local src
  if [[ -d "${tmp_extract}/nexus_v36" ]]; then
    src="${tmp_extract}/nexus_v36"
  elif [[ -d "${tmp_extract}/nexus_bot" ]]; then
    src="${tmp_extract}/nexus_bot"
  else
    # GitHub source archive usually has Repo-Tag folder
    src="$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${src}" ]] || die "Could not find source folder inside archive"

  # 5. Create rollback point (code snapshot)
  local rollback_dir="${BACKUP_ROOT}/rollback-$(stamp)"
  mkdir -p "${rollback_dir}"
  log "Creating rollback point → ${rollback_dir}"
  rsync -a --exclude='.venv' --exclude='storage' --exclude='data' --exclude='backups' \
    "${INSTALL_DIR}/" "${rollback_dir}/code/" 2>/dev/null || \
    cp -a "${INSTALL_DIR}" "${rollback_dir}/code_full" 2>/dev/null || true
  [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${rollback_dir}/.env"

  # 6. Stop service
  service_stop

  # 7. Replace code (preserve critical dirs)
  log "Installing new version..."
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name '.env' \
    ! -name 'storage' \
    ! -name 'data' \
    ! -name 'backups' \
    ! -name '.venv' \
    -exec rm -rf {} + 2>/dev/null || true

  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"

  # Preserve / restore .env if wiped
  if [[ ! -f "${INSTALL_DIR}/.env" && -f "${rollback_dir}/.env" ]]; then
    cp -a "${rollback_dir}/.env" "${INSTALL_DIR}/.env"
    ok "Restored .env from rollback point"
  fi

  # Simple .env merge notice (new keys)
  if [[ -f "${INSTALL_DIR}/.env.example" && -f "${INSTALL_DIR}/.env" ]]; then
    log "Checking for new config keys..."
    # Just warn about missing keys (don't auto-add)
    while IFS= read -r line; do
      [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
      local key="${line%%=*}"
      if ! grep -qE "^${key}=" "${INSTALL_DIR}/.env" 2>/dev/null; then
        warn "New config key detected (not in .env): ${key}"
      fi
    done < "${INSTALL_DIR}/.env.example" || true
  fi

  fix_perms

  # 8. Preflight
  if ! run_preflight; then
    warn "Preflight failed"
  fi

  # 9. Start + Health check
  if service_start && health_check; then
    ok "Update to ${target_version} successful!"
    # Clean old rollback if everything is fine (keep last 3)
    ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
  else
    err "Health check FAILED after update!"
    echo
    if confirm "Rollback to previous version?"; then
      do_rollback "${rollback_dir}"
    else
      err "Service may be down. Run: $0 doctor"
      return 1
    fi
  fi
}

do_rollback() {
  need_root
  local rb_dir="${1:-}"

  if [[ -z "${rb_dir}" ]]; then
    echo
    echo -e "${BLD}Available Rollback Points:${NC}"
    local points=()
    local i=1
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      points+=("$p")
      printf "  %2d) %s\n" "$i" "$(basename "$p")"
      ((i++))
    done < <(ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null)

    if [[ ${#points[@]} -eq 0 ]]; then
      # Fallback to latest full backup
      warn "No rollback points found. Trying latest full backup..."
      local latest
      latest="$(ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz 2>/dev/null | head -1)"
      [[ -n "${latest}" ]] || die "No backups available for rollback"
      do_restore "${latest}"
      return
    fi

    read -r -p "Select rollback point: " choice
    rb_dir="${points[$((choice-1))]}"
  fi

  [[ -d "${rb_dir}" ]] || die "Rollback directory not found"

  confirm "Rollback from ${rb_dir}؟" || die "Cancelled"

  service_stop

  if [[ -d "${rb_dir}/code" ]]; then
    find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
      ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' \
      -exec rm -rf {} + 2>/dev/null || true
    cp -a "${rb_dir}/code/." "${INSTALL_DIR}/"
    ok "Code restored from rollback point"
  elif [[ -d "${rb_dir}/code_full" ]]; then
    # more aggressive
    warn "Using full code snapshot"
    rsync -a --delete --exclude='storage' --exclude='data' --exclude='backups' --exclude='.venv' \
      "${rb_dir}/code_full/" "${INSTALL_DIR}/" || true
  fi

  [[ -f "${rb_dir}/.env" ]] && cp -a "${rb_dir}/.env" "${INSTALL_DIR}/.env"

  fix_perms
  run_preflight || true
  service_start
  ok "Rollback completed"
}

# ======================== Migrate ========================
do_export_migrate() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Install dir not found"

  local ts; ts="$(stamp)"
  local dest="${MIGRATE_ROOT}/export-${ts}"
  mkdir -p "${dest}"

  log "Creating migration package → ${dest}"
  if confirm "سرویس برای بکاپ تمیز متوقف شود؟ (توصیه می‌شود)"; then
    service_stop
  fi

  [[ -f "${INSTALL_DIR}/.env" ]]     && cp -a "${INSTALL_DIR}/.env"     "${dest}/.env"
  [[ -d "${INSTALL_DIR}/storage" ]]  && cp -a "${INSTALL_DIR}/storage"  "${dest}/storage"
  [[ -d "${INSTALL_DIR}/data" ]]     && cp -a "${INSTALL_DIR}/data"     "${dest}/data"
  [[ -f "${INSTALL_DIR}/VERSION" ]]  && cp -a "${INSTALL_DIR}/VERSION"  "${dest}/VERSION"
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    cp -a "/etc/systemd/system/${SERVICE_NAME}.service" "${dest}/${SERVICE_NAME}.service"
  fi

  create_manifest "${dest}" "migrate"

  local tar_path="${MIGRATE_ROOT}/nexusnet-migrate-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${MIGRATE_ROOT}" "export-${ts}"

  # Restart if we stopped
  has_service && ! systemctl is-active --quiet "${SERVICE_NAME}" && service_start || true

  ok "Migration package ready: ${tar_path}"
  echo
  echo -e "${BLD}روی VPS جدید:${NC}"
  echo "  1) bash <(curl -fsSL https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/install.sh)"
  echo "  2) sudo bash nexus.sh import-migrate ${tar_path}"
  echo "  3) sudo bash nexus.sh doctor"
}

do_import_migrate() {
  need_root
  local src="${1:-}"
  [[ -n "${src}" ]] || die "Usage: $0 import-migrate <migrate.tar.gz|dir>"
  [[ -d "${INSTALL_DIR}" ]] || die "Install dir missing — first install the bot"

  local work="${src}"
  local tmp=""
  if [[ -f "${src}" && "${src}" == *.tar.gz ]]; then
    tmp="$(mktemp -d /tmp/nexusnet_migrate_XXXXXX)"
    tar -xzf "${src}" -C "${tmp}"
    work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${work}" ]] || die "Package not found"
  [[ -f "${work}/manifest.json" ]] && cat "${work}/manifest.json"
  confirm "داده از بسته مهاجرت روی این سرور اعمال شود؟" || die "Cancelled"

  service_stop

  [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok ".env"
  if [[ -d "${work}/storage" ]]; then
    rm -rf "${INSTALL_DIR}/storage"
    cp -a "${work}/storage" "${INSTALL_DIR}/storage"
    ok "storage (database)"
  fi
  [[ -d "${work}/data" ]] && rm -rf "${INSTALL_DIR}/data" && cp -a "${work}/data" "${INSTALL_DIR}/data" && ok "data"

  if [[ -f "${work}/${SERVICE_NAME}.service" && ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    cp -a "${work}/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" || true
    ok "systemd unit installed"
  fi

  fix_perms
  run_preflight || true
  service_start
  [[ -n "${tmp}" ]] && rm -rf "${tmp}"
  ok "Import migrate done — run: $0 doctor"
}

do_ssh_migrate() {
  need_root
  echo
  echo -e "${BLD}══ Server-to-Server Migration ══${NC}"
  echo

  read -r -p "Destination VPS IP: " dest_ip
  [[ -n "${dest_ip}" ]] || die "IP required"
  read -r -p "SSH Port [22]: " dest_port
  dest_port="${dest_port:-22}"
  read -r -p "SSH User [root]: " dest_user
  dest_user="${dest_user:-root}"

  echo
  echo "Authentication method:"
  echo "  1) SSH Key (recommended)"
  echo "  2) Password"
  read -r -p "Choice [1]: " auth_choice

  local ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "${dest_port}")
  local ssh_cmd=(ssh "${ssh_opts[@]}" "${dest_user}@${dest_ip}")
  local scp_cmd=(scp -P "${dest_port}" -o StrictHostKeyChecking=accept-new)

  if [[ "${auth_choice}" == "2" ]]; then
    if ! has_cmd sshpass; then
      warn "sshpass not installed. Install it or use SSH key."
      die "Cannot proceed with password auth without sshpass"
    fi
    read -r -s -p "SSH Password: " dest_pass
    echo
    export SSHPASS="${dest_pass}"
    ssh_cmd=(sshpass -e ssh "${ssh_opts[@]}" "${dest_user}@${dest_ip}")
    scp_cmd=(sshpass -e scp -P "${dest_port}" -o StrictHostKeyChecking=accept-new)
  fi

  log "Testing SSH connection..."
  if ! "${ssh_cmd[@]}" "echo ok" &>/dev/null; then
    die "SSH connection failed"
  fi
  ok "SSH connected"

  log "Checking destination..."
  local dest_info
  dest_info=$("${ssh_cmd[@]}" "echo \"OS=\$(uname -s); RAM=\$(free -m | awk '/Mem/{print \$2}'); DISK=\$(df -m / | awk 'NR==2{print \$4}'); PYTHON=\$(python3 --version 2>/dev/null || echo none)\"")
  echo "  ${dest_info}"

  confirm "ادامه مهاجرت به ${dest_ip}؟" || die "Cancelled"

  # Create package locally
  log "Creating migration package on source..."
  local pkg
  pkg="$(ASSUME_YES=1 do_export_migrate | tail -1)"
  # Actually capture the tar path properly
  local ts; ts="$(stamp)"
  local dest_pkg="${MIGRATE_ROOT}/nexusnet-migrate-${ts}.tar.gz"
  # Re-run export more carefully
  ASSUME_YES=1 do_export_migrate >/dev/null
  pkg="$(ls -1t "${MIGRATE_ROOT}"/nexusnet-migrate-*.tar.gz | head -1)"

  log "Transferring package (${pkg})..."
  "${scp_cmd[@]}" "${pkg}" "${dest_user}@${dest_ip}:/tmp/nexusnet-migrate.tar.gz"

  log "Running import on destination..."
  "${ssh_cmd[@]}" "bash -s" <<'REMOTE'
set -e
if [[ ! -d /opt/nexusnet ]]; then
  echo "NexusNet not installed on destination. Please install first."
  exit 1
fi
# Assuming nexus.sh is available
if [[ -f /opt/nexusnet/nexus.sh ]]; then
  sudo bash /opt/nexusnet/nexus.sh import-migrate /tmp/nexusnet-migrate.tar.gz
elif [[ -f /usr/local/bin/nexus ]]; then
  sudo nexus import-migrate /tmp/nexusnet-migrate.tar.gz
else
  echo "Manager script not found on destination"
  exit 1
fi
REMOTE

  ok "Migration transfer completed"
  echo
  info "Source VPS remains untouched."
  info "After verifying the new VPS, update your DNS / reverse proxy."
}

# ======================== Repair ========================
do_repair() {
  need_root
  echo
  echo -e "${BLD}Repair NexusNet${NC}"
  echo "  1) Repair Python Environment (venv)"
  echo "  2) Repair Dependencies"
  echo "  3) Repair Permissions"
  echo "  4) Repair Systemd"
  echo "  5) Repair Configuration (.env)"
  echo "  6) Repair Everything"
  echo "  0) Back"
  read -r -p "Choice: " choice

  case "${choice}" in
    1)
      log "Rebuilding venv..."
      if [[ -d "${INSTALL_DIR}/.venv" ]]; then
        rm -rf "${INSTALL_DIR}/.venv"
      fi
      python3 -m venv "${INSTALL_DIR}/.venv"
      "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip
      if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
        "${INSTALL_DIR}/.venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"
      elif [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]]; then
        "${INSTALL_DIR}/.venv/bin/pip" install -r "${INSTALL_DIR}/deploy/requirements.txt"
      fi
      fix_perms
      ok "Python environment repaired"
      ;;
    2)
      log "Reinstalling dependencies..."
      local req=""
      [[ -f "${INSTALL_DIR}/requirements.txt" ]] && req="${INSTALL_DIR}/requirements.txt"
      [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
      [[ -n "${req}" ]] || die "requirements.txt not found"
      "${INSTALL_DIR}/.venv/bin/pip" install --upgrade -r "${req}"
      ok "Dependencies repaired"
      ;;
    3)
      log "Fixing permissions..."
      fix_perms
      ok "Permissions fixed"
      ;;
    4)
      log "Repairing systemd unit..."
      if [[ -f "${INSTALL_DIR}/deploy/systemd.service" ]]; then
        cp -a "${INSTALL_DIR}/deploy/systemd.service" "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        systemctl enable "${SERVICE_NAME}"
        ok "Systemd unit repaired"
      else
        warn "deploy/systemd.service not found"
      fi
      ;;
    5)
      if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
        if [[ -f "${INSTALL_DIR}/.env.example" ]]; then
          cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
          warn ".env created from example — please edit it"
        else
          die ".env and .env.example both missing"
        fi
      else
        ok ".env exists"
        # Check critical keys
        for key in BOT_TOKEN; do
          if ! grep -qE "^${key}=.+" "${INSTALL_DIR}/.env" 2>/dev/null; then
            warn "${key} seems empty or missing"
          fi
        done
      fi
      ;;
    6)
      ASSUME_YES=1
      do_repair <<< "1"
      do_repair <<< "2"
      do_repair <<< "3"
      do_repair <<< "4"
      do_repair <<< "5"
      ok "Full repair attempted"
      ;;
    0) return ;;
    *) warn "Invalid choice" ;;
  esac
}

# ======================== Diagnostics ========================
do_doctor() {
  need_root
  local report="/tmp/nexusnet-diagnostics-$(stamp).txt"
  {
    echo "NexusNet Diagnostics Report"
    echo "Generated: $(date)"
    echo "Hostname : $(hostname)"
    echo "========================================"
  } > "${report}"

  log "Running diagnostics..."
  local fail=0

  echo
  echo -e "${BLD}── System ──────────────────────────────${NC}"
  echo "  OS     : $(uname -srm)"
  echo "  CPU    : $(nproc) cores"
  echo "  RAM    : $(free -h | awk '/Mem/{print $2}') total"
  echo "  Disk   : $(df -h "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2{print $4 " free"}')"

  echo
  echo -e "${BLD}── Installation ────────────────────────${NC}"
  if [[ -d "${INSTALL_DIR}" ]]; then ok "Install dir: ${INSTALL_DIR}"; else err "Install dir missing"; fail=1; fi
  local ver; ver="$(get_installed_version)"
  echo "  Version: ${ver}"

  if [[ -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
    ok "Python venv"
    echo "    $($INSTALL_DIR/.venv/bin/python --version 2>&1)"
  else
    err "Python venv missing"; fail=1
  fi

  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    ok ".env exists"
    if grep -qE '^BOT_TOKEN=.+' "${INSTALL_DIR}/.env" 2>/dev/null; then
      ok "BOT_TOKEN present"
    else
      warn "BOT_TOKEN not found or empty"
    fi
    if grep -qE '^CREDENTIAL_ENCRYPTION_KEY=.+' "${INSTALL_DIR}/.env" 2>/dev/null; then
      ok "CREDENTIAL_ENCRYPTION_KEY set"
    else
      warn "CREDENTIAL_ENCRYPTION_KEY empty"
    fi
  else
    err ".env missing"; fail=1
  fi

  echo
  echo -e "${BLD}── Database ────────────────────────────${NC}"
  if [[ -f "${INSTALL_DIR}/storage/nexusnet.db" ]]; then
    ok "SQLite DB present"
    local sz; sz="$(du -h "${INSTALL_DIR}/storage/nexusnet.db" | awk '{print $1}')"
    echo "    Size: ${sz}"
    if has_cmd sqlite3; then
      local users
      users="$(sqlite3 "${INSTALL_DIR}/storage/nexusnet.db" 'SELECT count(*) FROM users;' 2>/dev/null || echo '?')"
      echo "    Users: ${users}"
    fi
  else
    warn "nexusnet.db not found under storage/"
  fi

  echo
  echo -e "${BLD}── Service ─────────────────────────────${NC}"
  if has_service; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      ok "Service active"
    else
      err "Service NOT active"; fail=1
    fi
    systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null && ok "Service enabled" || warn "Service not enabled"
  else
    warn "No systemd unit found"
  fi

  echo
  echo -e "${BLD}── Preflight ───────────────────────────${NC}"
  run_preflight || fail=1

  # Write summary to report
  {
    echo "Version: ${ver}"
    echo "Fail count: ${fail}"
    echo "Install: ${INSTALL_DIR}"
    df -h
    free -h
    systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
  } >> "${report}"

  echo
  if [[ "${fail}" -eq 0 ]]; then
    ok "Doctor: all critical checks passed"
  else
    err "Doctor: some checks failed (${fail})"
  fi
  info "Full report: ${report}"
  return ${fail}
}

# ======================== Service Manager ========================
do_service_menu() {
  while true; do
    echo
    echo -e "${BLD}Service Management${NC}"
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Status"
    echo "  5) Logs (last 80)"
    echo "  6) Follow Logs"
    echo "  7) Enable on boot"
    echo "  8) Disable on boot"
    echo "  0) Back"
    read -r -p "Choice: " c
    case "${c}" in
      1) need_root; service_start ;;
      2) need_root; service_stop ;;
      3) need_root; service_restart ;;
      4) do_status ;;
      5) journalctl -u "${SERVICE_NAME}" -n 80 --no-pager ;;
      6) journalctl -u "${SERVICE_NAME}" -f ;;
      7) need_root; systemctl enable "${SERVICE_NAME}" && ok "Enabled" ;;
      8) need_root; systemctl disable "${SERVICE_NAME}" && ok "Disabled" ;;
      0) break ;;
      *) warn "Invalid" ;;
    esac
  done
}

do_status() {
  echo "Install : ${INSTALL_DIR}"
  echo "Version : $(get_installed_version)"
  if has_service; then
    systemctl --no-pager -l status "${SERVICE_NAME}" || true
  else
    warn "No systemd unit"
  fi
  if [[ -f "${INSTALL_DIR}/storage/nexusnet.db" ]]; then
    echo "DB Size : $(du -h "${INSTALL_DIR}/storage/nexusnet.db" | awk '{print $1}')"
  fi
}

do_logs() {
  local n="${1:-80}"
  journalctl -u "${SERVICE_NAME}" -n "${n}" --no-pager
}

# ======================== Version Manager ========================
do_version_menu() {
  local current; current="$(get_installed_version)"
  echo
  echo -e "${BLD}Version Manager${NC}"
  echo "  Installed: ${current}"
  echo
  log "Fetching releases from GitHub..."
  local releases
  releases="$(list_releases)"
  if [[ -z "${releases}" ]]; then
    warn "Could not fetch releases"
  else
    echo -e "${BLD}Available:${NC}"
    echo "${releases}" | head -12 | nl
  fi
  echo
  echo "  1) Update to latest"
  echo "  2) Select specific version"
  echo "  3) Rollback"
  echo "  4) Show installed version"
  echo "  0) Back"
  read -r -p "Choice: " c
  case "${c}" in
    1) do_update ;;
    2)
      read -r -p "Enter version/tag: " ver
      [[ -n "${ver}" ]] && do_update "${ver}"
      ;;
    3) do_rollback ;;
    4) echo "Installed: ${current}" ;;
    0) return ;;
  esac
}

# ======================== Uninstall ========================
do_uninstall() {
  need_root
  echo
  echo -e "${BLD}Uninstall NexusNet${NC}"
  echo "  1) Remove application only (keep backups + data)"
  echo "  2) Remove application + service"
  echo "  3) Remove EVERYTHING (including backups)"
  echo "  0) Cancel"
  read -r -p "Choice: " c

  case "${c}" in
    1)
      confirm "Remove application files?" || die "Cancelled"
      service_stop
      rm -rf "${INSTALL_DIR}"
      ok "Application removed. Backups kept in ${BACKUP_ROOT}"
      ;;
    2)
      confirm "Remove application + systemd service?" || die "Cancelled"
      service_stop
      systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      rm -rf "${INSTALL_DIR}"
      ok "Application + service removed. Backups kept."
      ;;
    3)
      confirm "⚠ DELETE EVERYTHING including all backups؟" || die "Cancelled"
      confirm "Really sure? This cannot be undone." || die "Cancelled"
      service_stop
      systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      rm -rf "${INSTALL_DIR}" "${BACKUP_ROOT}" "${MIGRATE_ROOT}"
      ok "Everything removed"
      ;;
    0) return ;;
  esac
}

# ======================== Interactive Menu ========================
show_banner() {
  clear 2>/dev/null || true
  echo -e "${CYN}"
  cat << 'BANNER'
╔══════════════════════════════════════════════════╗
║           NexusNet Management Script             ║
║                  Advanced Edition                ║
╚══════════════════════════════════════════════════╝
BANNER
  echo -e "${NC}"
  local ver; ver="$(get_installed_version 2>/dev/null || echo 'not installed')"
  echo -e "  Install Dir : ${INSTALL_DIR}"
  echo -e "  Version     : ${ver}"
  echo -e "  Service     : ${SERVICE_NAME}"
  echo
}

main_menu() {
  while true; do
    show_banner
    echo -e "${BLD}  1)${NC} Update NexusNet"
    echo -e "${BLD}  2)${NC} Backup"
    echo -e "${BLD}  3)${NC} Restore"
    echo -e "${BLD}  4)${NC} Migrate (Export / Import / SSH)"
    echo -e "${BLD}  5)${NC} Repair Installation"
    echo -e "${BLD}  6)${NC} Diagnostics (Doctor)"
    echo -e "${BLD}  7)${NC} Service Management"
    echo -e "${BLD}  8)${NC} Version Manager"
    echo -e "${BLD}  9)${NC} Uninstall"
    echo -e "${BLD}  0)${NC} Exit"
    echo
    read -r -p "  Select: " choice
    echo

    case "${choice}" in
      1) do_update; pause ;;
      2)
        echo "Backup type: 1) Full  2) Database  3) Config  4) Storage"
        read -r -p "Choice [1]: " bt
        case "${bt:-1}" in
          2) do_backup db ;;
          3) do_backup config ;;
          4) do_backup storage ;;
          *) do_backup full ;;
        esac
        pause
        ;;
      3) do_restore; pause ;;
      4)
        echo "  1) Export migrate package"
        echo "  2) Import migrate package"
        echo "  3) Server-to-Server (SSH)"
        read -r -p "Choice: " mc
        case "${mc}" in
          1) do_export_migrate ;;
          2) read -r -p "Path to package: " p; do_import_migrate "$p" ;;
          3) do_ssh_migrate ;;
        esac
        pause
        ;;
      5) do_repair; pause ;;
      6) do_doctor; pause ;;
      7) do_service_menu ;;
      8) do_version_menu; pause ;;
      9) do_uninstall; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "Invalid choice" ; sleep 1 ;;
    esac
  done
}

# ======================== Usage / Help ========================
usage() {
  cat << EOF
NexusNet Manager — ${INSTALL_DIR}

Usage:
  bash $0                    Interactive menu
  sudo bash $0 <command>     Command mode

Commands:
  status                     وضعیت سرویس و نسخه
  logs [N]                   آخرین N خط لاگ (پیش‌فرض 80)
  doctor                     بررسی سلامت نصب

  start | stop | restart     مدیریت سرویس

  backup [full|db|config|storage]
  restore [path]             ریستور (interactive اگر path ندی)
  update [version|zip]       آپدیت با rollback خودکار
  rollback [dir]             بازگشت به نسخه قبلی

  export-migrate             بسته مهاجرت
  import-migrate <pkg>       وارد کردن بسته مهاجرت
  migrate                    Server-to-Server via SSH

  repair                     منوی تعمیر
  version                    منوی نسخه
  uninstall                  حذف نصب

  --dry-run                  فقط شبیه‌سازی (با update)

Env overrides:
  INSTALL_DIR  SERVICE_NAME  BACKUP_ROOT  SERVICE_USER
  KEEP_BACKUPS  ASSUME_YES=1  DRY_RUN=1  REPO

Examples:
  sudo bash $0 backup
  sudo bash $0 update
  sudo bash $0 update v36.4.0
  sudo bash $0 update --dry-run
  sudo bash $0 restore
  sudo bash $0 doctor
EOF
}

# ======================== Entry Point ========================
# Handle global flags
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ; shift || true ;;
    --yes|-y)  ASSUME_YES=1 ; shift || true ;;
  esac
done

cmd="${1:-}"
shift || true

case "${cmd}" in
  "")                main_menu ;;
  status)            do_status ;;
  logs)              do_logs "${1:-80}" ;;
  doctor)            do_doctor ;;
  start)             need_root; service_start ;;
  stop)              need_root; service_stop ;;
  restart)           need_root; service_restart ;;
  backup)            do_backup "${1:-full}" ;;
  restore)           do_restore "${1:-}" ;;
  update)            do_update "${1:-}" ;;
  rollback)          do_rollback "${1:-}" ;;
  export-migrate)    do_export_migrate ;;
  import-migrate)    do_import_migrate "${1:-}" ;;
  migrate)           do_ssh_migrate ;;
  repair)            do_repair ;;
  version)           do_version_menu ;;
  uninstall)         do_uninstall ;;
  -h|--help|help)    usage ;;
  *)                 die "Unknown command: ${cmd}  (help برای راهنما)" ;;
esac
