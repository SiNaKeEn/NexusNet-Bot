#!/usr/bin/env bash
# =============================================================================
# NexusNet Bot Manager v1.2.0
# =============================================================================
set -euo pipefail

# Auto-elevate (no need to type sudo)
if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/nexusnet}"
SERVICE_NAME="${SERVICE_NAME:-nexusnet}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/nexusnet-backups}"
MIGRATE_ROOT="${MIGRATE_ROOT:-/root/nexusnet-migrate}"
SERVICE_USER="${SERVICE_USER:-nexusnet}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
ASSUME_YES="${ASSUME_YES:-0}"
CMD_NAME="nexusnetmanager"
MANAGER_VERSION="1.3.0"
MANAGER_BIN="/usr/local/bin/${CMD_NAME}"

CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
YLW=$'\033[1;33m'
BLU=$'\033[1;34m'
DIM=$'\033[2m'
NC=$'\033[0m'

log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "${BLU}[i]${NC} $*"; }

stamp() { date +%Y%m%d_%H%M%S; }

confirm() {
  local msg="${1:-Continue?}"
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  read -r -p "$(echo -e "${YLW}${msg} [y/N] ${NC}")" ans
  [[ "${ans}" == "y" || "${ans}" == "Y" || "${ans}" == "yes" ]]
}

pause() {
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  read -r -p "Press Enter..."
}

has_cmd() { command -v "$1" &>/dev/null; }

_bot_ver_cache=""
get_bot_version() {
  if [[ -z "${_bot_ver_cache}" ]]; then
    if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
      _bot_ver_cache="$(tr -d '[:space:]' < "${INSTALL_DIR}/VERSION")"
    else
      _bot_ver_cache="not installed"
    fi
  fi
  echo "${_bot_ver_cache}"
}

service_active_fast() {
  [[ -f "/run/systemd/units/invocation:${SERVICE_NAME}.service" ]] && return 0
  systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null
}

has_service() {
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] \
    || systemctl cat "${SERVICE_NAME}" &>/dev/null
}

service_stop() {
  if service_active_fast; then
    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  fi
}

service_start() {
  if has_service; then
    log "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}"
    sleep 1
    if service_active_fast; then
      ok "Service started"
      return 0
    fi
    err "Service failed to start"
    return 1
  fi
  warn "No systemd unit"
  return 1
}

