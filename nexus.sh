#!/usr/bin/env bash
# =============================================================================
# NexusNet Bot Manager
# Command: nexusnetmanager
# Bot updates: local ZIP only (upload to /root)
# Manager updates: from GitHub (Manager branch)
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/nexusnet}"
SERVICE_NAME="${SERVICE_NAME:-nexusnet}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/nexusnet-backups}"
SERVICE_USER="${SERVICE_USER:-nexusnet}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
ASSUME_YES="${ASSUME_YES:-0}"
CMD_NAME="nexusnetmanager"
MANAGER_VERSION="1.0.0"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'
BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'

log()  { echo -e "${BLU}[*]${NC} $*"; }
ok()   { echo -e "${GRN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "${CYN}[i]${NC} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root: sudo ${CMD_NAME}"
  fi
}

stamp() { date +%Y%m%d_%H%M%S; }

confirm() {
  local msg="${1:-Continue?}"
  if [[ "${ASSUME_YES}" == "1" ]]; then return 0; fi
  read -r -p "$(echo -e "${YLW}${msg} [y/N] ${NC}")" ans
  [[ "${ans}" == "y" || "${ans}" == "Y" || "${ans}" == "yes" ]]
}

pause() {
  if [[ "${ASSUME_YES}" != "1" ]]; then
    read -r -p "Press Enter to continue..."
  fi
}

has_cmd() { command -v "$1" &>/dev/null; }

# ======================== Service ========================
has_service() {
  systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE_NAME}\.service" \
    || [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]
}

service_stop() {
  if has_service && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" || warn "stop failed (continuing)"
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
    warn "Service unit not found"
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
  return 0
}

get_bot_version() {
  if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
    tr -d '[:space:]' < "${INSTALL_DIR}/VERSION"
  else
    echo "not installed"
  fi
}

# ======================== Backup ========================
do_backup() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed at ${INSTALL_DIR}"

  local mode="${1:-full}"
  local ts; ts="$(stamp)"
  local dest="${BACKUP_ROOT}/${ts}"
  mkdir -p "${dest}"

  log "Backup -> ${dest} (${mode})"

  [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${dest}/.env"
  [[ -f "${INSTALL_DIR}/VERSION" ]] && cp -a "${INSTALL_DIR}/VERSION" "${dest}/VERSION"

  case "${mode}" in
    full)
      [[ -d "${INSTALL_DIR}/storage" ]] && cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
      [[ -d "${INSTALL_DIR}/data" ]]    && cp -a "${INSTALL_DIR}/data"    "${dest}/data"
      ;;
    db)
      mkdir -p "${dest}/database"
      find "${INSTALL_DIR}/storage" -maxdepth 2 \( -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' \) \
        -exec cp -a {} "${dest}/database/" \; 2>/dev/null || true
      if [[ ! "$(ls -A "${dest}/database" 2>/dev/null)" ]] && [[ -d "${INSTALL_DIR}/storage" ]]; then
        cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
      fi
      ;;
    *) die "Unknown mode: ${mode} (full|db)" ;;
  esac

  {
    echo "timestamp=${ts}"
    echo "hostname=$(hostname)"
    echo "version=$(get_bot_version)"
    echo "mode=${mode}"
  } > "${dest}/meta.txt"

  mkdir -p "${BACKUP_ROOT}"
  local tar_path="${BACKUP_ROOT}/nexusnet-backup-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${BACKUP_ROOT}" "${ts}"
  ok "Archive: ${tar_path}"

  local n
  n="$(ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${n}" -gt "${KEEP_BACKUPS}" ]]; then
    ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
    log "Pruned old backups (kept ${KEEP_BACKUPS})"
  fi
  echo "${tar_path}"
}

