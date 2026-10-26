#!/usr/bin/env bash
# =============================================================================
# NexusNet Bot Manager
# Install / update / backup / restore / migrate / keys & license for NexusNet Bot
# =============================================================================
set -euo pipefail

MANAGER_VERSION="1.4.1"
REPO="SiNaKeEn/NexusNet-Bot"
MANAGER_BRANCH="Manager"
CMD_NAME="nxt-bm"
MANAGER_BIN="/usr/local/bin/${CMD_NAME}"
LEGACY_BIN="/usr/local/bin/nexusnetmanager"   # old command name, kept as a symlink

INSTALL_DIR="${INSTALL_DIR:-/opt/nexusnet}"
SERVICE_NAME="${SERVICE_NAME:-nexusnet}"
SERVICE_USER="${SERVICE_USER:-nexusnet}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/nexusnet-backups}"
MIGRATE_ROOT="${MIGRATE_ROOT:-/root/nexusnet-migrate}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
KEEP_ROLLBACKS="${KEEP_ROLLBACKS:-5}"
ASSUME_YES="${ASSUME_YES:-0}"
DEFAULT_DB_URL="sqlite+aiosqlite:///./storage/nexusnet.db"

SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

CYAN=$'\033[1;36m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'
YLW=$'\033[1;33m';  BLU=$'\033[1;34m';  DIM=$'\033[2m'; NC=$'\033[0m'

log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YLW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "${BLU}[i]${NC} $*"; }
_ui()  { echo -e "$@" >&2; }

stamp()   { date +%Y%m%d_%H%M%S; }
has_cmd() { command -v "$1" &>/dev/null; }

# ---------- temp dir tracking ----------
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "${d:-}" && -d "${d}" ]] && rm -rf "${d}"
  done
  return 0
}
trap cleanup EXIT
MK_TMP=""
mk_tmp() { MK_TMP="$(mktemp -d /tmp/nexus_XXXXXX)"; TMP_DIRS+=("${MK_TMP}"); }

confirm() {
  local msg="${1:-Continue?}" ans
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  read -r -p "$(echo -e "${YLW}${msg} [y/N] ${NC}")" ans || return 1
  [[ "${ans}" == "y" || "${ans}" == "Y" || "${ans}" == "yes" ]]
}

ask() {  # ask "prompt" [default] -> ANS
  local prompt="$1" def="${2:-}" a
  if [[ "${ASSUME_YES}" == "1" ]]; then ANS="${def}"; return 0; fi
  if [[ -n "${def}" ]]; then
    read -r -p "$(echo -e "${YLW}${prompt} [${def}]: ${NC}")" a || a=""
  else
    read -r -p "$(echo -e "${YLW}${prompt}: ${NC}")" a || a=""
  fi
  a="${a//$'\r'/}"
  ANS="${a:-$def}"
}

pause() { [[ "${ASSUME_YES}" == "1" ]] && return 0; read -r -p "Press Enter..." _ || true; }

# ---------- version / service helpers ----------
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

code_present() { [[ -f "${INSTALL_DIR}/VERSION" || -d "${INSTALL_DIR}/deploy" ]]; }

service_active_fast() {
  [[ -f "/run/systemd/units/invocation:${SERVICE_NAME}.service" ]] && return 0
  systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null
}
has_service() {
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || systemctl cat "${SERVICE_NAME}" &>/dev/null
}
service_stop() {
  if has_service && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  fi
  return 0
}
service_start() {
  if has_service; then
    log "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}" 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then ok "Service started"; return 0; fi
    err "Service failed to start. Last log lines:"
    journalctl -u "${SERVICE_NAME}" -n 25 --no-pager 2>/dev/null || true
    return 1
  fi
  warn "No systemd unit (${SERVICE_NAME})"
  return 1
}
service_restart() {
  has_service || { warn "No systemd unit"; return 1; }
  systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then ok "Restarted"; return 0; fi
  err "Restart failed"; journalctl -u "${SERVICE_NAME}" -n 25 --no-pager 2>/dev/null || true
  return 1
}

fix_perms() {
  [[ -d "${INSTALL_DIR}" ]] || return 0
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"
  [[ -f "${INSTALL_DIR}/.env" ]] && chmod 600 "${INSTALL_DIR}/.env" 2>/dev/null || true
  local f
  for f in "${INSTALL_DIR}"/license*.pem; do
    [[ -f "${f}" ]] && chmod 600 "${f}" 2>/dev/null || true
  done
  if id "${SERVICE_USER}" &>/dev/null; then
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}" 2>/dev/null || true
  fi
  return 0
}

run_preflight() {
  local py="${INSTALL_DIR}/.venv/bin/python" pf="${INSTALL_DIR}/deploy/preflight.py"
  if [[ -x "${py}" && -f "${pf}" ]]; then
    log "Preflight..."
    ( cd "${INSTALL_DIR}" && "${py}" "${pf}" ) || { warn "Preflight reported problems"; return 1; }
    ok "Preflight OK"
  fi
  return 0
}