service_restart() {
  has_service || { warn "No systemd unit"; return 1; }
  systemctl restart "${SERVICE_NAME}"
  sleep 1
  service_active_fast && ok "Restarted" || err "Restart failed"
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
    log "Preflight..."
    "${py}" "${pf}" || { warn "Preflight problems"; return 1; }
    ok "Preflight OK"
  fi
  return 0
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

# UI goes to stderr so $(pick_zip) only captures the path
_ui() { echo -e "$@" >&2; }

resolve_zip_path() {
  local input="$1"
  input="${input//$'\r'/}"
  input="${input//\"/}"
  input="${input//\'/}"
  # trim spaces
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  [[ -z "${input}" ]] && return 1

  [[ -f "${input}" ]] && { printf '%s\n' "${input}"; return 0; }
  [[ -f "/root/${input}" ]] && { printf '%s\n' "/root/${input}"; return 0; }
  [[ -f "/root/${input}.zip" ]] && { printf '%s\n' "/root/${input}.zip"; return 0; }

  # try with NexusNet- prefix / V prefix variants
  local candidates=(
    "/root/${input}"
    "/root/${input}.zip"
    "/root/NexusNet-${input}.zip"
    "/root/NexusNet-V${input}.zip"
    "/root/NexusNet-v${input}.zip"
    "/root/NexusNet-V${input}"
    "/root/NexusNet-v${input}"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done

  local found
  found="$(find /root -maxdepth 3 -type f -iname "${input}" 2>/dev/null | head -1)"
  [[ -n "${found}" && -f "${found}" ]] && { printf '%s\n' "${found}"; return 0; }
  found="$(find /root -maxdepth 3 -type f -iname "${input}.zip" 2>/dev/null | head -1)"
  [[ -n "${found}" && -f "${found}" ]] && { printf '%s\n' "${found}"; return 0; }
  found="$(find /root -maxdepth 3 -type f -iname "*${input}*.zip" 2>/dev/null | head -1)"
  [[ -n "${found}" && -f "${found}" ]] && { printf '%s\n' "${found}"; return 0; }
  return 1
}

list_root_zips() {
  find /root -maxdepth 3 -type f -iname '*.zip' 2>/dev/null | sort -r
}

pick_zip() {
  # ALL user interaction on stderr; ONLY final path on stdout
  _ui ""
  _ui "${CYAN}Select bot ZIP${NC}"
  _ui "  ${GREEN}[1]${NC} Type filename / path / version (e.g. 1.3.2 or NexusNet-V1.3.2.zip)"
  _ui "  ${GREEN}[2]${NC} Scan /root and pick from list"
  _ui ""
  local mode name path choice
  read -r -p "$(echo -e "${YLW}Choice [1]: ${NC}")" mode >&2 || true
  mode="${mode//$'\r'/}"
  mode="${mode:-1}"

  # If user typed a path/version instead of 1/2, treat as mode 1 input
  if [[ "${mode}" != "1" && "${mode}" != "2" ]]; then
    name="${mode}"
    if path="$(resolve_zip_path "${name}")"; then
      _ui "${GREEN}[+]${NC} Using: ${path}"
      printf '%s\n' "${path}"
      return 0
    fi
    _ui "${RED}[-]${NC} Not found from input: ${name}"
    mode="2"
  fi

  if [[ "${mode}" == "1" ]]; then
    _ui "Examples: NexusNet-V1.3.2.zip | 1.3.2 | /root/NexusNet-V1.3.2.zip"
    read -r -p "$(echo -e "${YLW}Filename / path / version: ${NC}")" name >&2 || true
    name="${name//$'\r'/}"
    if path="$(resolve_zip_path "${name}")"; then
      _ui "${GREEN}[+]${NC} Using: ${path}"
      printf '%s\n' "${path}"
      return 0
    fi
    _ui "${RED}[-]${NC} Not found: ${name}"
    _ui "${CYAN}[*]${NC} Listing /root *.zip ..."
    list_root_zips >&2 || true
    ls -lah /root >&2 2>/dev/null | head -30 || true
    die "File not found"
  fi

  # mode 2 — list
  local zips=() f
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && zips+=("$f")
  done < <(list_root_zips)

  if [[ ${#zips[@]} -eq 0 ]]; then
    _ui "${YLW}[!]${NC} No .zip found under /root"
    ls -lah /root >&2 2>/dev/null | head -40 || true
    read -r -p "$(echo -e "${YLW}Full path to ZIP: ${NC}")" name >&2 || true
    path="$(resolve_zip_path "${name}")" || die "Not found: ${name}"
    _ui "${GREEN}[+]${NC} Using: ${path}"
    printf '%s\n' "${path}"
    return 0
  fi

  _ui ""
  _ui "${CYAN}ZIP files found:${NC}"
  _ui "${DIM}----------------------------------------${NC}"
  local i=1 base sz ver
  for z in "${zips[@]}"; do
    base="$(basename "$z")"
    sz=$(du -h "$z" 2>/dev/null | awk '{print $1}')
    ver="$(infer_version_from_name "$base")"
    _ui "  ${GREEN}[${i}]${NC}  ${base}  ${DIM}(${sz:-?})${NC}${ver:+  v${ver}}"
    _ui "      ${DIM}${z}${NC}"
    ((i++)) || true
  done
  _ui "${DIM}----------------------------------------${NC}"
  read -r -p "$(echo -e "${YLW}Select number: ${NC}")" choice >&2 || true
  choice="${choice//$'\r'/}"
  [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 && "${choice}" -le ${#zips[@]} ]] \
    || die "Invalid number"
  path="${zips[$((choice-1))]}"
  _ui "${GREEN}[+]${NC} Using: ${path}"
  printf '%s\n' "${path}"
}

extract_zip_source() {
  local zip_path="$1" tmp="$2"
  unzip -q "${zip_path}" -d "${tmp}"
  if [[ -d "${tmp}/nexus_v36" ]]; then echo "${tmp}/nexus_v36"
  elif [[ -d "${tmp}/nexus_bot" ]]; then echo "${tmp}/nexus_bot"
  else find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1
  fi
}

do_backup() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  local mode="${1:-full}" ts dest
  ts="$(stamp)"; dest="${BACKUP_ROOT}/${ts}"; mkdir -p "${dest}"
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
      ;;
  esac
  { echo "timestamp=${ts}"; echo "version=$(get_bot_version)"; echo "mode=${mode}"; } > "${dest}/meta.txt"
  mkdir -p "${BACKUP_ROOT}"
  local tar_path="${BACKUP_ROOT}/nexusnet-backup-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${BACKUP_ROOT}" "${ts}"
  ok "Archive: ${tar_path}"
  local n; n="$(ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${n}" -gt "${KEEP_BACKUPS}" ]]; then
    ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
  fi
  echo "${tar_path}"
}

do_restore() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  local src="${1:-}"
  if [[ -z "${src}" ]]; then
    local backups=() i=1
    echo; echo -e "${CYAN}Backups:${NC}"
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      backups+=("$b")
      local ver="?"; [[ -f "${b}/meta.txt" ]] && ver=$(grep '^version=' "${b}/meta.txt" 2>/dev/null | cut -d= -f2)
      printf "  ${GREEN}[%d]${NC}  %s  ${DIM}(v%s)${NC}\n" "$i" "$(basename "$b")" "$ver"
      ((i++)) || true
    done < <(ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | head -15)
    [[ ${#backups[@]} -gt 0 ]] || die "No backups"
    read -r -p "Select: " choice
    src="${backups[$((choice-1))]}"
  fi
  local work="${src}" tmp=""
  if [[ -f "${src}" && "${src}" == *.tar.gz ]]; then
    tmp="$(mktemp -d /tmp/nexus_restore_XXXXXX)"
    tar -xzf "${src}" -C "${tmp}"
    work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${work}" ]] || die "Backup not found"
  confirm "Restore and stop service?" || die "Cancelled"
  ASSUME_YES=1 do_backup full >/dev/null || true
  service_stop
  [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok ".env"
  if [[ -d "${work}/storage" ]]; then
    rm -rf "${INSTALL_DIR}/storage"; cp -a "${work}/storage" "${INSTALL_DIR}/storage"; ok "storage"
  elif [[ -d "${work}/database" ]]; then
    mkdir -p "${INSTALL_DIR}/storage"; cp -a "${work}/database/"* "${INSTALL_DIR}/storage/" 2>/dev/null || true; ok "database"
  fi
  fix_perms; service_start
  [[ -n "${tmp}" ]] && rm -rf "${tmp}"
  ok "Restore done"
}

do_install_bot() {
  if [[ -d "${INSTALL_DIR}" ]] && [[ -f "${INSTALL_DIR}/VERSION" || -f "${INSTALL_DIR}/.env" ]]; then
    warn "Bot already installed (v$(get_bot_version))"
    confirm "Reinstall code? (keep .env/data)" || die "Cancelled"
  fi
  local zip_path; zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found"
  log "ZIP: ${zip_path}"
  local ver; ver="$(infer_version_from_name "$(basename "${zip_path}")")"
  log "Dependencies..."
  if has_cmd apt-get; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv python3-pip curl unzip tar >/dev/null 2>&1 || true
  fi
  if ! id "${SERVICE_USER}" &>/dev/null; then
    useradd --system --home "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}" 2>/dev/null || true
  fi
  mkdir -p "${INSTALL_DIR}"
  local tmp; tmp="$(mktemp -d /tmp/nexus_install_XXXXXX)"
  trap 'rm -rf "'"${tmp}"'"' RETURN
  local src; src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Bad ZIP structure"
  log "Installing files..."
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' -exec rm -rf {} + 2>/dev/null || true
  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups" "${INSTALL_DIR}/data"
  [[ -n "${ver}" ]] && echo "${ver}" > "${INSTALL_DIR}/VERSION"
  _bot_ver_cache=""
  if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    [[ -f "${INSTALL_DIR}/.env.example" ]] && cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env" && warn ".env from example"
  else ok ".env kept"; fi
  if [[ ! -d "${INSTALL_DIR}/.venv" ]]; then log "Creating venv..."; python3 -m venv "${INSTALL_DIR}/.venv"; fi
  log "pip install..."
  "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip -q
  local req=""; [[ -f "${INSTALL_DIR}/requirements.txt" ]] && req="${INSTALL_DIR}/requirements.txt"
  [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
  [[ -n "${req}" ]] && "${INSTALL_DIR}/.venv/bin/pip" install -r "${req}" -q
  if [[ -f "${INSTALL_DIR}/deploy/systemd.service" ]]; then
    cp -a "${INSTALL_DIR}/deploy/systemd.service" "/etc/systemd/system/${SERVICE_NAME}.service"
    sed -i "s|/opt/nexusnet|${INSTALL_DIR}|g" "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl daemon-reload; systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "systemd installed"
  fi
  fix_perms
  ok "Install complete — v$(get_bot_version)"
}

do_update_bot() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  local current; current="$(get_bot_version)"
  info "Installed: ${current}"
  local zip_path; zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found"
  log "ZIP: ${zip_path}"
  local new_ver; new_ver="$(infer_version_from_name "$(basename "${zip_path}")")"
  [[ -n "${new_ver}" ]] && info "Target: ${new_ver}"
  confirm "Update from $(basename "${zip_path}")?" || die "Cancelled"
  log "Backup..."; ASSUME_YES=1 do_backup full >/dev/null || true
  local rb="${BACKUP_ROOT}/rollback-$(stamp)"; mkdir -p "${rb}"
  rsync -a --exclude='.venv' --exclude='storage' --exclude='data' --exclude='backups' "${INSTALL_DIR}/" "${rb}/code/" 2>/dev/null || true
  [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${rb}/.env"
  service_stop
  local tmp; tmp="$(mktemp -d /tmp/nexus_update_XXXXXX)"
  trap 'rm -rf "'"${tmp}"'"' RETURN
  local src; src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Bad ZIP"
  log "Replacing code..."
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' -exec rm -rf {} + 2>/dev/null || true
  cp -a "${src}/." "${INSTALL_DIR}/"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"
  [[ ! -f "${INSTALL_DIR}/.env" && -f "${rb}/.env" ]] && cp -a "${rb}/.env" "${INSTALL_DIR}/.env"
  [[ -n "${new_ver}" ]] && echo "${new_ver}" > "${INSTALL_DIR}/VERSION"
  _bot_ver_cache=""
  local req=""; [[ -f "${INSTALL_DIR}/requirements.txt" ]] && req="${INSTALL_DIR}/requirements.txt"
  [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
  [[ -n "${req}" && -x "${INSTALL_DIR}/.venv/bin/pip" ]] && "${INSTALL_DIR}/.venv/bin/pip" install -r "${req}" -q 2>/dev/null || true
  fix_perms; run_preflight || warn "Preflight failed"
  if service_start; then ok "Update OK: ${current} -> $(get_bot_version)"
  else err "Start failed"; confirm "Rollback?" && do_rollback "${rb}"; fi
}

do_rollback() {
  local rb_dir="${1:-}"
  if [[ -z "${rb_dir}" ]]; then
    local points=() i=1
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue; points+=("$p")
      printf "  ${GREEN}[%d]${NC}  %s\n" "$i" "$(basename "$p")"; ((i++)) || true
    done < <(ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null)
    [[ ${#points[@]} -gt 0 ]] || die "No rollback points"
    read -r -p "Select: " c; rb_dir="${points[$((c-1))]}"
  fi
  [[ -d "${rb_dir}" ]] || die "Not found"
  confirm "Rollback?" || die "Cancelled"
  service_stop
  if [[ -d "${rb_dir}/code" ]]; then
    find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'storage' ! -name 'data' ! -name 'backups' ! -name '.venv' -exec rm -rf {} + 2>/dev/null || true
    cp -a "${rb_dir}/code/." "${INSTALL_DIR}/"
  fi
  [[ -f "${rb_dir}/.env" ]] && cp -a "${rb_dir}/.env" "${INSTALL_DIR}/.env"
  _bot_ver_cache=""; fix_perms; service_start
  ok "Rollback done — v$(get_bot_version)"
}

do_install_manager() {
  local self; self="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  cp "${self}" "${MANAGER_BIN}"; chmod +x "${MANAGER_BIN}"
  ok "Manager installed -> ${MANAGER_BIN}"
  info "Run: ${CMD_NAME}"
}

do_update_manager() {
  log "Downloading manager from GitHub..."
  local url="https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/nexus.sh"
  local tmp; tmp="$(mktemp /tmp/nexus_mgr_XXXXXX.sh)"
  if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    die "Download failed: ${url}"
  fi
  grep -q 'MANAGER_VERSION=' "${tmp}" || { rm -f "${tmp}"; die "Invalid manager file"; }
  local remote_ver; remote_ver="$(grep -oP 'MANAGER_VERSION="\K[^"]+' "${tmp}" 2>/dev/null || echo "unknown")"
  info "Local  : ${MANAGER_VERSION}"
  info "Remote : ${remote_ver}"
  if [[ "${remote_ver}" == "${MANAGER_VERSION}" ]]; then
    ok "Already up to date (refreshing binary)"
    cp "${tmp}" "${MANAGER_BIN}"; chmod +x "${MANAGER_BIN}"; rm -f "${tmp}"; return 0
  fi
  confirm "Update manager ${MANAGER_VERSION} -> ${remote_ver}?" || { rm -f "${tmp}"; return 0; }
  cp "${tmp}" "${MANAGER_BIN}"; chmod +x "${MANAGER_BIN}"; rm -f "${tmp}"
  ok "Manager updated to ${remote_ver}"
  info "Restarting menu..."
  exec "${MANAGER_BIN}"
}

do_uninstall_manager() {
  confirm "Remove ${MANAGER_BIN}? (bot stays)" || die "Cancelled"
  rm -f "${MANAGER_BIN}"; ok "Manager removed"
}

do_export_migrate() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  local ts dest tar_path
  ts="$(stamp)"; dest="${MIGRATE_ROOT}/export-${ts}"; mkdir -p "${dest}"
  log "Export migrate package..."
  confirm "Stop service for clean export?" && service_stop || true
  [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${dest}/.env"
  [[ -d "${INSTALL_DIR}/storage" ]] && cp -a "${INSTALL_DIR}/storage" "${dest}/storage"
  [[ -d "${INSTALL_DIR}/data" ]] && cp -a "${INSTALL_DIR}/data" "${dest}/data"
  [[ -f "${INSTALL_DIR}/VERSION" ]] && cp -a "${INSTALL_DIR}/VERSION" "${dest}/VERSION"
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] && cp -a "/etc/systemd/system/${SERVICE_NAME}.service" "${dest}/${SERVICE_NAME}.service"
  { echo "timestamp=${ts}"; echo "version=$(get_bot_version)"; echo "hostname=$(hostname)"; } > "${dest}/meta.txt"
  mkdir -p "${MIGRATE_ROOT}"
  tar_path="${MIGRATE_ROOT}/nexusnet-migrate-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${MIGRATE_ROOT}" "export-${ts}"
  has_service && ! service_active_fast && service_start || true
  ok "Package: ${tar_path}"
  info "Copy to new VPS and use Migrate -> Import"
}

do_import_migrate() {
  [[ -d "${INSTALL_DIR}" ]] || die "Install bot on this server first"
  local src="${1:-}"
  [[ -z "${src}" ]] && read -r -p "Path to migrate .tar.gz: " src
  [[ -f "${src}" ]] || die "Not found: ${src}"
  local tmp work
  tmp="$(mktemp -d /tmp/nexus_mig_XXXXXX)"
  tar -xzf "${src}" -C "${tmp}"
  work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -d "${work}" ]] || die "Bad package"
  [[ -f "${work}/meta.txt" ]] && cat "${work}/meta.txt"
  confirm "Import migration data here?" || die "Cancelled"
  service_stop
  [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok ".env"
  if [[ -d "${work}/storage" ]]; then rm -rf "${INSTALL_DIR}/storage"; cp -a "${work}/storage" "${INSTALL_DIR}/storage"; ok "storage"; fi
  [[ -d "${work}/data" ]] && rm -rf "${INSTALL_DIR}/data" && cp -a "${work}/data" "${INSTALL_DIR}/data" && ok "data"
  if [[ -f "${work}/${SERVICE_NAME}.service" && ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    cp -a "${work}/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload; systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
  fi
  fix_perms; service_start; rm -rf "${tmp}"; ok "Import done"
}

do_migrate_menu() {
  echo; echo -e "${CYAN}-- Migrate VPS --${NC}"
  echo -e "  ${GREEN}[1]${NC} Export package"
  echo -e "  ${GREEN}[2]${NC} Import package"
  echo -e "  ${GREEN}[0]${NC} Back"
  read -r -p "Choice: " c
  case "${c}" in 1) do_export_migrate ;; 2) do_import_migrate ;; esac
}

do_service_menu() {
  while true; do
    echo; echo -e "${CYAN}-- Service --${NC}"
    echo -e "  ${GREEN}[1]${NC} Start  ${GREEN}[2]${NC} Stop  ${GREEN}[3]${NC} Restart"
    echo -e "  ${GREEN}[4]${NC} Status ${GREEN}[5]${NC} Logs  ${GREEN}[6]${NC} Follow  ${GREEN}[0]${NC} Back"
    read -r -p "Choice: " c
    case "${c}" in
      1) service_start; pause ;;
      2) service_stop; pause ;;
      3) service_restart; pause ;;
      4) echo "Bot: $(get_bot_version)"; systemctl --no-pager -l status "${SERVICE_NAME}" 2>/dev/null || true; pause ;;
      5) journalctl -u "${SERVICE_NAME}" -n 80 --no-pager; pause ;;
      6) journalctl -u "${SERVICE_NAME}" -f ;;
      0) break ;;
    esac
  done
}

do_doctor() {
  local fail=0
  echo; echo -e "${CYAN}-- Diagnostics --${NC}"
  echo "  Manager : ${MANAGER_VERSION}   Bot : $(get_bot_version)"
  [[ -d "${INSTALL_DIR}" ]] && ok "Install dir" || { err "Missing"; fail=1; }
  [[ -x "${INSTALL_DIR}/.venv/bin/python" ]] && ok "venv" || { err "venv missing"; fail=1; }
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    ok ".env"
    grep -qE '^BOT_TOKEN=.+' "${INSTALL_DIR}/.env" 2>/dev/null && ok "BOT_TOKEN" || warn "BOT_TOKEN empty"
    grep -qE '^CREDENTIAL_ENCRYPTION_KEY=.+' "${INSTALL_DIR}/.env" 2>/dev/null && ok "CREDENTIAL_ENCRYPTION_KEY" || warn "KEY empty"
  else err ".env missing"; fail=1; fi
  service_active_fast && ok "Service active" || warn "Service not active"
  run_preflight || fail=1
  [[ "${fail}" -eq 0 ]] && ok "OK" || err "Issues found"
}

do_uninstall_bot() {
  echo -e "  ${GREEN}[1]${NC} Bot only  ${GREEN}[2]${NC} Bot+service  ${GREEN}[3]${NC} Everything  ${GREEN}[0]${NC} Cancel"
  read -r -p "Choice: " c
  case "${c}" in
    1) confirm "Remove bot?" || return; service_stop; rm -rf "${INSTALL_DIR}"; ok "Done" ;;
    2) confirm "Remove bot+service?" || return; service_stop; systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
       rm -f "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload; rm -rf "${INSTALL_DIR}"; ok "Done" ;;
    3) confirm "DELETE EVERYTHING?" || return; service_stop; systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
       rm -f "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload
       rm -rf "${INSTALL_DIR}" "${BACKUP_ROOT}" "${MIGRATE_ROOT}"; ok "Done" ;;
  esac
}

show_menu() {
  local bot_ver; bot_ver="$(get_bot_version)"
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║          N E X U S N E T  -  Bot Manager         ║"
  printf "║              Manager v%-27s║\n" "${MANAGER_VERSION}"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  Bot     : %-37s║\n" "${bot_ver}"
  if service_active_fast; then echo -e "║  Status  : ${GREEN}Active${CYAN}                               ║"
  elif [[ -d "${INSTALL_DIR}" ]]; then echo -e "║  Status  : ${YLW}Stopped${CYAN}                              ║"
  else echo -e "║  Status  : ${DIM}Not installed${CYAN}                         ║"; fi
  echo "╠══════════════════════════════════════════════════╣"
  echo "║              SCRIPT MANAGEMENT                   ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  [1] » Install Manager                           ║"
  echo "║  [2] » Update Manager                            ║"
  echo "║  [3] » Uninstall Manager                         ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║                 BOT MANAGEMENT                   ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  [4] » Install Bot                               ║"
  echo "║  [5] » Update Bot (local ZIP)                    ║"
  echo "║  [6] » Backup                                    ║"
  echo "║  [7] » Restore                                   ║"
  echo "║  [8] » Migrate VPS                               ║"
  echo "║  [9] » Service Management                        ║"
  echo "║ [10] » Diagnostics                               ║"
  echo "║ [11] » Uninstall Bot                             ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  [0] » Exit                                      ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

main_menu() {
  while true; do
    show_menu
    read -r -p "Enter choice [0-11]: " choice
    choice="${choice//$'\r'/}"; echo
    case "${choice}" in
      1) do_install_manager; pause ;;
      2) do_update_manager; pause ;;
      3) do_uninstall_manager; pause ;;
      4) do_install_bot; pause ;;
      5) do_update_bot; pause ;;
      6) echo -e "  ${GREEN}[1]${NC} Full  ${GREEN}[2]${NC} DB"; read -r -p "Choice [1]: " bt
         case "${bt:-1}" in 2) do_backup db ;; *) do_backup full ;; esac; pause ;;
      7) do_restore; pause ;;
      8) do_migrate_menu; pause ;;
      9) do_service_menu ;;
      10) do_doctor; pause ;;
      11) do_uninstall_bot; pause ;;
      0) exit 0 ;;
      *) warn "Invalid" ;;
    esac
  done
}

cmd="${1:-}"; shift || true
case "${cmd}" in
  "") main_menu ;;
  install-manager) do_install_manager ;;
  update-manager) do_update_manager ;;
  install) do_install_bot ;;
  update) do_update_bot ;;
  backup) do_backup "${1:-full}" ;;
  restore) do_restore "${1:-}" ;;
  migrate-export) do_export_migrate ;;
  migrate-import) do_import_migrate "${1:-}" ;;
  start) service_start ;;
  stop) service_stop ;;
  restart) service_restart ;;
  status) echo "Bot: $(get_bot_version)  Manager: ${MANAGER_VERSION}"; systemctl --no-pager -l status "${SERVICE_NAME}" 2>/dev/null || true ;;
  logs) journalctl -u "${SERVICE_NAME}" -n "${1:-80}" --no-pager ;;
  doctor) do_doctor ;;
  *) echo "Usage: ${CMD_NAME} [install|update|backup|start|stop|doctor|...]"; exit 1 ;;
esac
