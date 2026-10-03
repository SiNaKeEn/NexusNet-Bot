#!/usr/bin/env bash
# =============================================================================
# NexusNet Bot Manager v1.1.0
# Command: nexusnetmanager
# Bot updates: local ZIP in /root only
# Manager updates: GitHub Manager branch
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
MANAGER_VERSION="1.1.0"

# Colors (match NexusNet Node style)
CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
YLW=$'\033[1;33m'
BLU=$'\033[1;34m'
DIM=$'\033[2m'
BLD=$'\033[1m'
NC=$'\033[0m'

log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "${BLU}[i]${NC} $*"; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root: sudo ${CMD_NAME}"
}

stamp() { date +%Y%m%d_%H%M%S; }

confirm() {
  local msg="${1:-Continue?}"
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  read -r -p "$(echo -e "${YLW}${msg} [y/N] ${NC}")" ans
  [[ "${ans}" == "y" || "${ans}" == "Y" || "${ans}" == "yes" ]]
}

pause() {
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  read -r -p "Press Enter to continue..."
}

has_cmd() { command -v "$1" &>/dev/null; }

# ======================== Service helpers ========================
has_service() {
  systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE_NAME}\.service" \
    || [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]
}

service_is_active() {
  has_service && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null
}

service_stop() {
  if service_is_active; then
    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" || warn "stop failed"
  fi
}

service_start() {
  if has_service; then
    log "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}"
    sleep 2
    if service_is_active; then
      ok "Service started"
      return 0
    fi
    err "Service failed to start"
    systemctl --no-pager -l status "${SERVICE_NAME}" 2>/dev/null || true
    return 1
  fi
  warn "No systemd unit found"
  return 1
}