# ---------- .env helpers ----------
env_get() {
  local key="$1" f="${INSTALL_DIR}/.env" line
  [[ -f "${f}" ]] || return 0
  line="$(grep -E "^${key}=" "${f}" 2>/dev/null | tail -n1 || true)"
  line="${line#*=}"; line="${line%$'\r'}"
  if [[ "${line}" == \"*\" ]]; then line="${line#\"}"; line="${line%\"}"
  elif [[ "${line}" == \'*\' ]]; then line="${line#\'}"; line="${line%\'}"; fi
  printf '%s' "${line}"
}

env_backup() {
  [[ -f "${INSTALL_DIR}/.env" ]] || return 0
  mkdir -p "${INSTALL_DIR}/backups"
  local b="${INSTALL_DIR}/backups/env-$(stamp).bak"
  cp -a "${INSTALL_DIR}/.env" "${b}"; chmod 600 "${b}"
  ENV_BACKUP_PATH="${b}"
}

env_set() {  # env_set KEY VALUE   (VALUE written verbatim after KEY=)
  local key="$1" val="$2" f="${INSTALL_DIR}/.env" tmp mode
  [[ -f "${f}" ]] || { : > "${f}"; chmod 600 "${f}"; }
  if grep -qE "^${key}=" "${f}"; then mode="active"
  elif grep -qE "^#[[:space:]]*${key}=" "${f}"; then mode="comment"
  else mode="append"; fi
  tmp="$(mktemp)"
  K="${key}" V="${val}" M="${mode}" awk '
    BEGIN { k=ENVIRON["K"]; v=ENVIRON["V"]; m=ENVIRON["M"]; done=0 }
    {
      if (m=="active" && index($0, k "=")==1) { if (!done) { print k "=" v; done=1 } ; next }
      if (m=="comment" && !done && $0 ~ ("^#[ \t]*" k "=")) { print k "=" v; done=1; next }
      print
    }
    END { if (m=="append") print k "=" v }
  ' "${f}" > "${tmp}"
  cat "${tmp}" > "${f}"; rm -f "${tmp}"
}

mask() {
  local s="$1" n=${#1}
  if (( n == 0 )); then echo "(empty)"
  elif (( n <= 12 )); then echo "****"
  else echo "${s:0:6}...${s: -4}  (${n} chars)"; fi
}

valid_token()  { [[ "$1" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]; }
valid_ids()    { [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]]; }
valid_fernet() {
  K="$1" python3 -c '
import os, sys, base64
try:
    sys.exit(0 if len(base64.urlsafe_b64decode(os.environ["K"].encode())) == 32 else 1)
except Exception:
    sys.exit(1)'
}
gen_fernet() { python3 -c 'import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode())'; }

# ---------- Telegram helpers ----------
tg_call() { curl -sS --max-time 15 "https://api.telegram.org/bot$1/$2" 2>/dev/null || true; }
tg_getme() {
  local out; out="$(tg_call "$1" getMe)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get("ok"):
    print(d["result"].get("username", ""))
else:
    sys.exit(2)'
}
tg_webhook_info() {
  local out; out="$(tg_call "$1" getWebhookInfo)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["result"]
    print("%s|%s|%s" % (d.get("url",""), d.get("pending_update_count",0), (d.get("last_error_message","") or "").replace("|"," ")))
except Exception:
    sys.exit(1)'
}
journal_has_conflict() {
  journalctl -u "${SERVICE_NAME}" --since "3 min ago" --no-pager 2>/dev/null | grep -qi "conflict" || return 1
}

do_telegram_check() {
  local token user info wurl wpend werr envurl
  token="$(env_get BOT_TOKEN)"
  [[ -n "${token}" ]] || { warn "BOT_TOKEN is empty"; return 0; }
  if user="$(tg_getme "${token}")"; then ok "Telegram token OK  ->  @${user}"
  else warn "Telegram getMe failed (invalid token or no internet from this server)"; return 0; fi
  info="$(tg_webhook_info "${token}" || true)"
  if [[ -n "${info}" ]]; then
    IFS='|' read -r wurl wpend werr <<< "${info}"
    envurl="$(env_get WEBHOOK_URL)"
    if [[ -z "${wurl}" ]]; then info "Telegram: no webhook set (polling mode)"
    else info "Telegram webhook: ${wurl}   pending: ${wpend}"; fi
    [[ -n "${werr}" ]] && warn "Telegram last webhook error: ${werr}"
    if [[ -z "${envurl}" && -n "${wurl}" ]]; then
      warn "A webhook is set at Telegram but WEBHOOK_URL is empty in .env (polling would fail)."
      if confirm "Delete the webhook at Telegram now?"; then
        tg_call "${token}" deleteWebhook >/dev/null; ok "Webhook deleted"
      fi
    fi
  fi
  if journal_has_conflict; then
    warn "Telegram 'Conflict' found in logs: ANOTHER instance uses this BOT_TOKEN (old server still running?)."
    warn "On the OLD server run:  systemctl disable --now ${SERVICE_NAME}"
  fi
  return 0
}

# ---------- sqlite helpers ----------
resolve_db_file() {
  local url; url="$(env_get DATABASE_URL)"; [[ -z "${url}" ]] && url="${DEFAULT_DB_URL}"
  URL="${url}" BASE="${INSTALL_DIR}" python3 - <<'PY'
import os, sys
u = os.environ["URL"]; base = os.environ["BASE"]
if not u.startswith("sqlite"): sys.exit(3)
i = u.find(":///")
if i < 0: sys.exit(3)
p = u[i+4:].split("?")[0]
if not p or p == ":memory:": sys.exit(3)
if not p.startswith("/"): p = os.path.normpath(os.path.join(base, p))
print(p)
PY
}
sqlite_copy() {  # hot, consistent copy (safe while bot is running)
  SRC="$1" DST="$2" python3 - <<'PY'
import os, sqlite3
s = sqlite3.connect(os.environ["SRC"]); d = sqlite3.connect(os.environ["DST"])
s.backup(d); d.close(); s.close()
PY
}
sqlite_check() {
  F="$1" python3 - <<'PY'
import os, sqlite3, sys
try:
    c = sqlite3.connect(os.environ["F"]); r = c.execute("PRAGMA integrity_check").fetchone()[0]; c.close()
    sys.exit(0 if r == "ok" else 1)
except Exception:
    sys.exit(1)
PY
}
refresh_db_copies() {  # replace raw db copies in staged dir with consistent hot copies
  local sdir="$1" ldir="$2" f rel
  [[ -d "${sdir}" && -d "${ldir}" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"${sdir}"/}"
    [[ -f "${ldir}/${rel}" ]] || continue
    rm -f "${f}" "${f}-wal" "${f}-shm"
    if ! sqlite_copy "${ldir}/${rel}" "${f}" 2>/dev/null; then
      warn "Hot copy failed for ${rel}, using raw copy"
      rm -f "${f}"; cp -a "${ldir}/${rel}" "${f}"
      [[ -f "${ldir}/${rel}-wal" ]] && cp -a "${ldir}/${rel}-wal" "${f}-wal"
      [[ -f "${ldir}/${rel}-shm" ]] && cp -a "${ldir}/${rel}-shm" "${f}-shm"
    fi
  done < <(find "${sdir}" -maxdepth 3 -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
  return 0
}
copy_secret_files() {  # .env VERSION license*.pem -> dir
  local dest="$1" f
  [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${dest}/.env"
  [[ -f "${INSTALL_DIR}/VERSION" ]] && cp -a "${INSTALL_DIR}/VERSION" "${dest}/VERSION"
  for f in "${INSTALL_DIR}"/license*.pem; do
    [[ -f "${f}" ]] && cp -a "${f}" "${dest}/"
  done
  return 0
}

# ---------- zip / version helpers ----------
infer_version_from_name() {
  local name="$1" v=""
  if   [[ "${name}" =~ [Vv]([0-9]+[._][0-9]+([._][0-9]+)?) ]]; then v="${BASH_REMATCH[1]}"
  elif [[ "${name}" =~ ([0-9]+[._][0-9]+([._][0-9]+)?) ]];      then v="${BASH_REMATCH[1]}"
  fi
  echo "${v//_/.}"
}

resolve_zip_path() {
  local input="$1"
  input="${input//$'\r'/}"; input="${input//\"/}"; input="${input//\'/}"
  input="${input#"${input%%[![:space:]]*}"}"; input="${input%"${input##*[![:space:]]}"}"
  [[ -z "${input}" ]] && return 1
  [[ -f "${input}" ]] && { printf '%s\n' "${input}"; return 0; }

  local v variants=("${input}" "${input//_/.}" "${input//./_}") c d
  for d in /root "$(pwd)"; do
    for v in "${variants[@]}"; do
      for c in "${d}/${v}" "${d}/${v}.zip" "${d}/NexusNet-${v}.zip" "${d}/NexusNet-V${v}.zip" \
               "${d}/NexusNet-v${v}.zip" "${d}/NexusNet_${v}.zip"; do
        [[ -f "${c}" ]] && { printf '%s\n' "${c}"; return 0; }
      done
    done
  done
  local found
  for v in "${variants[@]}"; do
    found="$(find /root -maxdepth 3 -type f -iname "*${v}*.zip" 2>/dev/null | sort -r | head -1)"
    [[ -n "${found}" && -f "${found}" ]] && { printf '%s\n' "${found}"; return 0; }
  done
  return 1
}

list_root_zips() { find /root -maxdepth 3 -type f -iname '*.zip' 2>/dev/null | sort -r; }

pick_zip() {  # all UI on stderr, only the final path on stdout
  _ui ""; _ui "${CYAN}Select bot ZIP${NC}"
  _ui "  ${GREEN}[1]${NC} Type filename / path / version  (e.g. 1.9.8, V1_9_8, NexusNet-V1_9_8.zip)"
  _ui "  ${GREEN}[2]${NC} Scan /root and pick from a list"
  _ui ""
  local mode name path choice
  read -r -p "$(echo -e "${YLW}Choice [1]: ${NC}")" mode >&2 || true
  mode="${mode//$'\r'/}"; mode="${mode:-1}"

  if [[ "${mode}" != "1" && "${mode}" != "2" ]]; then
    if path="$(resolve_zip_path "${mode}")"; then
      _ui "${GREEN}[+]${NC} Using: ${path}"; printf '%s\n' "${path}"; return 0
    fi
    _ui "${RED}[-]${NC} Not found from input: ${mode}"; mode="2"
  fi

  if [[ "${mode}" == "1" ]]; then
    read -r -p "$(echo -e "${YLW}Filename / path / version: ${NC}")" name >&2 || true
    if path="$(resolve_zip_path "${name}")"; then
      _ui "${GREEN}[+]${NC} Using: ${path}"; printf '%s\n' "${path}"; return 0
    fi
    _ui "${RED}[-]${NC} Not found: ${name}"; _ui "${CYAN}[*]${NC} ZIP files under /root:"
    list_root_zips >&2 || true
    die "File not found"
  fi

  local zips=() f z
  while IFS= read -r f; do [[ -n "${f}" && -f "${f}" ]] && zips+=("${f}"); done < <(list_root_zips)
  if [[ ${#zips[@]} -eq 0 ]]; then
    _ui "${YLW}[!]${NC} No .zip found under /root"
    read -r -p "$(echo -e "${YLW}Full path to ZIP: ${NC}")" name >&2 || true
    path="$(resolve_zip_path "${name}")" || die "Not found: ${name}"
    _ui "${GREEN}[+]${NC} Using: ${path}"; printf '%s\n' "${path}"; return 0
  fi
  _ui ""; _ui "${CYAN}ZIP files found:${NC}"
  local i=1 base sz ver
  for z in "${zips[@]}"; do
    base="$(basename "${z}")"; sz="$(du -h "${z}" 2>/dev/null | awk '{print $1}')"; ver="$(infer_version_from_name "${base}")"
    _ui "  ${GREEN}[${i}]${NC}  ${base}  ${DIM}(${sz:-?})${NC}${ver:+  v${ver}}"
    _ui "      ${DIM}${z}${NC}"
    i=$((i+1))
  done
  read -r -p "$(echo -e "${YLW}Select number: ${NC}")" choice >&2 || true
  choice="${choice//$'\r'/}"
  [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le ${#zips[@]} ]] || die "Invalid number"
  path="${zips[$((choice-1))]}"
  _ui "${GREEN}[+]${NC} Using: ${path}"; printf '%s\n' "${path}"
}

extract_zip_source() {  # zip tmpdir -> prints the directory that holds the bot code
  local zip_path="$1" tmp="$2"
  has_cmd unzip || die "unzip is not installed"
  unzip -q -o "${zip_path}" -d "${tmp}" || die "Cannot extract ZIP (corrupt?)"
  rm -rf "${tmp}/__MACOSX"
  if   [[ -d "${tmp}/nexus_v36" ]]; then echo "${tmp}/nexus_v36"; return 0
  elif [[ -d "${tmp}/nexus_bot" ]]; then echo "${tmp}/nexus_bot"; return 0; fi
  local dirs files
  dirs="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  files="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type f | wc -l)"
  if [[ "${dirs}" -eq 1 && "${files}" -eq 0 ]]; then
    find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1
  else
    echo "${tmp}"
  fi
}

# ---------- code deployment ----------
is_preserved() {
  case "$1" in
    .env|.env.local|storage|data|backups|.venv|logs|license*|*.pem) return 0 ;;
  esac
  return 1
}
clean_code_dir() {
  local d="$1" p
  while IFS= read -r -d '' p; do
    is_preserved "$(basename "${p}")" || rm -rf "${p}"
  done < <(find "${d}" -mindepth 1 -maxdepth 1 -print0)
  return 0
}
copy_code_in() {  # overlay source dir into INSTALL_DIR without touching secrets / live DB
  local src="$1" p n
  while IFS= read -r -d '' p; do
    n="$(basename "${p}")"
    case "${n}" in
      .env|.env.local|.venv|backups|license*|*.pem|__MACOSX) continue ;;
      storage) [[ -e "${INSTALL_DIR}/storage" ]] && continue ;;
    esac
    cp -a "${p}" "${INSTALL_DIR}/"
  done < <(find "${src}" -mindepth 1 -maxdepth 1 -print0)
  return 0
}
deploy_code() {  # src_dir version
  local src="$1" ver="$2" zv=""
  mkdir -p "${INSTALL_DIR}"
  clean_code_dir "${INSTALL_DIR}"
  copy_code_in "${src}"
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups" "${INSTALL_DIR}/data"
  [[ -f "${src}/VERSION" ]] && zv="$(tr -d '[:space:]' < "${src}/VERSION")"
  if   [[ -n "${zv}" ]];  then echo "${zv}"  > "${INSTALL_DIR}/VERSION"
  elif [[ -n "${ver}" ]]; then echo "${ver}" > "${INSTALL_DIR}/VERSION"; fi
  _bot_ver_cache=""
}

ensure_system_deps() {
  if has_cmd apt-get; then
    log "System packages (python3, venv, pip, curl, unzip, tar, sqlite3)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || warn "apt-get update reported errors"
    apt-get install -y -qq python3 python3-venv python3-pip curl unzip tar ca-certificates sqlite3 >/dev/null \
      || warn "apt-get install reported errors"
  else
    warn "apt-get not found: install python3, python3-venv, pip, curl, unzip, tar manually"
  fi
  has_cmd python3 || die "python3 is required"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || warn "Python older than 3.9 detected"
  python3 -c 'import venv, ensurepip' 2>/dev/null || die "python3-venv is missing (apt install python3-venv)"
}
ensure_service_user() {
  if ! id "${SERVICE_USER}" &>/dev/null; then
    useradd --system --home "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}" 2>/dev/null || true
  fi
}
setup_venv() {
  if [[ ! -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
    log "Creating virtualenv..."
    rm -rf "${INSTALL_DIR}/.venv"
    python3 -m venv "${INSTALL_DIR}/.venv" || { err "venv creation failed"; return 1; }
  fi
  "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip -q --disable-pip-version-check || warn "pip upgrade failed (continuing)"
  local req=""
  [[ -f "${INSTALL_DIR}/requirements.txt" ]] && req="${INSTALL_DIR}/requirements.txt"
  [[ -f "${INSTALL_DIR}/deploy/requirements.txt" ]] && req="${INSTALL_DIR}/deploy/requirements.txt"
  if [[ -n "${req}" ]]; then
    log "Installing Python requirements..."
    "${INSTALL_DIR}/.venv/bin/pip" install -r "${req}" -q --disable-pip-version-check \
      || { err "pip install failed"; return 1; }
  fi
  return 0
}
install_unit() {  # [fallback_unit_file] [old_install_dir]
  local fallback="${1:-}" old_dir="${2:-/opt/nexusnet}" unit="/etc/systemd/system/${SERVICE_NAME}.service" s=""
  if   [[ -f "${INSTALL_DIR}/deploy/systemd.service" ]]; then s="${INSTALL_DIR}/deploy/systemd.service"
  elif [[ -n "${fallback}" && -f "${fallback}" ]];        then s="${fallback}"; fi
  [[ -n "${s}" ]] || { warn "No systemd unit found (deploy/systemd.service)"; return 1; }
  cp -a "${s}" "${unit}"
  [[ "${old_dir}" != "${INSTALL_DIR}" ]] && sed -i "s|${old_dir}|${INSTALL_DIR}|g" "${unit}"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  ok "systemd unit installed"
}
check_new_env_vars() {
  local ex="${INSTALL_DIR}/.env.example" f="${INSTALL_DIR}/.env" k
  local missing=()
  [[ -f "${ex}" && -f "${f}" ]] || return 0
  while IFS= read -r k; do
    grep -qE "^${k}=" "${f}" || missing+=("${k}")
  done < <(grep -oE '^[A-Z][A-Z0-9_]*=' "${ex}" | tr -d '=')
  if (( ${#missing[@]} > 0 )); then
    warn "Variables in .env.example but missing from your .env: ${missing[*]}"
  fi
  return 0
}

# ---------- first-run wizard ----------
first_run_wizard() {
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  local tok ids owner user key
  echo; echo -e "${CYAN}-- Quick setup (.env) --${NC}"
  env_backup || true
  tok="$(env_get BOT_TOKEN)"
  if [[ -z "${tok}" ]]; then
    ask "BOT_TOKEN (from @BotFather, Enter to skip)"
    if [[ -n "${ANS}" ]]; then
      if valid_token "${ANS}"; then
        env_set BOT_TOKEN "${ANS}"
        if user="$(tg_getme "${ANS}")"; then ok "Token OK -> @${user}"; else warn "Could not verify token online (saved anyway)"; fi
      else warn "Token format looks wrong - skipped"; fi
    fi
  fi
  ids="$(env_get ADMIN_IDS)"
  if [[ -z "${ids}" ]]; then
    ask "ADMIN_IDS (your numeric Telegram ID, comma separated, Enter to skip)"
    if [[ -n "${ANS}" ]]; then
      ids="${ANS// /}"
      if valid_ids "${ids}"; then
        env_set ADMIN_IDS "${ids}"
        owner="$(env_get BOT_OWNER_ID)"
        if [[ -z "${owner}" ]]; then ask "BOT_OWNER_ID" "${ids%%,*}"; valid_ids "${ANS}" && env_set BOT_OWNER_ID "${ANS}"; fi
      else warn "IDs must be numbers - skipped"; fi
    fi
  fi
  key="$(env_get CREDENTIAL_ENCRYPTION_KEY)"
  if [[ -z "${key}" ]]; then
    key="$(gen_fernet)"; env_set CREDENTIAL_ENCRYPTION_KEY "${key}"
    ok "CREDENTIAL_ENCRYPTION_KEY generated (back up your .env! panel passwords depend on it)"
  fi
  [[ -z "$(env_get DATABASE_URL)" ]] && env_set DATABASE_URL "${DEFAULT_DB_URL}"
  fix_perms
  info "More options later: ${CMD_NAME} -> [12] Keys & License"
}

# ---------- backup / restore ----------
LAST_BACKUP=""
do_backup() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  local mode="${1:-full}" ts stage tar_path
  ts="$(stamp)"; mkdir -p "${BACKUP_ROOT}"; chmod 700 "${BACKUP_ROOT}"
  stage="${BACKUP_ROOT}/.stage-${ts}"; mkdir -p "${stage}/${ts}"
  log "Backup (${mode})..."
  copy_secret_files "${stage}/${ts}"
  case "${mode}" in
    full)
      [[ -d "${INSTALL_DIR}/storage" ]] && cp -a "${INSTALL_DIR}/storage" "${stage}/${ts}/storage" \
        && refresh_db_copies "${stage}/${ts}/storage" "${INSTALL_DIR}/storage"
      [[ -d "${INSTALL_DIR}/data" ]] && cp -a "${INSTALL_DIR}/data" "${stage}/${ts}/data"
      ;;
    db)
      mkdir -p "${stage}/${ts}/database"
      find "${INSTALL_DIR}/storage" -maxdepth 2 -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
        -exec cp -a {} "${stage}/${ts}/database/" \; 2>/dev/null || true
      refresh_db_copies "${stage}/${ts}/database" "${INSTALL_DIR}/storage"
      ;;
  esac
  { echo "timestamp=${ts}"; echo "version=$(get_bot_version)"; echo "mode=${mode}"; echo "install_dir=${INSTALL_DIR}"; } > "${stage}/${ts}/meta.txt"
  tar_path="${BACKUP_ROOT}/nexusnet-backup-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${stage}" "${ts}"
  rm -rf "${stage}"; chmod 600 "${tar_path}"
  LAST_BACKUP="${tar_path}"
  ok "Archive: ${tar_path}"
  ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
  return 0
}

do_restore() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  local src="${1:-}" choice
  if [[ -z "${src}" ]]; then
    local backups=() i=1 b ver
    echo; echo -e "${CYAN}Backups:${NC}"
    while IFS= read -r b; do
      [[ -z "${b}" ]] && continue
      backups+=("${b}"); printf "  ${GREEN}[%d]${NC}  %s\n" "${i}" "$(basename "${b}")"; i=$((i+1))
    done < <(ls -1t "${BACKUP_ROOT}"/nexusnet-backup-*.tar.gz 2>/dev/null | head -15)
    [[ ${#backups[@]} -gt 0 ]] || die "No backups in ${BACKUP_ROOT}"
    read -r -p "Select: " choice
    [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le ${#backups[@]} ]] || die "Invalid selection"
    src="${backups[$((choice-1))]}"
  fi
  local work="${src}" tmp=""
  if [[ -f "${src}" && "${src}" == *.tar.gz ]]; then
    mk_tmp; tmp="${MK_TMP}"
    tar -xzf "${src}" -C "${tmp}" || die "Cannot read archive"
    work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi
  [[ -d "${work}" ]] || die "Backup not found"
  confirm "Restore from $(basename "${src}")? (service will be stopped, a safety backup is taken first)" || die "Cancelled"
  ASSUME_YES=1 do_backup full >/dev/null || true
  service_stop
  [[ -f "${work}/.env" ]] && cp -a "${work}/.env" "${INSTALL_DIR}/.env" && ok ".env"
  local f
  for f in "${work}"/license*.pem; do [[ -f "${f}" ]] && cp -a "${f}" "${INSTALL_DIR}/" && ok "$(basename "${f}")"; done
  if [[ -d "${work}/storage" ]]; then
    rm -rf "${INSTALL_DIR}/storage"; cp -a "${work}/storage" "${INSTALL_DIR}/storage"; ok "storage"
  elif [[ -d "${work}/database" ]]; then
    mkdir -p "${INSTALL_DIR}/storage"
    rm -f "${INSTALL_DIR}"/storage/*.db-wal "${INSTALL_DIR}"/storage/*.db-shm
    cp -a "${work}/database/." "${INSTALL_DIR}/storage/" 2>/dev/null || true; ok "database"
  fi
  [[ -d "${work}/data" ]] && { rm -rf "${INSTALL_DIR}/data"; cp -a "${work}/data" "${INSTALL_DIR}/data"; ok "data"; }
  fix_perms; service_start || true
  ok "Restore done"
}

# ---------- install / update / rollback ----------
do_install_bot() {
  if code_present && [[ -f "${INSTALL_DIR}/.env" ]]; then
    warn "Bot already installed (v$(get_bot_version))"
    confirm "Reinstall code? (.env, storage and license keys are kept)" || die "Cancelled"
  fi
  local zip_path; zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found"
  log "ZIP: ${zip_path}"
  local ver; ver="$(infer_version_from_name "$(basename "${zip_path}")")"
  ensure_system_deps; ensure_service_user
  local tmp src; mk_tmp; tmp="${MK_TMP}"
  src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Bad ZIP structure"
  log "Installing files..."
  deploy_code "${src}" "${ver}"
  if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    if [[ -f "${INSTALL_DIR}/.env.example" ]]; then cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"; warn ".env created from .env.example"
    else : > "${INSTALL_DIR}/.env"; fi
    chmod 600 "${INSTALL_DIR}/.env"
  else ok ".env kept"; fi
  setup_venv || die "Dependency install failed - fix the error above and run Install again"
  install_unit || true
  fix_perms
  first_run_wizard
  ok "Install complete - v$(get_bot_version)"
  if has_service && confirm "Start the bot now?"; then service_start || true; fi
}

do_update_bot() {
  code_present || die "Bot not installed"
  local current; current="$(get_bot_version)"; info "Installed: ${current}"
  local zip_path; zip_path="$(pick_zip)"
  [[ -f "${zip_path}" ]] || die "ZIP not found"
  log "ZIP: ${zip_path}"
  local new_ver; new_ver="$(infer_version_from_name "$(basename "${zip_path}")")"
  [[ -n "${new_ver}" ]] && info "Target: ${new_ver}"
  confirm "Update from $(basename "${zip_path}")?" || die "Cancelled"

  local tmp src; mk_tmp; tmp="${MK_TMP}"
  src="$(extract_zip_source "${zip_path}" "${tmp}")"
  [[ -d "${src}" ]] || die "Bad ZIP structure"

  log "Backup..."; ASSUME_YES=1 do_backup full >/dev/null || warn "Backup failed (continuing)"
  local rb="${BACKUP_ROOT}/rollback-$(stamp)"; mkdir -p "${rb}"; chmod 700 "${rb}"
  tar -C "${INSTALL_DIR}" --exclude=./.venv --exclude=./storage --exclude=./data --exclude=./backups \
      --exclude=./.env --exclude='./license*' --exclude='./*.pem' -czf "${rb}/code.tar.gz" . \
      || warn "Could not create rollback snapshot"
  copy_secret_files "${rb}"
  echo "${current}" > "${rb}/prev_version"
  ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null | tail -n +"$((KEEP_ROLLBACKS + 1))" | xargs -r rm -rf

  service_stop
  log "Replacing code (keeping .env, storage, data, license keys)..."
  deploy_code "${src}" "${new_ver}"
  [[ ! -f "${INSTALL_DIR}/.env" && -f "${rb}/.env" ]] && cp -a "${rb}/.env" "${INSTALL_DIR}/.env"
  ensure_service_user
  if ! setup_venv; then
    err "Dependency install failed"
    confirm "Rollback to ${current}?" && do_rollback "${rb}"
    return 1
  fi
  fix_perms; check_new_env_vars
  run_preflight || warn "Preflight failed"
  if service_start; then ok "Update OK: ${current} -> $(get_bot_version)"
  else err "Start failed"; confirm "Rollback to ${current}?" && do_rollback "${rb}"; fi
}

do_rollback() {
  local rb_dir="${1:-}"
  if [[ -z "${rb_dir}" ]]; then
    local points=() i=1 p c
    while IFS= read -r p; do
      [[ -z "${p}" ]] && continue; points+=("${p%/}")
      printf "  ${GREEN}[%d]${NC}  %s  ${DIM}(was v%s)${NC}\n" "${i}" "$(basename "${p}")" "$(cat "${p}/prev_version" 2>/dev/null || echo '?')"
      i=$((i+1))
    done < <(ls -1dt "${BACKUP_ROOT}"/rollback-*/ 2>/dev/null)
    [[ ${#points[@]} -gt 0 ]] || die "No rollback points"
    read -r -p "Select: " c
    [[ "${c}" =~ ^[0-9]+$ && "${c}" -ge 1 && "${c}" -le ${#points[@]} ]] || die "Invalid selection"
    rb_dir="${points[$((c-1))]}"
  fi
  [[ -d "${rb_dir}" ]] || die "Rollback point not found"
  confirm "Rollback code to $(cat "${rb_dir}/prev_version" 2>/dev/null || echo previous)? (data is not touched)" || die "Cancelled"
  service_stop
  if [[ -f "${rb_dir}/code.tar.gz" ]]; then
    clean_code_dir "${INSTALL_DIR}"
    tar -xzf "${rb_dir}/code.tar.gz" -C "${INSTALL_DIR}"
  fi
  [[ -f "${rb_dir}/.env" ]] && cp -a "${rb_dir}/.env" "${INSTALL_DIR}/.env"
  _bot_ver_cache=""; setup_venv || warn "venv/requirements problem"; fix_perms; service_start || true
  ok "Rollback done - v$(get_bot_version)"
}

# ---------- manager self management ----------
put_manager() {  # atomic replace (safe even if the running script is the target) + legacy symlink
  local src="$1"
  cp "${src}" "${MANAGER_BIN}.new" && chmod 755 "${MANAGER_BIN}.new" && mv -f "${MANAGER_BIN}.new" "${MANAGER_BIN}"
  if [[ -e "${LEGACY_BIN}" || -L "${LEGACY_BIN}" ]]; then ln -sf "${MANAGER_BIN}" "${LEGACY_BIN}"; fi
}
do_install_manager() {
  put_manager "${SELF_PATH}"
  ok "Manager installed -> ${MANAGER_BIN}"; info "Run: ${CMD_NAME}"
}
do_update_manager() {
  log "Downloading manager from GitHub..."
  local url="https://raw.githubusercontent.com/${REPO}/${MANAGER_BRANCH}/nexus.sh" tmp remote_ver
  tmp="$(mktemp /tmp/nexus_mgr_XXXXXX.sh)"
  curl -fsSL --connect-timeout 15 --max-time 60 -o "${tmp}" "${url}" || { rm -f "${tmp}"; die "Download failed: ${url}"; }
  grep -q 'MANAGER_VERSION=' "${tmp}" || { rm -f "${tmp}"; die "Invalid manager file"; }
  bash -n "${tmp}" 2>/dev/null || { rm -f "${tmp}"; die "Downloaded file has syntax errors - update aborted"; }
  remote_ver="$(sed -n 's/^MANAGER_VERSION="\([^"]*\)".*/\1/p' "${tmp}" | head -1)"
  info "Local  : ${MANAGER_VERSION}"; info "Remote : ${remote_ver:-unknown}"
  if [[ "${remote_ver}" == "${MANAGER_VERSION}" ]]; then
    ok "Already up to date (refreshing binary)"
    put_manager "${tmp}"; rm -f "${tmp}"; return 0
  fi
  confirm "Update manager ${MANAGER_VERSION} -> ${remote_ver}?" || { rm -f "${tmp}"; return 0; }
  put_manager "${tmp}"; rm -f "${tmp}"
  ok "Manager updated to ${remote_ver}"; info "Restarting menu..."
  exec "${MANAGER_BIN}"
}
do_uninstall_manager() {
  confirm "Remove ${MANAGER_BIN}? (bot stays)" || die "Cancelled"
  rm -f "${MANAGER_BIN}" "${LEGACY_BIN}"; ok "Manager removed"
}

# ---------- migration ----------
LAST_PACKAGE=""
meta_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

print_migration_checklist() {
  cat <<EOT

${CYAN}Migration checklist${NC}
  1. OLD server : Migrate -> Export (stops the bot so no data is lost)
  2. Copy the package to the NEW server  (or use "Push" - it does everything)
  3. NEW server : install manager, then  ${CMD_NAME} migrate-import <package.tar.gz>
  4. Verify     : ${CMD_NAME} doctor   (token, webhook, DB integrity, conflicts)
  5. OLD server : systemctl disable --now ${SERVICE_NAME}   (never run both with one token)
  6. Webhook mode only: point DNS (A record) to the NEW IP, set up reverse proxy + TLS there,
     then restart the bot so it re-registers the webhook.
  7. Keep the package safe: it contains .env, encryption key and license private key.
EOT
}

do_export_migrate() {
  code_present || die "Bot not installed"
  local ts dest tar_path name
  ts="$(stamp)"; name="export-${ts}"; dest="${MIGRATE_ROOT}/${name}"
  mkdir -p "${dest}"; chmod 700 "${MIGRATE_ROOT}"
  log "Export migration package..."
  local was_active=0
  service_active_fast && was_active=1
  if (( was_active )); then
    if confirm "Stop the bot for a clean, lossless export? (recommended)"; then service_stop
    else warn "Bot keeps running: changes made after this moment will NOT be in the package"; fi
  fi
  copy_secret_files "${dest}"
  [[ -d "${INSTALL_DIR}/storage" ]] && { cp -a "${INSTALL_DIR}/storage" "${dest}/storage"; refresh_db_copies "${dest}/storage" "${INSTALL_DIR}/storage"; }
  [[ -d "${INSTALL_DIR}/data" ]] && cp -a "${INSTALL_DIR}/data" "${dest}/data"
  # code snapshot (no venv - it is rebuilt on the new server)
  mkdir -p "${dest}/code"
  tar -C "${INSTALL_DIR}" --exclude=./.venv --exclude=./storage --exclude=./data --exclude=./backups \
      --exclude=./.env --exclude='./license*' --exclude='./*.pem' --exclude=__pycache__ --exclude='*.pyc' -cf - . \
      | tar -C "${dest}/code" -xf -
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] && cp -a "/etc/systemd/system/${SERVICE_NAME}.service" "${dest}/${SERVICE_NAME}.service"
  crontab -l 2>/dev/null | grep -i nexus > "${dest}/crontab.txt" || true
  [[ -s "${dest}/crontab.txt" ]] || rm -f "${dest}/crontab.txt"
  {
    echo "timestamp=${ts}"; echo "version=$(get_bot_version)"; echo "hostname=$(hostname)"
    echo "install_dir=${INSTALL_DIR}"; echo "service_name=${SERVICE_NAME}"; echo "service_user=${SERVICE_USER}"
    echo "manager=${MANAGER_VERSION}"
  } > "${dest}/meta.txt"
  tar_path="${MIGRATE_ROOT}/nexusnet-migrate-${ts}.tar.gz"
  tar -czf "${tar_path}" -C "${MIGRATE_ROOT}" "${name}"
  rm -rf "${dest}"; chmod 600 "${tar_path}"
  ( cd "${MIGRATE_ROOT}" && sha256sum "$(basename "${tar_path}")" > "$(basename "${tar_path}").sha256" )
  LAST_PACKAGE="${tar_path}"
  ok "Package : ${tar_path}"
  ok "Checksum: ${tar_path}.sha256"
  warn "The package contains secrets (.env, encryption key, license private key). Transfer it securely, delete it afterwards."
  if [[ "${NO_CUTOVER:-0}" != "1" ]] && has_service; then
    echo
    warn "Two bots with the same BOT_TOKEN conflict with each other."
    if confirm "Disable the bot on THIS (old) server now? (recommended once the new one is ready)"; then
      systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true; ok "Old service stopped and disabled"
    elif (( was_active )) && ! service_active_fast; then
      confirm "Start the bot here again?" && { service_start || true; }
    fi
  fi
  return 0
}

do_import_migrate() {
  local src="${1:-}"
  [[ -z "${src}" ]] && { read -r -p "Path to migrate .tar.gz: " src || true; }
  src="${src//\"/}"; src="${src//\'/}"
  [[ -f "${src}" ]] || die "Not found: ${src}"
  if [[ -f "${src}.sha256" ]]; then
    ( cd "$(dirname "${src}")" && sha256sum -c "$(basename "${src}").sha256" >/dev/null 2>&1 ) \
      && ok "Checksum OK" || die "Checksum FAILED - the package is corrupt or incomplete. Copy it again."
  else warn "No .sha256 file next to the package - integrity not verified"; fi

  local tmp work; mk_tmp; tmp="${MK_TMP}"
  tar -xzf "${src}" -C "${tmp}" || die "Cannot read package"
  work="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -d "${work}" && -f "${work}/meta.txt" ]] || die "Not a NexusNet migration package"
  echo -e "${CYAN}Package info:${NC}"; sed 's/^/   /' "${work}/meta.txt"
  local old_dir pkg_ver old_unit
  old_dir="$(meta_get "${work}/meta.txt" install_dir)"; old_dir="${old_dir:-/opt/nexusnet}"
  pkg_ver="$(meta_get "${work}/meta.txt" version)"
  [[ -f "${work}/.env" ]] || die "Package has no .env"
  confirm "Import into ${INSTALL_DIR} on THIS server?" || die "Cancelled"

  ensure_system_deps; ensure_service_user
  mkdir -p "${INSTALL_DIR}"
  service_stop

  # 1) code
  local use_pkg_code=0
  if [[ -d "${work}/code" ]]; then
    if ! code_present; then use_pkg_code=1
    elif [[ "$(get_bot_version)" != "${pkg_ver}" ]]; then
      confirm "Installed code is v$(get_bot_version), package has v${pkg_ver}. Use the package code?" && use_pkg_code=1
    fi
  fi
  if (( use_pkg_code )); then
    log "Deploying code v${pkg_ver} from package..."
    deploy_code "${work}/code" "${pkg_ver}"
  elif ! code_present; then
    warn "Package has no code snapshot - select the bot ZIP"
    local zp zt zs zv; zp="$(pick_zip)"; [[ -f "${zp}" ]] || die "ZIP not found"
    mk_tmp; zt="${MK_TMP}"; zs="$(extract_zip_source "${zp}" "${zt}")"
    zv="$(infer_version_from_name "$(basename "${zp}")")"
    deploy_code "${zs}" "${zv}"
  fi

  # 2) safety copy of whatever is already here, then restore data
  if [[ -f "${INSTALL_DIR}/.env" || -d "${INSTALL_DIR}/storage" ]]; then
    local pre="${BACKUP_ROOT}/pre-import-$(stamp)"; mkdir -p "${pre}"; chmod 700 "${BACKUP_ROOT}" "${pre}"
    [[ -f "${INSTALL_DIR}/.env" ]] && cp -a "${INSTALL_DIR}/.env" "${pre}/.env"
    [[ -d "${INSTALL_DIR}/storage" ]] && cp -a "${INSTALL_DIR}/storage" "${pre}/storage"
    info "Previous .env/storage saved in ${pre}"
  fi
  cp -a "${work}/.env" "${INSTALL_DIR}/.env"; chmod 600 "${INSTALL_DIR}/.env"; ok ".env"
  local f
  for f in "${work}"/license*.pem; do [[ -f "${f}" ]] && cp -a "${f}" "${INSTALL_DIR}/" && ok "$(basename "${f}")"; done
  if [[ -d "${work}/storage" ]]; then
    rm -rf "${INSTALL_DIR}/storage"; cp -a "${work}/storage" "${INSTALL_DIR}/storage"; ok "storage"
  fi
  if [[ -d "${work}/data" ]]; then
    rm -rf "${INSTALL_DIR}/data"; cp -a "${work}/data" "${INSTALL_DIR}/data"; ok "data"
  fi
  mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/backups"
  [[ -f "${work}/VERSION" && ! -f "${INSTALL_DIR}/VERSION" ]] && cp -a "${work}/VERSION" "${INSTALL_DIR}/VERSION"

  # 3) fix absolute paths if the install dir changed
  if [[ "${old_dir}" != "${INSTALL_DIR}" ]]; then
    local du; du="$(env_get DATABASE_URL)"
    if [[ "${du}" == *"${old_dir}"* ]]; then env_set DATABASE_URL "${du//${old_dir}/${INSTALL_DIR}}"; ok "DATABASE_URL path updated"; fi
  fi

  # 4) python env + service
  setup_venv || die "Dependency install failed. Fix the error above, then run: ${CMD_NAME} migrate-import ${src}"
  install_unit "${work}/${SERVICE_NAME}.service" "${old_dir}" || warn "Create/enable the systemd unit manually"
  fix_perms

  # 5) verify + start
  local dbf
  if dbf="$(resolve_db_file 2>/dev/null)" && [[ -n "${dbf}" ]]; then
    if [[ -f "${dbf}" ]]; then
      if sqlite_check "${dbf}"; then ok "SQLite integrity OK ($(du -h "${dbf}" | awk '{print $1}'))"
      else err "SQLite integrity check FAILED for ${dbf}"; fi
    else warn "Database file not found: ${dbf} (new empty DB will be created on start)"; fi
  fi
  check_new_env_vars; run_preflight || warn "Preflight reported problems"
  _bot_ver_cache=""
  service_start || true
  sleep 3
  do_telegram_check
  [[ -f "${work}/crontab.txt" ]] && { warn "The old server had cron entries - re-create manually if needed:"; sed 's/^/   /' "${work}/crontab.txt"; }
  if [[ -n "$(env_get WEBHOOK_URL)" ]]; then
    warn "Webhook mode: point DNS of $(env_get WEBHOOK_URL) to this server's IP and set up reverse proxy + TLS."
  fi
  ok "Import finished - bot v$(get_bot_version)"
  info "Now stop the OLD server's bot:  systemctl disable --now ${SERVICE_NAME}"
}

do_push_migrate() {
  has_cmd ssh && has_cmd scp || die "ssh/scp missing (apt install openssh-client)"
  local host port user rdir sudo=""
  ask "New server IP / hostname"; host="${ANS}"; [[ -n "${host}" ]] || die "Host required"
  ask "SSH port" "22"; port="${ANS}"
  ask "SSH user" "root"; user="${ANS}"
  if [[ "${user}" == "root" ]]; then rdir="/root"; else rdir="/tmp"; sudo="sudo"; fi
  local sock="/tmp/nexus-ssh-$$"
  local sshopts=(-p "${port}" -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o "ControlPath=${sock}" -o ControlPersist=120)
  local scpopts=(-P "${port}" -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o "ControlPath=${sock}" -o ControlPersist=120)

  log "Testing SSH connection (enter the password once if asked)..."
  ssh "${sshopts[@]}" "${user}@${host}" "echo connected" || die "SSH connection failed"

  NO_CUTOVER=1 do_export_migrate
  local pkg="${LAST_PACKAGE}" pb; pb="$(basename "${pkg}")"
  [[ -f "${pkg}" ]] || die "Export failed"

  log "Uploading package + manager to ${host}..."
  scp "${scpopts[@]}" "${pkg}" "${pkg}.sha256" "${SELF_PATH}" "${user}@${host}:${rdir}/" || die "Upload failed"
  local rcmd="set -e; ${sudo} install -m 755 ${rdir}/$(basename "${SELF_PATH}") ${MANAGER_BIN}; ${sudo} env ASSUME_YES=1 ${CMD_NAME} migrate-import '${rdir}/${pb}'"
  log "Running install + import on the new server..."
  if ssh -t "${sshopts[@]}" "${user}@${host}" "${rcmd}"; then
    ok "New server is up with all data."
    if has_service && confirm "Disable the bot on THIS (old) server now? (recommended)"; then
      systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true; ok "Old service stopped and disabled"
    fi
    if confirm "Delete the package from the new server?"; then
      ssh "${sshopts[@]}" "${user}@${host}" "${sudo} rm -f '${rdir}/${pb}' '${rdir}/${pb}.sha256'" || true
    fi
  else
    err "Remote import failed. The old bot is still stopped but NOT disabled."
    confirm "Start the bot on THIS server again?" && { service_start || true; }
  fi
  ssh -O exit "${sshopts[@]}" "${user}@${host}" 2>/dev/null || true
  print_migration_checklist
}

do_migrate_menu() {
  echo; echo -e "${CYAN}-- Migrate VPS --${NC}"
  echo -e "  ${GREEN}[1]${NC} Export package            (run on OLD server)"
  echo -e "  ${GREEN}[2]${NC} Push to new server (auto) (export + upload + install + import)"
  echo -e "  ${GREEN}[3]${NC} Import package            (run on NEW server)"
  echo -e "  ${GREEN}[4]${NC} Telegram / webhook check"
  echo -e "  ${GREEN}[5]${NC} Show checklist"
  echo -e "  ${GREEN}[0]${NC} Back"
  local c; read -r -p "Choice: " c || return 0
  case "${c}" in
    1) do_export_migrate ;;
    2) do_push_migrate ;;
    3) do_import_migrate ;;
    4) do_telegram_check ;;
    5) print_migration_checklist ;;
  esac
}

# ---------- keys & license ----------
pem_to_env() { awk 'NF { if (n++) printf "\\n"; printf "%s", $0 }' "$1"; }

show_env_status() {
  local k v
  echo; echo -e "${CYAN}Current .env (masked)${NC}"
  for k in BOT_TOKEN ADMIN_IDS BOT_OWNER_ID DATABASE_URL CREDENTIAL_ENCRYPTION_KEY LICENSE_KEY \
           LICENSE_VERIFY_PUBLIC_KEY LICENSE_SIGNING_PRIVATE_KEY REDIS_URL WEBHOOK_URL WEBHOOK_PATH WEBHOOK_HOST WEBHOOK_PORT WEBHOOK_SECRET; do
    v="$(env_get "${k}")"
    case "${k}" in
      ADMIN_IDS|BOT_OWNER_ID|DATABASE_URL|WEBHOOK_URL|WEBHOOK_PATH|WEBHOOK_HOST|WEBHOOK_PORT|REDIS_URL)
        printf "  %-28s %s\n" "${k}" "${v:-(empty)}" ;;
      *) printf "  %-28s %s\n" "${k}" "$(mask "${v}")" ;;
    esac
  done
  local f
  for f in "${INSTALL_DIR}"/license*.pem; do [[ -f "${f}" ]] && printf "  %-28s present\n" "$(basename "${f}")"; done
  return 0
}

ask_restart() { has_service && confirm "Restart the bot to apply?" && { service_restart || true; }; return 0; }

do_set_token() {
  ask "New BOT_TOKEN (from @BotFather)"; local t="${ANS// /}"
  [[ -n "${t}" ]] || { warn "Empty - cancelled"; return 0; }
  valid_token "${t}" || { err "Token format is invalid (expected 123456:ABC...)"; return 0; }
  local u
  if u="$(tg_getme "${t}")"; then ok "Telegram accepted the token -> @${u}"
  else
    warn "Telegram did not confirm this token (wrong token or no internet)."
    confirm "Save it anyway?" || return 0
  fi
  env_backup; env_set BOT_TOKEN "${t}"; fix_perms; ok "BOT_TOKEN saved (previous .env: ${ENV_BACKUP_PATH:-n/a})"
  ask_restart
}

do_set_admins() {
  local cur; cur="$(env_get ADMIN_IDS)"
  ask "ADMIN_IDS (numeric Telegram IDs, comma separated)" "${cur}"; local ids="${ANS// /}"
  valid_ids "${ids}" || { err "Only numbers separated by commas are allowed"; return 0; }
  local own; own="$(env_get BOT_OWNER_ID)"
  ask "BOT_OWNER_ID" "${own:-${ids%%,*}}"; local o="${ANS// /}"
  [[ "${o}" =~ ^[0-9]+$ ]] || { err "BOT_OWNER_ID must be a number"; return 0; }
  env_backup; env_set ADMIN_IDS "${ids}"; env_set BOT_OWNER_ID "${o}"; fix_perms
  ok "Saved ADMIN_IDS=${ids}  BOT_OWNER_ID=${o}"; ask_restart
}

do_encryption_key() {
  local cur; cur="$(env_get CREDENTIAL_ENCRYPTION_KEY)"
  echo -e "  ${GREEN}[1]${NC} Paste an existing key (e.g. from the old server)"
  echo -e "  ${GREEN}[2]${NC} Generate a NEW key"
  echo -e "  ${GREEN}[0]${NC} Back"
  local c; read -r -p "Choice: " c || return 0
  case "${c}" in
    1) ask "Paste CREDENTIAL_ENCRYPTION_KEY"; local k="${ANS// /}"
       valid_fernet "${k}" || { err "Not a valid Fernet key (44 chars, url-safe base64)"; return 0; }
       env_backup; env_set CREDENTIAL_ENCRYPTION_KEY "${k}"; fix_perms; ok "Key saved"; ask_restart ;;
    2) if [[ -n "${cur}" ]]; then
         echo -e "${RED}DANGER:${NC} saved panel passwords/credentials are encrypted with the CURRENT key."
         echo -e "${RED}A new key makes them unreadable${NC} (you would have to re-enter every panel login)."
         ask "Type ROTATE to continue"; [[ "${ANS}" == "ROTATE" ]] || { warn "Cancelled"; return 0; }
         ASSUME_YES=1 do_backup full >/dev/null || true
       fi
       local k; k="$(gen_fernet)"
       env_backup; env_set CREDENTIAL_ENCRYPTION_KEY "${k}"; fix_perms
       ok "New CREDENTIAL_ENCRYPTION_KEY generated and saved"
       info "Old .env copy: ${ENV_BACKUP_PATH:-n/a}"; ask_restart ;;
  esac
}

do_set_license_key() {
  ask "LICENSE_KEY (leave empty to clear - master bot)"; local lk="${ANS// /}"
  env_backup
  local py="${INSTALL_DIR}/.venv/bin/python" act="${INSTALL_DIR}/deploy/activate_license.py"
  if [[ -n "${lk}" && -f "${act}" && -x "${py}" ]]; then
    log "Activating with deploy/activate_license.py ..."
    if ( cd "${INSTALL_DIR}" && "${py}" "${act}" --license "${lk}" --env "${INSTALL_DIR}/.env" ); then ok "License activated"
    else warn "Activation script failed - writing LICENSE_KEY directly"; env_set LICENSE_KEY "${lk}"; fi
  else
    env_set LICENSE_KEY "${lk}"; ok "LICENSE_KEY $( [[ -n "${lk}" ]] && echo saved || echo cleared )"
  fi
  fix_perms; ask_restart
}

print_public_key_snippet() {
  local pub="${INSTALL_DIR}/license_public.pem"
  [[ -f "${pub}" ]] || { warn "license_public.pem not found"; return 0; }
  local line; line="LICENSE_VERIFY_PUBLIC_KEY=\"$(pem_to_env "${pub}")\""
  echo; echo -e "${CYAN}Put this in the CUSTOMER bot's .env:${NC}"; echo "${line}"; echo
  printf '%s\n' "${line}" > /root/nexusnet-customer-public-key.txt
  info "Also saved to /root/nexusnet-customer-public-key.txt (public key - safe to share)"
}

do_gen_license_keys() {
  local py="${INSTALL_DIR}/.venv/bin/python" gen="${INSTALL_DIR}/deploy/generate_license_keys.py"
  [[ -x "${py}" ]] || py="python3"
  [[ -f "${gen}" ]] || { err "deploy/generate_license_keys.py not found in this bot version"; return 0; }
  local priv="${INSTALL_DIR}/license_private.pem" pub="${INSTALL_DIR}/license_public.pem" kb=""
  if [[ -f "${priv}" || -n "$(env_get LICENSE_SIGNING_PRIVATE_KEY)" ]]; then
    echo -e "${RED}WARNING:${NC} a license key pair already exists."
    echo "Licenses signed with the OLD private key stop validating on customer bots until you give them the NEW public key."
    ask "Type NEW-KEYS to generate a fresh pair"; [[ "${ANS}" == "NEW-KEYS" ]] || { warn "Cancelled"; return 0; }
    kb="${BACKUP_ROOT}/license-keys-$(stamp)"; mkdir -p "${kb}"; chmod 700 "${kb}"
    [[ -f "${priv}" ]] && mv "${priv}" "${kb}/"
    [[ -f "${pub}"  ]] && mv "${pub}"  "${kb}/"
    info "Old pair moved to ${kb}"
  fi
  local marker; marker="$(mktemp)"
  if ! ( cd "${INSTALL_DIR}" && "${py}" "${gen}" ); then
    err "Key generation failed"
    [[ -n "${kb}" ]] && { mv "${kb}"/license_*.pem "${INSTALL_DIR}/" 2>/dev/null || true; info "Old keys restored"; }
    rm -f "${marker}"; return 0
  fi
  local f
  for f in license_private.pem license_public.pem; do   # pick up files if script wrote them elsewhere
    [[ -f "${INSTALL_DIR}/${f}" ]] || { [[ -f "${INSTALL_DIR}/deploy/${f}" ]] && mv "${INSTALL_DIR}/deploy/${f}" "${INSTALL_DIR}/${f}"; }
  done
  rm -f "${marker}"
  [[ -f "${priv}" && -f "${pub}" ]] || { err "license_private.pem / license_public.pem were not created"; return 0; }
  grep -q "PRIVATE KEY" "${priv}" || { err "license_private.pem looks invalid"; return 0; }
  chmod 600 "${priv}"; chmod 644 "${pub}"
  env_backup
  env_set LICENSE_SIGNING_PRIVATE_KEY "\"$(pem_to_env "${priv}")\""
  fix_perms
  ok "New key pair created; LICENSE_SIGNING_PRIVATE_KEY written to .env"
  warn "NEVER give license_private.pem to customers. Keep it only on your master server (it is included in backups/migration)."
  print_public_key_snippet
  ask_restart
}

do_set_any_env() {
  ask "Variable name (e.g. REDIS_URL, WEBHOOK_URL, WEBHOOK_SECRET)"; local k="${ANS// /}"
  [[ "${k}" =~ ^[A-Z][A-Z0-9_]*$ ]] || { err "Invalid name (use UPPER_CASE)"; return 0; }
  echo "Current: $(mask "$(env_get "${k}")")"
  ask "New value (empty = set to empty)"; local v="${ANS}"
  env_backup; env_set "${k}" "${v}"; fix_perms; ok "${k} saved"; ask_restart
}

do_keys_menu() {
  [[ -d "${INSTALL_DIR}" ]] || die "Bot not installed"
  while true; do
    echo; echo -e "${CYAN}-- Keys & License --${NC}"
    echo -e "  ${GREEN}[1]${NC} Show current config (masked)"
    echo -e "  ${GREEN}[2]${NC} Set / change BOT_TOKEN        (validated with Telegram)"
    echo -e "  ${GREEN}[3]${NC} Set ADMIN_IDS / BOT_OWNER_ID"
    echo -e "  ${GREEN}[4]${NC} CREDENTIAL_ENCRYPTION_KEY     (paste existing / generate new)"
    echo -e "  ${GREEN}[5]${NC} Set / activate LICENSE_KEY"
    echo -e "  ${GREEN}[6]${NC} Generate NEW license key pair (master server)"
    echo -e "  ${GREEN}[7]${NC} Show license PUBLIC key line  (for customer .env)"
    echo -e "  ${GREEN}[8]${NC} Set any .env variable         (REDIS_URL, WEBHOOK_*, ...)"
    echo -e "  ${GREEN}[9]${NC} Edit .env in editor"
    echo -e "  ${GREEN}[10]${NC} Restart bot"
    echo -e "  ${GREEN}[0]${NC} Back"
    local c; read -r -p "Choice: " c || return 0
    case "${c//$'\r'/}" in
      1) show_env_status ;;
      2) do_set_token ;;
      3) do_set_admins ;;
      4) do_encryption_key ;;
      5) do_set_license_key ;;
      6) do_gen_license_keys ;;
      7) print_public_key_snippet ;;
      8) do_set_any_env ;;
      9) env_backup; "${EDITOR:-nano}" "${INSTALL_DIR}/.env" 2>/dev/null || vi "${INSTALL_DIR}/.env"; fix_perms; ask_restart ;;
      10) service_restart || true ;;
      0) return 0 ;;
    esac
  done
}

# ---------- service / doctor / uninstall ----------
do_service_menu() {
  while true; do
    echo; echo -e "${CYAN}-- Service --${NC}"
    echo -e "  ${GREEN}[1]${NC} Start  ${GREEN}[2]${NC} Stop  ${GREEN}[3]${NC} Restart"
    echo -e "  ${GREEN}[4]${NC} Status ${GREEN}[5]${NC} Logs  ${GREEN}[6]${NC} Follow  ${GREEN}[0]${NC} Back"
    local c; read -r -p "Choice: " c || return 0
    case "${c//$'\r'/}" in
      1) service_start || true; pause ;;
      2) service_stop; pause ;;
      3) service_restart || true; pause ;;
      4) echo "Bot: $(get_bot_version)"; systemctl --no-pager -l status "${SERVICE_NAME}" 2>/dev/null || true; pause ;;
      5) journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true; pause ;;
      6) journalctl -u "${SERVICE_NAME}" -f || true ;;
      0) break ;;
    esac
  done
}