# ======================== Restore ========================
do_restore() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"

  local src="${1:-}"
  if [[ -z "${src}" ]]; then
    echo
    echo -e "${BLD}Available backups:${NC}"
    local backups=()
    local i=1
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      backups+=("$b")
      local name ver="?"
      name=$(basename "$b")
      [[ -f "${b}/meta.txt" ]] && ver=$(grep '^version=' "${b}/meta.txt" 2>/dev/null | cut -d= -f2)
      printf "  %2d) %s  (v%s)\n" "$i" "$name" "$ver"
      ((i++))
    done < <(ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | head -15)

    [[ ${#backups[@]} -gt 0 ]] || die "No backups found"
    echo
    read -r -p "Select number: " choice
    [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 && "${choice}" -le ${#backups[@]} ]] \
      || die "Invalid selection"
    src="${backups[$((choice-1))]}"
  fi

  local work="${src}" tmp=""
  if [[ -f "${src}" && "${src}" == *.tar.gz ]]; then
    tmp="$(mktemp -d /tmp/nexus_restore_XXXXXX)"
    tar -xzf "${src}" -C "${tmp}"
    work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${work}" ]] || die "Backup not found"

  echo
  info "Restore from: ${work}"
  [[ -f "${work}/meta.txt" ]] && cat "${work}/meta.txt"
  confirm "WARNING: Service will stop. Continue?" || die "Cancelled"

  ASSUME_YES=1 do_backup full >/dev/null || true
  service_stop

  [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok ".env restored"
  if [[ -d "${work}/storage" ]]; then
    rm -rf "${INSTALL_DIR}/storage"
    cp -a "${work}/storage" "${INSTALL_DIR}/storage"
    ok "storage restored"
  elif [[ -d "${work}/database" ]]; then
    mkdir -p "${INSTALL_DIR}/storage"
    cp -a "${work}/database/"* "${INSTALL_DIR}/storage/" 2>/dev/null || true
    ok "database restored"
  fi
  [[ -d "${work}/data" ]] && rm -rf "${INSTALL_DIR}/data" && cp -a "${work}/data" "${INSTALL_DIR}/data" && ok "data restored"

  fix_perms
  run_preflight || true
  service_start
  [[ -n "${tmp}" ]] && rm -rf "${tmp}"
  ok "Restore done"
}

# ======================== Install Bot ========================
find_local_zips() {
  # Look in /root for bot zip files
  find /root -maxdepth 1 -type f \( -iname 'NexusNet*.zip' -o -iname 'nexus*.zip' -o -iname '*nexusnet*.zip' \) 2>/dev/null | sort -r
}

pick_zip() {
  local zips=()
  while IFS= read -r z; do
    [[ -n "$z" ]] && zips+=("$z")
  done < <(find_local_zips)

  if [[ ${#zips[@]} -eq 0 ]]; then
    echo
    warn "No ZIP found in /root"
    echo "  Upload a bot ZIP to /root first, e.g.:"
    echo "    scp NexusNet-V1.3.2.zip root@SERVER:/root/"
    echo
    read -r -p "Or enter full path to ZIP: " custom
    [[ -f "${custom}" ]] || die "File not found: ${custom}"
    echo "${custom}"
    return
  fi

  if [[ ${#zips[@]} -eq 1 ]]; then
    echo "${zips[0]}"
    return
  fi

  echo
  echo -e "${BLD}Found ZIP files in /root:${NC}"
  local i=1
  for z in "${zips[@]}"; do
    local sz
    sz=$(du -h "$z" | awk '{print $1}')
    printf "  %2d) %s  (%s)\n" "$i" "$(basename "$z")" "$sz"
    ((i++))
  done
  echo
  read -r -p "Select ZIP number: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 && "${choice}" -le ${#zips[@]} ]] \
    || die "Invalid selection"
  echo "${zips[$((choice-1))]}"
}

extract_zip_source() {
  local zip_path="$1"
  local tmp="$2"
  unzip -q "${zip_path}" -d "${tmp}"
  if [[ -d "${tmp}/nexus_v36" ]]; then
    echo "${tmp}/nexus_v36"
  elif [[ -d "${tmp}/nexus_bot" ]]; then
    echo "${tmp}/nexus_bot"
  else
    find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1
  fi
}

infer_version_from_zip() {
  local zip_path="$1"
  local base
  base="$(basename "${zip_path}" .zip)"
  if [[ "${base}" =~ [Vv]?([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

do_install_bot() {
  need_root

  if [[ -d "${INSTALL_DIR}" ]] && [[ -f "${INSTALL_DIR}/VERSION" || -f "${INSTALL_DIR}/.env" ]]; then
    warn "Bot appears to be already installed at ${INSTALL_DIR}"
    echo "  Version: $(get_bot_version)"
    confirm "Reinstall / overwrite code? (data & .env will be kept)" || die "Cancelled"
  fi

  local zip_path
  zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found"
  log "Using: ${zip_path}"

  local ver
  ver="$(infer_version_from_zip "${zip_path}")"

  # Dependencies
  log "Installing system dependencies..."
  if has_cmd apt-get; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      python3 python3-venv python3-pip curl unzip tar \
      >/dev/null 2>&1 || warn "Some packages failed to install"
  fi

  # Create user
  if ! id "${SERVICE_USER}" &>/dev/null; then
    log "Creating user ${SERVICE_USER}..."
    useradd --system --home "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}" 2>/dev/null || true
  fi

  mkdir -p "${INSTALL_DIR}"
  local tmp; tmp="$(mktemp -d /tmp/nexus_install_XXXXXX)"
  trap 'rm -rf "'"${tmp}"'"' RETURN

  local src
  src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Could not find source folder inside ZIP"

  log "Installing files to ${INSTALL_DIR}..."
  # Keep existing data
  local keep_env=0 keep_storage=0 keep_data=0
  [[ -f "${INSTALL_DIR}/.env" ]] && keep_env=1
  [[ -d "${INSTALL_DIR}/storage" ]] && keep_storage=1
  [[ -d "${INSTALL_DIR}/data" ]] && keep_data=1

  # Copy code
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' \
    -exec rm -rf {} + 2>/dev/null || true

  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups" "${INSTALL_DIR}/data"

  # VERSION
  if [[ -n "${ver}" ]]; then
    echo "${ver}" > "${INSTALL_DIR}/VERSION"
  elif [[ ! -f "${INSTALL_DIR}/VERSION" ]]; then
    echo "unknown" > "${INSTALL_DIR}/VERSION"
  fi

  # .env
  if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    if [[ -f "${INSTALL_DIR}/.env.example" ]]; then
      cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
      warn ".env created from example — edit it before starting"
    else
      warn "No .env found — create ${INSTALL_DIR}/.env manually"
    fi
  else
    ok ".env preserved"
  fi

  # venv
  if [[ ! -d "${INSTALL_DIR}/.venv" ]]; then
    log "Creating Python venv..."
    python3 -m venv "${INSTALL_DIR}/.venv"
  fi
  log "Installing Python packages..."
  "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip -q
  if [[ -f "${INSTALL_DIR}/requirements.txt" ]]; then
    "${INSTALL_DIR}/.venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt" -q
  elif [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]]; then
    "${INSTALL_DIR}/.venv/bin/pip" install -r "${INSTALL_DIR}/deploy/requirements.txt" -q
  fi

  # systemd
  if [[ -f "${INSTALL_DIR}/deploy/systemd.service" ]]; then
    log "Installing systemd unit..."
    cp -a "${INSTALL_DIR}/deploy/systemd.service" "/etc/systemd/system/${SERVICE_NAME}.service"
    # fix paths if needed
    sed -i "s|/opt/nexusnet|${INSTALL_DIR}|g" "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "systemd unit installed"
  else
    warn "deploy/systemd.service not found — configure service manually"
  fi

  fix_perms
  run_preflight || true

  echo
  ok "Install complete"
  echo -e "  Path    : ${INSTALL_DIR}"
  echo -e "  Version : ${BLD}$(get_bot_version)${NC}"
  echo
  info "Next steps:"
  echo "  1. Edit ${INSTALL_DIR}/.env  (BOT_TOKEN, CREDENTIAL_ENCRYPTION_KEY, ...)"
  echo "  2. sudo ${CMD_NAME}  ->  Service Management  ->  Start"
  echo "  or: sudo systemctl start ${SERVICE_NAME}"
}

# ======================== Update Bot (local ZIP only) ========================
do_update_bot() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed. Use option 1 first."

  local current
  current="$(get_bot_version)"
  info "Installed version: ${current}"

  local zip_path
  zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found"
  log "Using: ${zip_path}"

  local new_ver
  new_ver="$(infer_version_from_zip "${zip_path}")"
  [[ -n "${new_ver}" ]] && info "Target version: ${new_ver}"

  confirm "Update bot from $(basename "${zip_path}")?" || die "Cancelled"

  log "Creating pre-update backup..."
  ASSUME_YES=1 do_backup full >/dev/null || true

  local rollback_dir="${BACKUP_ROOT}/rollback-$(stamp)"
  mkdir -p "${rollback_dir}"
  rsync -a --exclude='.venv' --exclude='storage' --exclude='data' --exclude='backups' \
    "${INSTALL_DIR}/" "${rollback_dir}/code/" 2>/dev/null || true
  [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${rollback_dir}/.env"

  service_stop

  local tmp; tmp="$(mktemp -d /tmp/nexus_update_XXXXXX)"
  trap 'rm -rf "'"${tmp}"'"' RETURN

  local src
  src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Source folder not found in ZIP"

  log "Installing new version..."
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' \
    -exec rm -rf {} + 2>/dev/null || true

  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"

  if [[ ! -f "${INSTALL_DIR}/.env" && -f "${rollback_dir}/.env" ]]; then
    cp -a "${rollback_dir}/.env" "${INSTALL_DIR}/.env"
  fi

  if [[ -n "${new_ver}" ]]; then
    echo "${new_ver}" > "${INSTALL_DIR}/VERSION"
  fi

  # Refresh deps if requirements changed
  if [[ -f "${INSTALL_DIR}/requirements.txt" ]] || [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]]; then
    log "Updating Python packages..."
    local req="${INSTALL_DIR}/requirements.txt"
    [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
    "${INSTALL_DIR}/.venv/bin/pip" install -r "${req}" -q 2>/dev/null || true
  fi

  fix_perms
  run_preflight || warn "Preflight failed"

  local installed_ver
  installed_ver="$(get_bot_version)"

  if service_start; then
    echo
    ok "Update successful!"
    echo -e "  Previous : ${current}"
    echo -e "  Current  : ${BLD}${installed_ver}${NC}"
    echo
    # keep only last 3 rollbacks
    ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
  else
    err "Service failed after update"
    if confirm "Rollback to previous version?"; then
      do_rollback "${rollback_dir}"
    fi
  fi
}

do_rollback() {
  need_root
  local rb_dir="${1:-}"
  if [[ -z "${rb_dir}" ]]; then
    local points=()
    local i=1
    echo
    echo -e "${BLD}Rollback points:${NC}"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      points+=("$p")
      printf "  %2d) %s\n" "$i" "$(basename "$p")"
      ((i++))
    done < <(ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null)
    [[ ${#points[@]} -gt 0 ]] || die "No rollback points"
    read -r -p "Select: " choice
    rb_dir="${points[$((choice-1))]}"
  fi
  [[ -d "${rb_dir}" ]] || die "Not found"
  confirm "Rollback from $(basename "${rb_dir}")?" || die "Cancelled"

  service_stop
  if [[ -d "${rb_dir}/code" ]]; then
    find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
      ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' \
      -exec rm -rf {} + 2>/dev/null || true
    cp -a "${rb_dir}/code/." "${INSTALL_DIR}/"
  fi
  [[ -f "${rb_dir}/.env" ]] && cp -a "${rb_dir}/.env" "${INSTALL_DIR}/.env"
  fix_perms
  service_start
  ok "Rollback done — version: $(get_bot_version)"
}

# ======================== Update Manager (GitHub) ========================
do_update_manager() {
  need_root
  log "Checking GitHub for manager updates..."
  local url="https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/nexus.sh"
  local tmp
  tmp="$(mktemp /tmp/nexus_mgr_XXXXXX.sh)"
  if ! curl -fsSL -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    die "Failed to download manager from GitHub"
  fi

  local remote_ver local_ver
  remote_ver="$(grep -oP 'MANAGER_VERSION="\K[^"]+' "${tmp}" 2>/dev/null || echo "unknown")"
  local_ver="${MANAGER_VERSION}"

  info "Local manager  : ${local_ver}"
  info "Remote manager : ${remote_ver}"

  if [[ "${remote_ver}" == "${local_ver}" ]]; then
    ok "Manager is up to date"
    rm -f "${tmp}"
    return 0
  fi

  confirm "Update manager ${local_ver} -> ${remote_ver}?" || { rm -f "${tmp}"; die "Cancelled"; }

  local dest="/usr/local/bin/${CMD_NAME}"
  cp "${tmp}" "${dest}"
  chmod +x "${dest}"
  [[ -d "${INSTALL_DIR}" ]] && cp "${tmp}" "${INSTALL_DIR}/nexus.sh" && chmod +x "${INSTALL_DIR}/nexus.sh"
  rm -f "${tmp}"
  ok "Manager updated to ${remote_ver}"
  info "Restart the menu to use the new version: sudo ${CMD_NAME}"
}

# ======================== Service menu ========================
do_service_menu() {
  while true; do
    echo
    echo -e "${BLD}Service Management${NC}"
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Status"
    echo "  5) Logs (last 80)"
    echo "  6) Follow logs"
    echo "  0) Back"
    read -r -p "Choice: " c
    case "${c}" in
      1) need_root; service_start; pause ;;
      2) need_root; service_stop; pause ;;
      3) need_root; service_restart; pause ;;
      4)
        echo "Install : ${INSTALL_DIR}"
        echo "Version : $(get_bot_version)"
        if has_service; then
          systemctl --no-pager -l status "${SERVICE_NAME}" || true
        else
          warn "No systemd unit"
        fi
        pause
        ;;
      5) journalctl -u "${SERVICE_NAME}" -n 80 --no-pager; pause ;;
      6) journalctl -u "${SERVICE_NAME}" -f ;;
      0) break ;;
      *) warn "Invalid" ;;
    esac
  done
}

# ======================== Doctor ========================
do_doctor() {
  need_root
  local fail=0
  echo
  echo -e "${BLD}── Diagnostics ─────────────────────────${NC}"
  echo "  OS      : $(uname -srm)"
  echo "  Manager : ${MANAGER_VERSION}"
  echo "  Bot     : $(get_bot_version)"
  echo "  Path    : ${INSTALL_DIR}"

  [[ -d "${INSTALL_DIR}" ]] && ok "Install dir exists" || { err "Install dir missing"; fail=1; }

  if [[ -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
    ok "Python venv ($("${INSTALL_DIR}/.venv/bin/python" --version 2>&1))"
  else
    err "Python venv missing"; fail=1
  fi

  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    ok ".env exists"
    grep -qE '^BOT_TOKEN=.+' "${INSTALL_DIR}/.env" 2>/dev/null && ok "BOT_TOKEN set" || warn "BOT_TOKEN empty/missing"
    grep -qE '^CREDENTIAL_ENCRYPTION_KEY=.+' "${INSTALL_DIR}/.env" 2>/dev/null \
      && ok "CREDENTIAL_ENCRYPTION_KEY set" || warn "CREDENTIAL_ENCRYPTION_KEY empty"
  else
    err ".env missing"; fail=1
  fi

  if [[ -f "${INSTALL_DIR}/storage/nexusnet.db" ]]; then
    ok "SQLite DB present ($(du -h "${INSTALL_DIR}/storage/nexusnet.db" | awk '{print $1}'))"
  else
    info "No nexusnet.db under storage/ (first run or custom path)"
  fi

  if has_service; then
    systemctl is-active --quiet "${SERVICE_NAME}" && ok "Service active" || { err "Service not active"; fail=1; }
  else
    warn "No systemd unit"
  fi

  run_preflight || fail=1

  echo
  if [[ "${fail}" -eq 0 ]]; then
    ok "All critical checks passed"
  else
    err "Some checks failed"
  fi
}

# ======================== Uninstall ========================
do_uninstall() {
  need_root
  echo
  echo -e "${BLD}Uninstall${NC}"
  echo "  1) Remove bot (keep backups)"
  echo "  2) Remove bot + service (keep backups)"
  echo "  3) Remove everything including backups"
  echo "  0) Cancel"
  read -r -p "Choice: " c
  case "${c}" in
    1)
      confirm "Remove application files?" || die "Cancelled"
      service_stop
      rm -rf "${INSTALL_DIR}"
      ok "Removed. Backups kept in ${BACKUP_ROOT}"
      ;;
    2)
      confirm "Remove application + service?" || die "Cancelled"
      service_stop
      systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      rm -rf "${INSTALL_DIR}"
      ok "Removed. Backups kept."
      ;;
    3)
      confirm "WARNING: Delete EVERYTHING including backups?" || die "Cancelled"
      confirm "Really sure?" || die "Cancelled"
      service_stop
      systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      rm -rf "${INSTALL_DIR}" "${BACKUP_ROOT}"
      ok "Everything removed"
      ;;
    0) return ;;
  esac
}

# ======================== Menu ========================
show_banner() {
  clear 2>/dev/null || true
  echo -e "${CYN}"
  cat << 'BANNER'
╔══════════════════════════════════════════════════╗
║              NexusNet Bot Manager                ║
╚══════════════════════════════════════════════════╝
BANNER
  echo -e "${NC}"
  echo -e "  Manager : ${MANAGER_VERSION}"
  echo -e "  Bot     : $(get_bot_version)"
  echo -e "  Path    : ${INSTALL_DIR}"
  echo
}

main_menu() {
  while true; do
    show_banner
    echo -e "  ${BLD}1)${NC} Install Bot"
    echo -e "  ${BLD}2)${NC} Update Manager (GitHub)"
    echo -e "  ${BLD}3)${NC} Update Bot (local ZIP)"
    echo -e "  ${BLD}4)${NC} Backup"
    echo -e "  ${BLD}5)${NC} Restore"
    echo -e "  ${BLD}6)${NC} Service Management"
    echo -e "  ${BLD}7)${NC} Diagnostics"
    echo -e "  ${BLD}8)${NC} Uninstall"
    echo -e "  ${BLD}0)${NC} Exit"
    echo
    read -r -p "  Select: " choice
    echo
    case "${choice}" in
      1) do_install_bot; pause ;;
      2) do_update_manager; pause ;;
      3) do_update_bot; pause ;;
      4)
        echo "  1) Full   2) Database only"
        read -r -p "Choice [1]: " bt
        case "${bt:-1}" in 2) do_backup db ;; *) do_backup full ;; esac
        pause
        ;;
      5) do_restore; pause ;;
      6) do_service_menu ;;
      7) do_doctor; pause ;;
      8) do_uninstall; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "Invalid choice"; sleep 1 ;;
    esac
  done
}