service_restart() {
  has_service || { warn "No systemd unit"; return 1; }
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  systemctl --no-pager -l status "${SERVICE_NAME}" 2>/dev/null || true
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

get_service_status() {
  if service_is_active; then
    echo -e "${GREEN}Active${NC}"
  elif has_service; then
    echo -e "${RED}Stopped${NC}"
  elif [[ -d "${INSTALL_DIR}" ]]; then
    echo -e "${YLW}No service${NC}"
  else
    echo -e "${DIM}Not installed${NC}"
  fi
}

# ======================== ZIP helpers ========================
find_local_zips() {
  # Broad search in /root (maxdepth 2) for bot packages
  find /root -maxdepth 2 -type f -iname '*.zip' 2>/dev/null | while read -r f; do
    local base
    base="$(basename "$f")"
    # skip our own manager package names if needed, still show all for user choice
    echo "$f"
  done | sort -r
}

infer_version_from_name() {
  local name="$1"
  if [[ "${name}" =~ [Vv]([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${name}" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

pick_zip() {
  local zips=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && zips+=("$f")
  done < <(find /root -maxdepth 2 -type f -iname '*.zip' 2>/dev/null | sort -r)

  echo
  if [[ ${#zips[@]} -eq 0 ]]; then
    warn "No .zip files found under /root"
    echo "  Checked: /root and /root/* (maxdepth 2)"
    echo "  Upload example:"
    echo "    scp NexusNet-V1.3.2.zip root@SERVER:/root/"
    echo
    # show what is actually in /root
    log "Files currently in /root:"
    ls -lah /root 2>/dev/null | head -30 || true
    echo
    read -r -p "Enter full path to bot ZIP: " custom
    custom="${custom//$'\r'/}"
    custom="${custom//\"/}"
    custom="${custom//\'/}"
    [[ -f "${custom}" ]] || die "File not found: ${custom}"
    printf '%s\n' "${custom}"
    return
  fi

  echo -e "${CYAN}ZIP files found:${NC}"
  echo -e "${DIM}────────────────────────────────────────${NC}"
  local i=1
  for z in "${zips[@]}"; do
    local sz ver base
    base="$(basename "$z")"
    sz=$(du -h "$z" 2>/dev/null | awk '{print $1}')
    ver="$(infer_version_from_name "$base")"
    printf "  ${GREEN}[%d]${NC}  %s  ${DIM}(%s)${NC}" "$i" "$base" "${sz:-?}"
    [[ -n "$ver" ]] && printf "  v%s" "$ver"
    printf "\n      ${DIM}%s${NC}\n" "$z"
    ((i++)) || true
  done
  echo -e "${DIM}────────────────────────────────────────${NC}"
  echo
  echo "Enter list number, or full path to a ZIP file."
  read -r -p "Select [1-${#zips[@]}] or path: " choice
  choice="${choice//$'\r'/}"
  choice="${choice//\"/}"
  choice="${choice//\'/}"

  # path typed directly
  if [[ -f "${choice}" ]]; then
    printf '%s\n' "${choice}"
    return
  fi

  # number
  if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 && "${choice}" -le ${#zips[@]} ]]; then
    printf '%s\n' "${zips[$((choice-1))]}"
    return
  fi

  die "Invalid selection: ${choice}"
}

extract_zip_source() {
  local zip_path="$1" tmp="$2"
  unzip -q "${zip_path}" -d "${tmp}"
  if [[ -d "${tmp}/nexus_v36" ]]; then echo "${tmp}/nexus_v36"
  elif [[ -d "${tmp}/nexus_bot" ]]; then echo "${tmp}/nexus_bot"
  else find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1
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
      [[ -d "${INSTALL_DIR}/data" ]] && cp -a "${INSTALL_DIR}/data" "${dest}/data"
      ;;
    db)
      mkdir -p "${dest}/database"
      find "${INSTALL_DIR}/storage" -maxdepth 2 \( -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' \) \
        -exec cp -a {} "${dest}/database/" \; 2>/dev/null || true
      if [[ ! "$(ls -A "${dest}/database" 2>/dev/null)" ]] && [[ -d "${INSTALL_DIR}/storage" ]]; then
        cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
      fi
      ;;
    *) die "Unknown mode (full|db)" ;;
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
  fi
  echo "${tar_path}"
}

# ======================== Restore ========================
do_restore() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"

  local src="${1:-}"
  if [[ -z "${src}" ]]; then
    local backups=()
    local i=1
    echo
    echo -e "${CYAN}Available backups:${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      backups+=("$b")
      local name ver="?"
      name=$(basename "$b")
      [[ -f "${b}/meta.txt" ]] && ver=$(grep '^version=' "${b}/meta.txt" 2>/dev/null | cut -d= -f2)
      printf "  ${GREEN}[%d]${NC}  %s  ${DIM}(v%s)${NC}\n" "$i" "$name" "$ver"
      ((i++))
    done < <(ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | head -15)
    echo -e "${DIM}────────────────────────────────────────${NC}"
    [[ ${#backups[@]} -gt 0 ]] || die "No backups found"
    echo
    read -r -p "Select number: " choice
    choice="${choice//$'\r'/}"
    [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 && "${choice}" -le ${#backups[@]} ]] || die "Invalid"
    src="${backups[$((choice-1))]}"
  fi

  local work="${src}" tmp=""
  if [[ -f "${src}" && "${src}" == *.tar.gz ]]; then
    tmp="$(mktemp -d /tmp/nexus_restore_XXXXXX)"
    tar -xzf "${src}" -C "${tmp}"
    work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${work}" ]] || die "Backup not found"

  info "Restore from: $(basename "${work}")"
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
do_install_bot() {
  need_root

  if [[ -d "${INSTALL_DIR}" ]] && [[ -f "${INSTALL_DIR}/VERSION" || -f "${INSTALL_DIR}/.env" ]]; then
    warn "Bot already installed (v$(get_bot_version))"
    confirm "Reinstall code? (.env and data will be kept)" || die "Cancelled"
  fi

  local zip_path
  zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found: ${zip_path}"
  log "ZIP: ${zip_path}"

  local ver
  ver="$(infer_version_from_name "$(basename "${zip_path}")")"

  log "Installing dependencies..."
  if has_cmd apt-get; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      python3 python3-venv python3-pip curl unzip tar >/dev/null 2>&1 || true
  fi

  if ! id "${SERVICE_USER}" &>/dev/null; then
    useradd --system --home "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}" 2>/dev/null || true
  fi

  mkdir -p "${INSTALL_DIR}"
  local tmp; tmp="$(mktemp -d /tmp/nexus_install_XXXXXX)"
  trap 'rm -rf "'"${tmp}"'"' RETURN

  local src
  src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Cannot find source folder inside ZIP"

  log "Copying files to ${INSTALL_DIR}..."
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' \
    -exec rm -rf {} + 2>/dev/null || true
  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups" "${INSTALL_DIR}/data"

  if [[ -n "${ver}" ]]; then
    echo "${ver}" > "${INSTALL_DIR}/VERSION"
  elif [[ ! -f "${INSTALL_DIR}/VERSION" ]]; then
    echo "unknown" > "${INSTALL_DIR}/VERSION"
  fi

  if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    if [[ -f "${INSTALL_DIR}/.env.example" ]]; then
      cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
      warn ".env created from example — edit before start"
    else
      warn "Create ${INSTALL_DIR}/.env manually"
    fi
  else
    ok ".env preserved"
  fi

  if [[ ! -d "${INSTALL_DIR}/.venv" ]]; then
    log "Creating Python venv..."
    python3 -m venv "${INSTALL_DIR}/.venv"
  fi
  log "Installing Python packages..."
  "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip -q
  local req=""
  [[ -f "${INSTALL_DIR}/requirements.txt" ]] && req="${INSTALL_DIR}/requirements.txt"
  [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
  [[ -n "${req}" ]] && "${INSTALL_DIR}/.venv/bin/pip" install -r "${req}" -q

  if [[ -f "${INSTALL_DIR}/deploy/systemd.service" ]]; then
    log "Installing systemd unit..."
    cp -a "${INSTALL_DIR}/deploy/systemd.service" "/etc/systemd/system/${SERVICE_NAME}.service"
    sed -i "s|/opt/nexusnet|${INSTALL_DIR}|g" "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "systemd unit installed"
  else
    warn "deploy/systemd.service not found"
  fi

  fix_perms
  run_preflight || true

  echo
  ok "Install complete"
  echo -e "  Path    : ${INSTALL_DIR}"
  echo -e "  Version : ${GREEN}$(get_bot_version)${NC}"
  echo
  info "Next: edit ${INSTALL_DIR}/.env then start the service (menu 6)"
}

# ======================== Update Bot ========================
do_update_bot() {
  need_root
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed. Use [1] Install Bot first."

  local current
  current="$(get_bot_version)"
  info "Installed version: ${current}"

  local zip_path
  zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found: ${zip_path}"
  log "ZIP: ${zip_path}"

  local new_ver
  new_ver="$(infer_version_from_name "$(basename "${zip_path}")")"
  [[ -n "${new_ver}" ]] && info "Detected version: ${new_ver}"

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

  log "Installing new files..."
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' \
    -exec rm -rf {} + 2>/dev/null || true
  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"

  [[ ! -f "${INSTALL_DIR}/.env" && -f "${rollback_dir}/.env" ]] && cp -a "${rollback_dir}/.env" "${INSTALL_DIR}/.env"
  [[ -n "${new_ver}" ]] && echo "${new_ver}" > "${INSTALL_DIR}/VERSION"

  local req=""
  [[ -f "${INSTALL_DIR}/requirements.txt" ]] && req="${INSTALL_DIR}/requirements.txt"
  [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
  if [[ -n "${req}" && -x "${INSTALL_DIR}/.venv/bin/pip" ]]; then
    log "Updating Python packages..."
    "${INSTALL_DIR}/.venv/bin/pip" install -r "${req}" -q 2>/dev/null || true
  fi

  fix_perms
  run_preflight || warn "Preflight failed"

  local installed_ver
  installed_ver="$(get_bot_version)"

  if service_start; then
    echo
    ok "Update successful"
    echo -e "  Previous : ${current}"
    echo -e "  Current  : ${GREEN}${installed_ver}${NC}"
    ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
  else
    err "Service failed after update"
    if confirm "Rollback?"; then
      do_rollback "${rollback_dir}"
    fi
  fi
}

do_rollback() {
  need_root
  local rb_dir="${1:-}"
  if [[ -z "${rb_dir}" ]]; then
    local points=() i=1
    echo
    echo -e "${CYAN}Rollback points:${NC}"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      points+=("$p")
      printf "  ${GREEN}[%d]${NC}  %s\n" "$i" "$(basename "$p")"
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

# ======================== Update Manager ========================
do_update_manager() {
  need_root
  log "Checking GitHub for manager updates..."
  local url="https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/nexus.sh"
  local tmp; tmp="$(mktemp /tmp/nexus_mgr_XXXXXX.sh)"
  if ! curl -fsSL -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    die "Download failed"
  fi

  local remote_ver
  remote_ver="$(grep -oP 'MANAGER_VERSION="\K[^"]+' "${tmp}" 2>/dev/null || echo "unknown")"
  info "Local  : ${MANAGER_VERSION}"
  info "Remote : ${remote_ver}"

  if [[ "${remote_ver}" == "${MANAGER_VERSION}" ]]; then
    ok "Manager is up to date"
    rm -f "${tmp}"
    return 0
  fi

  confirm "Update manager ${MANAGER_VERSION} -> ${remote_ver}?" || { rm -f "${tmp}"; return 0; }

  cp "${tmp}" "/usr/local/bin/${CMD_NAME}"
  chmod +x "/usr/local/bin/${CMD_NAME}"
  rm -f "${tmp}"
  ok "Manager updated to ${remote_ver}"
  info "Run again: sudo ${CMD_NAME}"
}

# ======================== Service menu ========================
do_service_menu() {
  while true; do
    echo
    echo -e "${CYAN}── Service Management ──────────────────${NC}"
    echo -e "  ${GREEN}[1]${NC} » Start"
    echo -e "  ${GREEN}[2]${NC} » Stop"
    echo -e "  ${GREEN}[3]${NC} » Restart"
    echo -e "  ${GREEN}[4]${NC} » Status"
    echo -e "  ${GREEN}[5]${NC} » Logs (last 80)"
    echo -e "  ${GREEN}[6]${NC} » Follow logs"
    echo -e "  ${GREEN}[0]${NC} » Back"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    read -r -p "Enter choice [0-6]: " c
    c="${c//$'\r'/}"
    case "${c}" in
      1) need_root; service_start; pause ;;
      2) need_root; service_stop; pause ;;
      3) need_root; service_restart; pause ;;
      4)
        echo "Bot     : $(get_bot_version)"
        echo "Path    : ${INSTALL_DIR}"
        has_service && systemctl --no-pager -l status "${SERVICE_NAME}" || warn "No unit"
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
  echo -e "${CYAN}── Diagnostics ─────────────────────────${NC}"
  echo "  OS      : $(uname -srm)"
  echo "  Manager : ${MANAGER_VERSION}"
  echo "  Bot     : $(get_bot_version)"
  echo "  Path    : ${INSTALL_DIR}"
  echo

  [[ -d "${INSTALL_DIR}" ]] && ok "Install dir" || { err "Install dir missing"; fail=1; }

  if [[ -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
    ok "Python venv ($("${INSTALL_DIR}/.venv/bin/python" --version 2>&1))"
  else
    err "Python venv missing"; fail=1
  fi

  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    ok ".env exists"
    grep -qE '^BOT_TOKEN=.+' "${INSTALL_DIR}/.env" 2>/dev/null && ok "BOT_TOKEN set" || warn "BOT_TOKEN empty"
    grep -qE '^CREDENTIAL_ENCRYPTION_KEY=.+' "${INSTALL_DIR}/.env" 2>/dev/null \
      && ok "CREDENTIAL_ENCRYPTION_KEY set" || warn "CREDENTIAL_ENCRYPTION_KEY empty"
  else
    err ".env missing"; fail=1
  fi

  if [[ -f "${INSTALL_DIR}/storage/nexusnet.db" ]]; then
    ok "SQLite DB ($(du -h "${INSTALL_DIR}/storage/nexusnet.db" | awk '{print $1}'))"
  else
    info "No nexusnet.db under storage/"
  fi

  if has_service; then
    service_is_active && ok "Service active" || { err "Service not active"; fail=1; }
  else
    warn "No systemd unit"
  fi

  run_preflight || fail=1
  echo
  [[ "${fail}" -eq 0 ]] && ok "All critical checks passed" || err "Some checks failed"
}

# ======================== Uninstall ========================
do_uninstall() {
  need_root
  echo
  echo -e "${CYAN}── Uninstall ───────────────────────────${NC}"
  echo -e "  ${GREEN}[1]${NC} » Remove bot (keep backups)"
  echo -e "  ${GREEN}[2]${NC} » Remove bot + service (keep backups)"
  echo -e "  ${GREEN}[3]${NC} » Remove everything"
  echo -e "  ${GREEN}[0]${NC} » Cancel"
  echo -e "${CYAN}────────────────────────────────────────${NC}"
  read -r -p "Enter choice [0-3]: " c
  c="${c//$'\r'/}"
  case "${c}" in
    1)
      confirm "Remove application files?" || die "Cancelled"
      service_stop; rm -rf "${INSTALL_DIR}"
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

# ======================== Main Menu (Node-style) ========================
show_menu() {
  clear 2>/dev/null || true
  local bot_ver
  bot_ver="$(get_bot_version)"

  echo -e "${CYAN}"
  cat << 'TOP'
╔══════════════════════════════════════════════════╗
║          N E X U S N E T  -  Bot Manager         ║
TOP
  printf "║              Manager %-28s║\n" "v${MANAGER_VERSION}"
  cat << 'MID'
╠══════════════════════════════════════════════════╣
MID
  printf "║  Bot     : %-36s║\n" "${bot_ver}"
  if service_is_active; then
    echo -e "║  Status  : ${GREEN}Active${CYAN}                               ║"
  elif [[ -d "${INSTALL_DIR}" ]]; then
    echo -e "║  Status  : ${YLW}Installed (stopped)${CYAN}                  ║"
  else
    echo -e "║  Status  : ${DIM}Not installed${CYAN}                         ║"
  fi
  cat << 'BODY'
╠══════════════════════════════════════════════════╣
║              SCRIPT MANAGEMENT                   ║
╠══════════════════════════════════════════════════╣
║  [1] » Install Manager                           ║
║  [2] » Update Manager                            ║
║  [3] » Uninstall Manager                         ║
╠══════════════════════════════════════════════════╣
║                 BOT MANAGEMENT                   ║
╠══════════════════════════════════════════════════╣
║  [4] » Install Bot                               ║
║  [5] » Update Bot (local ZIP)                    ║
║  [6] » Backup                                    ║
║  [7] » Restore                                   ║
║  [8] » Service Management                        ║
║  [9] » Diagnostics                               ║
║ [10] » Uninstall Bot                             ║
╠══════════════════════════════════════════════════╣
║  [0] » Exit                                      ║
╚══════════════════════════════════════════════════╝
BODY
  echo -e "${NC}"
}

do_install_manager() {
  need_root
  local dest="/usr/local/bin/${CMD_NAME}"
  if [[ -f "${dest}" ]]; then
    ok "Manager already installed at ${dest}"
    info "Version: ${MANAGER_VERSION}"
    confirm "Reinstall/overwrite?" || return 0
  fi
  # copy self if we know our path
  local self
  self="$(readlink -f "$0" 2>/dev/null || echo "")"
  if [[ -n "${self}" && -f "${self}" ]]; then
    cp "${self}" "${dest}"
    chmod +x "${dest}"
    ok "Manager installed -> ${dest}"
  else
    # fetch from github
    do_update_manager
  fi
}

do_uninstall_manager() {
  need_root
  confirm "Remove manager command (${CMD_NAME})? Bot files stay." || die "Cancelled"
  rm -f "/usr/local/bin/${CMD_NAME}"
  ok "Manager removed. Bot at ${INSTALL_DIR} was not touched."
}

main_menu() {
  while true; do
    show_menu
    read -r -p "Enter choice [0-10]: " choice
    choice="${choice//$'\r'/}"
    echo
    case "${choice}" in
      1) do_install_manager; pause ;;
      2) do_update_manager; pause ;;
      3) do_uninstall_manager; pause ;;
      4) do_install_bot; pause ;;
      5) do_update_bot; pause ;;
      6)
        echo -e "  ${GREEN}[1]${NC} Full backup"
        echo -e "  ${GREEN}[2]${NC} Database only"
        read -r -p "Choice [1]: " bt
        bt="${bt//$'\r'/}"
        case "${bt:-1}" in 2) do_backup db ;; *) do_backup full ;; esac
        pause
        ;;
      7) do_restore; pause ;;
      8) do_service_menu ;;
      9) do_doctor; pause ;;
      10) do_uninstall; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "Invalid choice"; sleep 1 ;;
    esac
  done
}

usage() {
  cat << EOF
NexusNet Bot Manager v${MANAGER_VERSION}

  ${CMD_NAME}                 Interactive menu
  sudo ${CMD_NAME} <cmd>      Command mode

Commands:
  install | update | update-manager
  backup [full|db] | restore [path] | rollback
  start | stop | restart | status | logs
  doctor | uninstall
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
  *)               die "Unknown command: ${cmd}" ;;
esac