do_doctor() {
  local fail=0 v
  echo; echo -e "${CYAN}-- Diagnostics --${NC}"
  echo "  Manager : ${MANAGER_VERSION}   Bot : $(get_bot_version)"
  [[ -d "${INSTALL_DIR}" ]] && ok "Install dir ${INSTALL_DIR}" || { err "Install dir missing"; return 0; }
  [[ -x "${INSTALL_DIR}/.venv/bin/python" ]] && ok "venv" || { err "venv missing"; fail=1; }
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    ok ".env present"
    [[ "$(stat -c %a "${INSTALL_DIR}/.env" 2>/dev/null)" == "600" ]] || warn ".env permissions are not 600 (fix: chmod 600 ${INSTALL_DIR}/.env)"
    [[ -n "$(env_get BOT_TOKEN)" ]] && { valid_token "$(env_get BOT_TOKEN)" && ok "BOT_TOKEN format" || { err "BOT_TOKEN format invalid"; fail=1; }; } || { err "BOT_TOKEN empty"; fail=1; }
    v="$(env_get ADMIN_IDS)";     [[ -n "${v}" ]] && { valid_ids "${v}" && ok "ADMIN_IDS" || { err "ADMIN_IDS invalid"; fail=1; }; } || { err "ADMIN_IDS empty"; fail=1; }
    v="$(env_get BOT_OWNER_ID)";  [[ -n "${v}" ]] && ok "BOT_OWNER_ID" || { err "BOT_OWNER_ID empty"; fail=1; }
    v="$(env_get CREDENTIAL_ENCRYPTION_KEY)"
    if [[ -n "${v}" ]]; then valid_fernet "${v}" && ok "CREDENTIAL_ENCRYPTION_KEY valid" || { err "CREDENTIAL_ENCRYPTION_KEY is not a valid Fernet key"; fail=1; }
    else err "CREDENTIAL_ENCRYPTION_KEY empty"; fail=1; fi
    [[ -n "$(env_get LICENSE_KEY)" ]] && ok "LICENSE_KEY set" || info "LICENSE_KEY empty (fine for the master bot)"
    if [[ -n "$(env_get LICENSE_SIGNING_PRIVATE_KEY)" ]]; then
      ok "LICENSE_SIGNING_PRIVATE_KEY set (master)"
      [[ -f "${INSTALL_DIR}/license_private.pem" ]] || warn "license_private.pem file missing (only .env copy exists - back it up)"
    fi
    check_new_env_vars
  else err ".env missing"; fail=1; fi
  local dbf
  if dbf="$(resolve_db_file 2>/dev/null)"; then
    if [[ -f "${dbf}" ]]; then sqlite_check "${dbf}" && ok "SQLite integrity OK ($(du -h "${dbf}" | awk '{print $1}'))" || { err "SQLite integrity FAILED"; fail=1; }
    else warn "DB file not found yet: ${dbf}"; fi
  else info "Non-SQLite or unknown DATABASE_URL - DB is NOT included in backups, back it up separately"; fi
  has_service && ok "systemd unit" || { err "systemd unit missing"; fail=1; }
  service_active_fast && ok "Service active" || { warn "Service not active"; fail=1; }
  local free; free="$(df -Pm "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ -n "${free}" && "${free}" -lt 500 ]] && warn "Low disk space: ${free} MB free"
  run_preflight || fail=1
  do_telegram_check
  [[ "${fail}" -eq 0 ]] && ok "All checks passed" || err "Issues found"
  return 0
}