usage() {
  cat << EOF
NexusNet Bot Manager v${MANAGER_VERSION}

Usage:
  ${CMD_NAME}                 Interactive menu
  sudo ${CMD_NAME} <cmd>      Command mode

Commands:
  install         Install bot from local ZIP in /root
  update          Update bot from local ZIP
  update-manager  Update this manager from GitHub
  backup [full|db]
  restore [path]
  rollback
  start|stop|restart|status|logs
  doctor
  uninstall

Bot ZIP: place file in /root (e.g. NexusNet-V1.3.2.zip)
EOF
}

# ======================== Entry ========================
cmd="${1:-}"
shift || true

case "${cmd}" in
  "")              main_menu ;;
  install)         do_install_bot ;;
  update)          do_update_bot ;;
  update-manager)  do_update_manager ;;
  backup)          do_backup "${1:-full}" ;;
  restore)         do_restore "${1:-}" ;;
  rollback)        do_rollback "${1:-}" ;;
  start)           need_root; service_start ;;
  stop)            need_root; service_stop ;;
  restart)         need_root; service_restart ;;
  status)
    echo "Bot     : $(get_bot_version)"
    echo "Manager : ${MANAGER_VERSION}"
    echo "Path    : ${INSTALL_DIR}"
    has_service && systemctl --no-pager -l status "${SERVICE_NAME}" || true
    ;;
  logs)            journalctl -u "${SERVICE_NAME}" -n "${1:-80}" --no-pager ;;
  doctor)          do_doctor ;;
  uninstall)       do_uninstall ;;
  -h|--help|help)  usage ;;
  *)               die "Unknown command: ${cmd} (try: help)" ;;
esac