do_uninstall_bot() {
  echo -e "  ${GREEN}[1]${NC} Bot only  ${GREEN}[2]${NC} Bot+service  ${GREEN}[3]${NC} Everything (incl. backups)  ${GREEN}[0]${NC} Cancel"
  local c; read -r -p "Choice: " c || return 0
  case "${c//$'\r'/}" in
    1) confirm "Remove bot files?" || return 0; service_stop; rm -rf "${INSTALL_DIR}"; ok "Done" ;;
    2) confirm "Remove bot + service?" || return 0; service_stop; systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
       rm -f "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload; rm -rf "${INSTALL_DIR}"; ok "Done" ;;
    3) confirm "DELETE EVERYTHING including backups?" || return 0; service_stop; systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
       rm -f "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload
       rm -rf "${INSTALL_DIR}" "${BACKUP_ROOT}" "${MIGRATE_ROOT}"; ok "Done" ;;
  esac
}

# ---------- menu ----------
show_menu() {
  local bot_ver; bot_ver="$(get_bot_version)"
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║          N E X U S N E T  -  Bot Manager         ║"
  printf "║  Manager v%-39s║\n" "${MANAGER_VERSION}"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  Bot     : %-38s║\n" "${bot_ver}"
  if service_active_fast; then printf "║  Status  : %s%-38s%s║\n" "${GREEN}" "Active" "${CYAN}"
  elif [[ -d "${INSTALL_DIR}" ]]; then printf "║  Status  : %s%-38s%s║\n" "${YLW}" "Stopped" "${CYAN}"
  else printf "║  Status  : %s%-38s%s║\n" "${DIM}" "Not installed" "${CYAN}"; fi
  echo "╠══════════════════════════════════════════════════╣"
  echo "║              SCRIPT MANAGEMENT                   ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  [1]  » Install Manager                          ║"
  echo "║  [2]  » Update Manager                           ║"
  echo "║  [3]  » Uninstall Manager                        ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║                 BOT MANAGEMENT                   ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  [4]  » Install Bot                              ║"
  echo "║  [5]  » Update Bot (local ZIP)                   ║"
  echo "║  [6]  » Backup                                   ║"
  echo "║  [7]  » Restore                                  ║"
  echo "║  [8]  » Migrate VPS                              ║"
  echo "║  [9]  » Service Management                       ║"
  echo "║  [10] » Diagnostics                              ║"
  echo "║  [11] » Uninstall Bot                            ║"
  echo "║  [12] » Keys & License (.env)                    ║"
  echo "║  [13] » Rollback last update                     ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  [0]  » Exit                                     ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

run_sub() { bash "${SELF_PATH}" "$@" || true; }

main_menu() {
  local choice bt
  while true; do
    show_menu
    read -r -p "Enter choice [0-13]: " choice || exit 0
    choice="${choice//$'\r'/}"; echo
    # each action runs in its own process: a failure never kills the menu, and set -e stays active inside
    case "${choice}" in
      1)  run_sub install-manager; pause ;;
      2)  do_update_manager || true; pause ;;
      3)  run_sub uninstall-manager; pause ;;
      4)  run_sub install; pause ;;
      5)  run_sub update; pause ;;
      6)  echo -e "  ${GREEN}[1]${NC} Full  ${GREEN}[2]${NC} DB only"; read -r -p "Choice [1]: " bt || bt=1
          case "${bt:-1}" in 2) run_sub backup db ;; *) run_sub backup full ;; esac; pause ;;
      7)  run_sub restore; pause ;;
      8)  run_sub migrate; pause ;;
      9)  do_service_menu ;;
      10) run_sub doctor; pause ;;
      11) run_sub uninstall-bot; pause ;;
      12) run_sub keys ;;
      13) run_sub rollback; pause ;;
      0)  exit 0 ;;
      *)  warn "Invalid choice" ;;
    esac
  done
}

usage() {
  cat <<EOT
Usage: ${CMD_NAME} [command]
  (no command)            interactive menu
  install | update | rollback
  backup [full|db] | restore [archive]
  migrate-export | migrate-push | migrate-import <package.tar.gz>
  keys                    keys & license menu
  env-set KEY VALUE       set a variable in .env
  start | stop | restart | status | logs [n] | doctor | telegram
  install-manager | update-manager
EOT
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    has_cmd sudo || { echo "Run as root (sudo not found)" >&2; exit 1; }
    exec sudo -E bash "${SELF_PATH}" "$@"
  fi
  # upgraded from the old command name: install under the new name, keep old one as symlink
  if [[ ! -x "${MANAGER_BIN}" && "${SELF_PATH}" == "${LEGACY_BIN}" ]]; then
    cp "${SELF_PATH}" "${MANAGER_BIN}.new" && chmod 755 "${MANAGER_BIN}.new" && mv -f "${MANAGER_BIN}.new" "${MANAGER_BIN}" \
      && ln -sf "${MANAGER_BIN}" "${LEGACY_BIN}" && ok "Command renamed: use  ${CMD_NAME}  (old name still works)"
  fi
  local cmd="${1:-}"; shift || true
  case "${cmd}" in
    "")               main_menu ;;
    install-manager)  do_install_manager ;;
    uninstall-manager) do_uninstall_manager ;;
    uninstall-bot)    do_uninstall_bot ;;
    migrate)          do_migrate_menu ;;
    update-manager)   do_update_manager ;;
    install)          do_install_bot ;;
    update)           do_update_bot ;;
    rollback)         do_rollback "${1:-}" ;;
    backup)           do_backup "${1:-full}" ;;
    restore)          do_restore "${1:-}" ;;
    migrate-export)   do_export_migrate ;;
    migrate-push)     do_push_migrate ;;
    migrate-import)   do_import_migrate "${1:-}" ;;
    keys)             do_keys_menu ;;
    env-set)          [[ $# -ge 2 ]] || die "Usage: ${CMD_NAME} env-set KEY VALUE"; env_backup; env_set "$1" "$2"; fix_perms; ok "$1 saved" ;;
    start)            service_start ;;
    stop)             service_stop ;;
    restart)          service_restart ;;
    status)           echo "Bot: $(get_bot_version)  Manager: ${MANAGER_VERSION}"; systemctl --no-pager -l status "${SERVICE_NAME}" 2>/dev/null || true ;;
    logs)             journalctl -u "${SERVICE_NAME}" -n "${1:-80}" --no-pager ;;
    doctor)           do_doctor ;;
    telegram)         do_telegram_check ;;
    help|-h|--help)   usage ;;
    *)                usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
