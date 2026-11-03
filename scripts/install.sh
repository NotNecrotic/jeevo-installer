#!/usr/bin/env bash
#
# Jeevo — Linux installer.
#
# Installs Jeevo (pnpm monorepo: Node API + web bundle + Python AI worker) as
# production systemd services behind nginx, and installs the `jeevo` admin
# CLI (`sudo jeevo update`, `status`, `logs`, `restart`, `version`).
#
# Intended use:
#     curl -fsSL https://YOUR-INSTALLER-URL/install.sh | sudo bash
# or, from a checkout of the repository:
#     sudo bash scripts/install.sh
#
# Layout it creates:
#     /opt/jeevo            application code (git clone; replaceable)
#                             apps/api  apps/web  apps/ai-worker  packages/shared
#     /etc/jeevo            configuration, secrets, install metadata
#     /var/lib/jeevo        database (host storage) + service user home
#     <data dir>            LARGE FILES: media-store/ and artwork/
#                           (point this at your network storage if you like)
#     /usr/local/bin/jeevo  admin CLI
#     systemd units: jeevo-api, jeevo-worker; nginx site "jeevo"
#
# This installer targets the pnpm monorepo layout and FRESH installs only.
# Installations made by the old installer (backend/ + frontend/ + npm) are not
# migrated.
#
# It never overwrites an existing installation: if /etc/jeevo/install.conf
# exists the script exits and tells you to use `sudo jeevo update` instead.
#
# The repository is private; the installer never contains credentials. You
# provide either a read-only GitHub token or a read-only SSH deploy key at
# install time, and it is stored under /etc/jeevo with tight permissions.
#
# What you see: a numbered step list with a spinner for slow tasks. All
# command output (apt, pnpm, pip, build...) goes to /var/log/jeevo-install.log
# and is shown only if something fails.
#
# Push notifications: the installer generates a VAPID key pair ONCE and stores
# it in /etc/jeevo/backend.env. Never regenerate it on an existing install:
# a new pair invalidates every device's push subscription. Push also needs a
# contact email (VAPID_SUBJECT); if you skip it, push stays off until you add
# it to backend.env and restart the API.
#
# Piped-install safety:
#   * All interactive prompts read from /dev/tty, never from stdin, so
#     `curl ... | sudo bash` works (stdin is the script itself there).
#   * The whole script body lives in main(), invoked on the LAST line, so
#     bash has parsed the complete script before executing anything and no
#     child process can swallow part of it from the pipe.
#
# Environment overrides (used by the automated tests; not for production):
#     JEEVO_SYSTEMD=0          skip systemd/nginx integration (test containers)
#     JEEVO_ASSUME_YES=1       answer every prompt with its default
#     JEEVO_SKIP_PYTHON_CHECK=1  allow Python older than 3.9 (test containers)
#     NO_COLOR=1               disable colours and the spinner
#
# Unattended piped install (sudo strips the environment, so pass it via env):
#     curl -fsSL <url>/install.sh | sudo env JEEVO_ASSUME_YES=1 \
#         GITHUB_TOKEN=... AUTH_PASSWORD=... VAPID_EMAIL=you@example.org bash
#
set -Eeuo pipefail

CONF_DIR=/etc/jeevo
CONF="${CONF_DIR}/install.conf"
BIN_PATH=/usr/local/bin/jeevo
SERVICE_USER=jeevo
SERVICE_HOME=/var/lib/jeevo
LOG=/var/log/jeevo-install.log

# Node major installed when the system has none (or an older one). The repo pins
# a very recent pnpm, which follows current Node LTS releases.
NODE_MAJOR=22

SYSTEMD="${JEEVO_SYSTEMD:-1}"
ASSUME_YES="${JEEVO_ASSUME_YES:-0}"
UPLOAD_MAX_MB=2048

TOTAL_STEPS=9
STEP=0
FAIL_HINT=""
PW_GENERATED=0
PW_SHOWN=""
PUSH_ENABLED=0

# ------------------------------------------------------------ terminal UI

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  TTY_UI=1
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  TTY_UI=0
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) UTF=1 ;;
  *) UTF=0 ;;
esac
if [[ "$UTF" == 1 ]]; then
  S_OK="✔"; S_FAIL="✘"; S_WARN="▲"; S_Q="?"; S_ARROW="›"; S_RULE="─"
  SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  S_OK="ok"; S_FAIL="xx"; S_WARN="!!"; S_Q="?"; S_ARROW=">"; S_RULE="-"
  SPIN=('-' '\' '|' '/')
fi

rule() {
  local n="${1:-56}" i line=""
  for ((i = 0; i < n; i++)); do line+="$S_RULE"; done
  printf '  %s%s%s\n' "$DIM" "$line" "$RESET"
}
step()    { STEP=$((STEP + 1)); printf '\n%s[%d/%d]%s %s%s%s\n' "$CYAN" "$STEP" "$TOTAL_STEPS" "$RESET" "$BOLD" "$*" "$RESET"; }
section() { printf '\n  %s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()      { printf '  %s%s%s %s\n' "$GREEN" "$S_OK" "$RESET" "$*"; }
note()    { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn()    { printf '  %s%s%s %s\n' "$YELLOW" "$S_WARN" "$RESET" "$*" >&2; }
kv()      { printf '  %s%-14s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }

die() {
  printf '\n  %s%s%s %s\n' "$RED" "$S_FAIL" "$RESET" "$*" >&2
  if [[ -s "$LOG" ]]; then
    printf '  %sFull log: %s%s\n' "$DIM" "$LOG" "$RESET" >&2
  fi
  exit 1
}

show_cursor() { if [[ "$TTY_UI" == 1 ]]; then printf '\033[?25h'; fi; }

dump_log_tail() {
  printf '\n  %sLast lines of the log:%s\n' "$DIM" "$RESET" >&2
  tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
}

# _run "Message" command...  — run a command with its output sent to the log.
# Shows a spinner while it runs, then a tick (or a cross) with the message.
# Returns the command's exit status; never exits by itself.
_run() {
  local msg="$1" start=$SECONDS rc=0 pid i=0 t extra=""
  shift
  printf '\n[%s] %s\n' "$(date +%T)" "$msg" >>"$LOG"
  if [[ "$TTY_UI" == 1 ]]; then
    "$@" >>"$LOG" 2>&1 </dev/null &
    pid=$!
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r\033[K  %s%s%s %s %s%ds%s' \
        "$CYAN" "${SPIN[i % ${#SPIN[@]}]}" "$RESET" "$msg" "$DIM" "$((SECONDS - start))" "$RESET"
      i=$((i + 1))
      sleep 0.1
    done
    wait "$pid" || rc=$?
    printf '\r\033[K\033[?25h'
  else
    printf '  ... %s\n' "$msg"
    "$@" >>"$LOG" 2>&1 </dev/null || rc=$?
  fi
  t=$((SECONDS - start))
  if [[ "$t" -ge 2 ]]; then extra=" ${DIM}(${t}s)${RESET}"; fi
  if [[ "$rc" -eq 0 ]]; then
    printf '  %s%s%s %s%s\n' "$GREEN" "$S_OK" "$RESET" "$msg" "$extra"
  else
    printf '  %s%s%s %s\n' "$RED" "$S_FAIL" "$RESET" "$msg" >&2
  fi
  return "$rc"
}

# run — like _run, but a failure prints the log tail (plus FAIL_HINT) and aborts.
run() {
  if ! _run "$@"; then
    dump_log_tail
    if [[ -n "$FAIL_HINT" ]]; then printf '\n  %s\n' "$FAIL_HINT" >&2; fi
    FAIL_HINT=""
    die "Installation stopped."
  fi
  FAIL_HINT=""
}

# prompt VAR "Question" "default" ["help text"] — default wins on empty input
# (and always, in JEEVO_ASSUME_YES mode). A variable already set in the
# environment wins over everything (automated tests and scripted installs).
# Input is read from /dev/tty so that piped installs (curl | bash) work.
prompt() {
  local var="$1" q="$2" def="$3" help="${4:-}" reply d=""
  if [[ -n "$def" ]]; then d=" ${DIM}[${def}]${RESET}"; fi
  if [[ -n "${!var:-}" ]]; then
    ok "${q}: ${BOLD}${!var}${RESET} ${DIM}(from environment)${RESET}"
    return
  fi
  if [[ "$ASSUME_YES" == 1 ]]; then
    printf -v "$var" '%s' "$def"
    ok "${q}: ${BOLD}${def}${RESET} ${DIM}(default)${RESET}"
    return
  fi
  if [[ -n "$help" ]]; then note "$help"; fi
  read -r -p "  ${CYAN}${S_Q}${RESET} ${q}${d} ${S_ARROW} " reply </dev/tty || true
  printf -v "$var" '%s' "${reply:-$def}"
}

# prompt_secret VAR "Question" [default] ["help text"] — input is not echoed.
prompt_secret() {
  local var="$1" q="$2" def="${3:-}" help="${4:-}" reply
  if [[ -n "${!var:-}" ]]; then
    ok "${q}: ${DIM}(hidden, from environment)${RESET}"
    return
  fi
  if [[ "$ASSUME_YES" == 1 ]]; then
    printf -v "$var" '%s' "$def"
    ok "${q}: ${DIM}(hidden, default)${RESET}"
    return
  fi
  if [[ -n "$help" ]]; then note "$help"; fi
  while true; do
    read -r -p "  ${CYAN}${S_Q}${RESET} ${q} ${S_ARROW} " reply </dev/tty || true
    if [[ -z "$reply" && -n "$def" ]]; then
      reply="$def"
      printf '  %s(using the generated value)%s\n' "$DIM" "$RESET"
    fi
    if [[ -n "$reply" ]]; then printf -v "$var" '%s' "$reply"; return; fi
    printf '  %s(cannot be empty)%s\n' "$DIM" "$RESET"
  done
}

# confirm "Question" [y|n] — returns 0 for yes. Always yes in ASSUME_YES mode.
confirm() {
  local q="$1" def="${2:-y}" reply hint="Y/n"
  if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
  if [[ "$def" != y ]]; then hint="y/N"; fi
  read -r -p "  ${CYAN}${S_Q}${RESET} ${q} ${DIM}[${hint}]${RESET} ${S_ARROW} " reply </dev/tty || reply=""
  reply="${reply:-$def}"
  [[ "$reply" == [yY]* ]]
}

require_abs_path() {
  [[ "$1" == /* && "$1" != *[[:space:]]* ]] \
    || die "$2 must be an absolute path without spaces (got: '$1')"
}

on_err() {
  local rc="$1" line="$2"
  [[ "${BASHPID:-$$}" == "$$" ]] || return 0
  printf '\n  %s%s%s Unexpected error (exit %s) near line %s of the installer.\n' \
    "$RED" "$S_FAIL" "$RESET" "$rc" "$line" >&2
  if [[ -s "$LOG" ]]; then
    printf '  %sFull log: %s%s\n' "$DIM" "$LOG" "$RESET" >&2
  fi
  return 0
}

on_interrupt() {
  local p
  p="$(jobs -p 2>/dev/null || true)"
  if [[ -n "$p" ]]; then kill $p 2>/dev/null || true; fi
  show_cursor
  printf '\n  %s%s%s Interrupted.\n' "$YELLOW" "$S_WARN" "$RESET" >&2
  exit 130
}

# ----------------------------------------------------------------- helpers

# All git/pnpm/pip operations run as the service user, with the configured auth
# environment. Filled in during the authentication phase.
GIT_ENV=()
as_jeevo() { runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" "${GIT_ENV[@]}" "$@"; }

# as_jeevo_in DIR command... — like as_jeevo, but inside DIR. Needed for
# anything that resolves modules relative to the working directory.
as_jeevo_in() {
  local dir="$1"
  shift
  runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" "${GIT_ENV[@]}" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

# Read-only git queries as root: the repo is owned by the service user, so git
# must be told to trust it ("dubious ownership").
gitv() { git -c safe.directory="$INSTALL_DIR" -C "$INSTALL_DIR" "$@"; }

install_node() {
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs
}

# The pnpm version the repository pins in its root package.json
# ("packageManager": "pnpm@X.Y.Z[+sha...]"). Prints X.Y.Z; fails if not pnpm.
pinned_pnpm() {
  local pm v
  pm="$(node -p "require('${INSTALL_DIR}/package.json').packageManager || ''" 2>/dev/null || true)"
  [[ "$pm" == pnpm@* ]] || return 1
  v="${pm#pnpm@}"
  v="${v%%+*}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  printf '%s' "$v"
}

# Install exactly the pinned pnpm globally (as root), unless it already matches.
ensure_pnpm() {
  local want have
  want="$(pinned_pnpm)" || return 1
  have="$(pnpm --version 2>/dev/null || true)"
  [[ "$have" == "$want" ]] && return 0
  npm install -g "pnpm@${want}"
}

reload_nginx() { systemctl reload nginx || systemctl restart nginx; }

health_check() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${PORT}/api/health" 2>/dev/null | grep -q '"ok"'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

main() {

umask 022
cd /
trap 'on_err "$?" "$LINENO"' ERR
trap on_interrupt INT TERM
trap show_cursor EXIT

printf '\n  %sJeevo%s %sinstaller%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
rule

# ------------------------------------------------------------ 1. system check

step "Checking your system"

[[ $EUID -eq 0 ]] || die "Run this installer as root: curl -fsSL <url>/install.sh | sudo bash"

install -m 600 /dev/null "$LOG"
printf 'Jeevo installer log — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG"
note "Details are written to ${LOG}"

# Prompts need a real terminal (stdin is the script when piped from curl).
if [[ "$ASSUME_YES" != 1 ]] && ! { : </dev/tty; } 2>/dev/null; then
  die "No terminal available for prompts. Re-run from an interactive terminal, or set JEEVO_ASSUME_YES=1 and preset the variables (AUTH_PASSWORD, GITHUB_TOKEN, VAPID_EMAIL, ...) in the environment."
fi

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; only Debian/Ubuntu are supported."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ok "${PRETTY_NAME:-$ID}" ;;
  *) die "Unsupported distribution '${ID:-unknown}'. Supported: Debian and Ubuntu." ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) ok "Architecture ${ARCH}" ;;
  *) die "Unsupported architecture '$ARCH'. Supported: x86_64 and aarch64." ;;
esac

if [[ -f "$CONF" ]]; then
  die "Jeevo is already installed (${CONF} exists). Use 'sudo jeevo update' to update it, or edit the installation by hand. This installer never overwrites an existing installation."
fi

command -v runuser >/dev/null 2>&1 || die "runuser is missing (package util-linux); it is required."
command -v flock  >/dev/null 2>&1 || die "flock is missing (package util-linux); it is required."
exec 9>/var/lock/jeevo-install.lock
flock -n 9 || die "Another jeevo installation is already running."

# ----------------------------------------------------------- 2. configuration

step "Configuration"
note "Press Enter to accept the default shown in [brackets]."

DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
DEFAULT_IP="${DEFAULT_IP:-127.0.0.1}"

section "Locations"
prompt INSTALL_DIR "Application directory" "/opt/jeevo" \
  "Program code. Safe to delete and re-create; updates replace it."
require_abs_path "$INSTALL_DIR" "Install directory"

prompt DATA_DIR "Media directory" "/srv/jeevo-data" \
  "Where uploads and artwork are stored. Can be a network mount (NFS/CIFS)."
require_abs_path "$DATA_DIR" "Data directory"

section "Network"
prompt PORT "Backend port" "3000" \
  "Internal port for the API. Only nginx on this machine should reach it."
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "PORT must be 1-65535 (got '$PORT')"

prompt SITE_URL "Public site URL" "http://${DEFAULT_IP}" \
  "How you will open Jeevo in a browser (also used for CORS)."
[[ "$SITE_URL" != *[[:space:]]* ]] || die "SITE_URL must not contain spaces."

prompt UPLOAD_MAX_MB "Max upload size (MB)" "$UPLOAD_MAX_MB"
[[ "$UPLOAD_MAX_MB" =~ ^[0-9]+$ ]] || die "UPLOAD_MAX_MB must be a number."

section "Source repository"
prompt REPO_URL "Git repository" "https://github.com/NotNecrotic/jeevo.git" \
  "Private is fine. Use an https:// URL with a token, or an SSH URL with a deploy key."

case "$REPO_URL" in
  https://*)                 GIT_KIND=https ;;
  ssh://*|git@*)             GIT_KIND=ssh ;;
  /*|file://*)               GIT_KIND=local ;;   # test/local mirrors only
  *) die "Repository URL must be https://…, git@…:… (SSH), or a local path." ;;
esac

case "$GIT_KIND" in
  https)
    prompt_secret GITHUB_TOKEN "GitHub access token" "" \
      "Fine-grained, read-only token: Repository permissions -> Contents: Read-only."
    [[ -n "$GITHUB_TOKEN" ]] || die "The token cannot be empty."
    ;;
  ssh)
    prompt KEY_SRC "Deploy key path" "" \
      "Private key file whose .pub is registered on GitHub as a read-only deploy key."
    [[ -f "${KEY_SRC:-}" ]] || die "No such key file: ${KEY_SRC:-<empty>}. Create one with 'ssh-keygen -t ed25519 -f jeevo_deploy_key -N \"\"' and register the .pub as a read-only deploy key on the repository."
    ;;
esac

section "Owner account"
prompt AUTH_USERNAME "Username" "admin" \
  "The first administrator. Created the first time Jeevo starts."
AUTH_PASSWORD_DEFAULT="$(openssl rand -base64 18 2>/dev/null || echo "changeme-$(date +%s)")"
prompt_secret AUTH_PASSWORD "Password (Enter = generate one)" "$AUTH_PASSWORD_DEFAULT" \
  "Change it later in the app. A generated password is shown once at the end."
if [[ "$AUTH_PASSWORD" == "$AUTH_PASSWORD_DEFAULT" ]]; then
  PW_GENERATED=1
  PW_SHOWN="$AUTH_PASSWORD"
fi

section "Push notifications (optional)"
while true; do
  prompt VAPID_EMAIL "Contact email (Enter to skip)" "" \
    "Push services require a contact address. It is only sent to the browser push servers (Apple, Google, Mozilla), never shown to users. Skip it and Jeevo works normally, but no push notifications are sent to phones."
  VAPID_EMAIL="${VAPID_EMAIL#mailto:}"
  VAPID_EMAIL="${VAPID_EMAIL//[[:space:]]/}"
  if [[ -z "$VAPID_EMAIL" || "$VAPID_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
  warn "'${VAPID_EMAIL}' does not look like an email address."
  [[ "$ASSUME_YES" != 1 ]] || die "VAPID_EMAIL is not a valid email address."
  VAPID_EMAIL=""
done
if [[ -n "$VAPID_EMAIL" ]]; then
  case "${VAPID_EMAIL##*@}" in
    example.com|example.org|example.net|localhost|*.local|*.test)
      warn "Apple rejects placeholder-looking contact domains. Use a real address."
      ;;
  esac
fi

section "Review"
kv "Code"         "$INSTALL_DIR"
kv "Media"        "$DATA_DIR"
kv "Site URL"     "$SITE_URL"
kv "API port"     "$PORT (internal)"
kv "Max upload"   "${UPLOAD_MAX_MB} MB"
kv "Repository"   "$REPO_URL"
kv "Owner"        "$AUTH_USERNAME"
kv "Push email"   "${VAPID_EMAIL:-none (push notifications off)}"
printf '\n'
if ! confirm "Install with these settings?" y; then
  printf '\n  Cancelled. Nothing was changed.\n\n'
  exit 0
fi

# ------------------------------------------------------- 3. system packages

step "System packages"
export DEBIAN_FRONTEND=noninteractive
run "Updating package lists" apt-get update -qq
# build-essential is a fallback for native modules (better-sqlite3) when no
# prebuilt binary matches this machine.
run "Installing git, nginx, ffmpeg, Python and build tools" \
  apt-get install -y -qq git curl ca-certificates openssl python3 python3-venv \
  python3-pip nginx ffmpeg util-linux build-essential

if ! command -v node >/dev/null 2>&1 \
  || [[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt "$NODE_MAJOR" ]]; then
  run "Installing Node.js ${NODE_MAJOR}" install_node
fi
NODE_FOUND="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_FOUND" -ge "$NODE_MAJOR" ]] || die "Node.js ${NODE_MAJOR}+ is required; found $(node --version)."
NODE_BIN="$(command -v node)"
ok "Node.js $(node --version), npm $(npm --version)"

PY_VER="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  if [[ "${JEEVO_SKIP_PYTHON_CHECK:-0}" == 1 ]]; then
    warn "Python ${PY_VER} is older than 3.9 (JEEVO_SKIP_PYTHON_CHECK=1)."
  else
    die "Python 3.9+ is required for the AI worker (found ${PY_VER}). Install python3.9+ and re-run."
  fi
else
  ok "Python ${PY_VER}"
fi

# -------------------------------------------------- 4. account + directories

step "Service account and folders"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  ok "User '${SERVICE_USER}' already exists"
else
  useradd --system --user-group --home-dir "$SERVICE_HOME" --create-home \
    --shell /usr/sbin/nologin "$SERVICE_USER"
  ok "Created system user '${SERVICE_USER}' (no login)"
fi

install -d -m 750 -o root -g "$SERVICE_USER" "$CONF_DIR"
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$SERVICE_HOME"
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$DATA_DIR" "$DATA_DIR/media-store" "$DATA_DIR/artwork"
ok "${CONF_DIR} ${DIM}(configuration, root-owned)${RESET}"
ok "${SERVICE_HOME} ${DIM}(database, pnpm store)${RESET}"
ok "${DATA_DIR} ${DIM}(media-store + artwork)${RESET}"
if ! mountpoint -q "$DATA_DIR"; then
  warn "${DATA_DIR} is not a mount point. Fine for a local disk. If this is"
  warn "network storage (NFS/CIFS), mount it there BEFORE the first start —"
  warn "the backend refuses to start when its media path is missing."
fi
runuser -u "$SERVICE_USER" -- touch "$DATA_DIR/.write-test" \
  && rm -f "$DATA_DIR/.write-test" \
  || die "$DATA_DIR is not writable by user '$SERVICE_USER'. Fix the permissions/mount and re-run."

# --------------------------------------------------- 5. repository + download

step "Downloading Jeevo"

case "$GIT_KIND" in
  https)
    TOKEN_FILE="${CONF_DIR}/git-credentials"
    install -m 640 -o root -g "$SERVICE_USER" /dev/null "$TOKEN_FILE"
    printf '%s' "$GITHUB_TOKEN" > "$TOKEN_FILE"
    unset GITHUB_TOKEN
    install -m 755 -o root -g "$SERVICE_USER" /dev/null "${CONF_DIR}/git-askpass.sh"
    cat > "${CONF_DIR}/git-askpass.sh" <<'ASKPASS'
#!/usr/bin/env bash
# git credential helper used ONLY through GIT_ASKPASS on our own git calls.
# Prints the stored token; never writes it anywhere else.
exec cat /etc/jeevo/git-credentials
ASKPASS
    GIT_ENV+=(
      "GIT_ASKPASS=${CONF_DIR}/git-askpass.sh"
      "SSH_ASKPASS=${CONF_DIR}/git-askpass.sh"
      "GIT_TERMINAL_PROMPT=0"
    )
    ok "Token stored in ${TOKEN_FILE} ${DIM}(mode 640, never logged)${RESET}"
    ;;
  ssh)
    install -m 600 -o root -g "$SERVICE_USER" "$KEY_SRC" "${CONF_DIR}/jeevo_deploy_key"
    SSH_HOST="$(printf '%s' "$REPO_URL" | sed -E 's#^ssh://##; s#^git@##; s#[/:].*$##')"
    [[ -n "$SSH_HOST" ]] || SSH_HOST=github.com
    ssh-keyscan -H "$SSH_HOST" > "${CONF_DIR}/known_hosts" 2>/dev/null \
      || die "Could not fetch host keys for ${SSH_HOST}."
    chmod 644 "${CONF_DIR}/known_hosts"
    GIT_ENV+=(
      "GIT_SSH_COMMAND=ssh -i ${CONF_DIR}/jeevo_deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=${CONF_DIR}/known_hosts -o StrictHostKeyChecking=yes"
      "GIT_TERMINAL_PROMPT=0"
    )
    ok "Deploy key stored in ${CONF_DIR}/jeevo_deploy_key ${DIM}(mode 600)${RESET}"
    ok "Host keys pinned for ${SSH_HOST}"
    ;;
  local)
    GIT_ENV+=("GIT_TERMINAL_PROMPT=0")
    ok "Local repository ${DIM}(no credentials needed)${RESET}"
    ;;
esac

FAIL_HINT="Cannot reach ${REPO_URL} with the supplied credentials. Check the URL, the token's access to the repository, or the deploy key. Nothing has been installed."
run "Checking repository access" as_jeevo git ls-remote --heads --tags "$REPO_URL"

# Which ref should `jeevo update` track? Versioned tags (v*) are preferred;
# tracking a plain development branch requires an explicit confirmation.
TAGS_OUT="$(as_jeevo git ls-remote --tags "$REPO_URL" 2>>"$LOG" || true)"
if grep -qE 'refs/tags/v[0-9]' <<<"$TAGS_OUT"; then
  UPDATE_MODE=tags
  REF=""
  ok "Release tags found ${DIM}(updates will follow the latest v* tag)${RESET}"
else
  UPDATE_MODE=ref
  warn "No v* release tags found on the repository."
  prompt REF "Branch that 'jeevo update' should track" "master"
  if ! confirm "'${REF}' is a development branch, not a release. Track it anyway?" n; then
    die "Aborted. Create versioned tags (v1.2.3) on the repository, or re-run and accept tracking ${REF}."
  fi
  note "Once v* tags exist, 'jeevo update' switches to the latest tag automatically."
fi

install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$INSTALL_DIR"
run "Cloning the repository" as_jeevo git clone --quiet "$REPO_URL" "$INSTALL_DIR"
ok "Version $(gitv describe --tags --always)"

# This installer only understands the pnpm monorepo layout. Fail early and
# clearly on anything else (for example an old backend/ + frontend/ checkout).
if [[ ! -f "$INSTALL_DIR/pnpm-workspace.yaml" || ! -d "$INSTALL_DIR/apps/api" \
   || ! -d "$INSTALL_DIR/apps/web" || ! -d "$INSTALL_DIR/apps/ai-worker" ]]; then
  die "This repository does not have the expected layout (pnpm-workspace.yaml, apps/api, apps/web, apps/ai-worker). This installer targets the pnpm monorepo and fresh installs only."
fi

# -------------------------------------------------------- 6. dependencies

step "Installing dependencies"

PNPM_WANT="$(pinned_pnpm)" \
  || die "The repository's package.json must pin pnpm in its \"packageManager\" field (found none)."
run "Installing pnpm ${PNPM_WANT}" ensure_pnpm

FAIL_HINT="pnpm install failed. If the log mentions ignored build scripts, check pnpm.onlyBuiltDependencies / allowBuilds for better-sqlite3, esbuild and ffmpeg-static."
run "Installing packages (pnpm)" as_jeevo pnpm --dir "$INSTALL_DIR" install --frozen-lockfile
FAIL_HINT="better-sqlite3 has no usable native build. Check the pnpm install section of the log for build errors."
run "Checking native modules" as_jeevo_in "$INSTALL_DIR/apps/api" \
  node -e 'new (require("better-sqlite3"))(":memory:").close()'

# The worker keeps its model cache inside the app directory; create it up front
# because the API unit lists it as a writable path (systemd refuses to start a
# unit whose ReadWritePaths entry does not exist).
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$INSTALL_DIR/apps/ai-worker/models"

run "Creating the Python environment" as_jeevo python3 -m venv "$INSTALL_DIR/apps/ai-worker/.venv"
run "Updating pip" as_jeevo "$INSTALL_DIR/apps/ai-worker/.venv/bin/python" -m pip install --quiet --upgrade pip
run "AI worker packages (pip)" as_jeevo "$INSTALL_DIR/apps/ai-worker/.venv/bin/python" -m pip install --quiet \
  -r "$INSTALL_DIR/apps/ai-worker/requirements.txt"

# ------------------------------------------------------ 7. configure + build

step "Configuring and building"

WORKER_TOKEN="$(openssl rand -hex 32)"
[[ -n "$WORKER_TOKEN" ]] || die "Could not generate WORKER_TOKEN (openssl failed)."

# Push (VAPID) keys: generated exactly once, here. The public key is handed to
# browsers; the private key signs every push. Regenerating either later would
# silently break every device's subscription, so neither `jeevo update` nor any
# other command ever touches them.
VAPID_PAIR="$(as_jeevo_in "$INSTALL_DIR/apps/api" node -e \
  'const w=require("web-push");const k=w.generateVAPIDKeys();process.stdout.write(k.publicKey+" "+k.privateKey)' \
  2>>"$LOG")" || die "Could not generate the push notification keys (web-push is part of apps/api)."
VAPID_PUBLIC_KEY="${VAPID_PAIR%% *}"
VAPID_PRIVATE_KEY="${VAPID_PAIR##* }"
[[ -n "$VAPID_PUBLIC_KEY" && -n "$VAPID_PRIVATE_KEY" && "$VAPID_PUBLIC_KEY" != "$VAPID_PRIVATE_KEY" ]] \
  || die "Push key generation returned unexpected output."
if [[ -n "$VAPID_EMAIL" ]]; then
  VAPID_SUBJECT="mailto:${VAPID_EMAIL}"
  PUSH_ENABLED=1
else
  VAPID_SUBJECT=""
  PUSH_ENABLED=0
fi

BACKEND_ENV="${CONF_DIR}/backend.env"
WORKER_ENV="${CONF_DIR}/worker.env"
install -m 640 -o root -g "$SERVICE_USER" /dev/null "$BACKEND_ENV"
install -m 640 -o root -g "$SERVICE_USER" /dev/null "$WORKER_ENV"

cat > "$BACKEND_ENV" <<EOF
# Jeevo backend configuration. Written by install.sh — edit deliberately.
# Loaded through the symlink at ${INSTALL_DIR}/apps/api/.env.
# The owner account below is only used the FIRST time the database is created;
# afterwards the database is authoritative (change it in the app UI).
NODE_ENV=production
PORT=${PORT}
HOST=127.0.0.1
CORS_ORIGIN=${SITE_URL}
TRUST_PROXY=true
AUTH_USERNAME=${AUTH_USERNAME}
AUTH_PASSWORD=${AUTH_PASSWORD}
DATABASE_PATH=${SERVICE_HOME}/jeevo.sqlite
ARTWORK_PATH=${DATA_DIR}/artwork
JEEVO_MEDIA_PATH=${DATA_DIR}/media-store
UPLOAD_MAX_MB=${UPLOAD_MAX_MB}
WORKER_TOKEN=${WORKER_TOKEN}
PROCESSING_ENABLED=true
NSFW_SYNC_SCAN=true
JEEVO_PYTHON=${INSTALL_DIR}/apps/ai-worker/.venv/bin/python
JEEVO_AI_WORKER_DIR=${INSTALL_DIR}/apps/ai-worker
JEEVO_MODEL_CACHE=${INSTALL_DIR}/apps/ai-worker/models
JEEVO_DEVICE=auto
NSFW_THRESHOLD=0.8

# Push notifications. NEVER regenerate this key pair on a running install:
# every device would have to turn notifications on again. Push stays off until
# VAPID_SUBJECT is a real mailto: address or https URL (then: jeevo restart api).
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
VAPID_PRIVATE_KEY=${VAPID_PRIVATE_KEY}
VAPID_SUBJECT=${VAPID_SUBJECT}
EOF

cat > "$WORKER_ENV" <<EOF
# Jeevo AI worker configuration. Written by install.sh — edit deliberately.
# Loaded through the symlink at ${INSTALL_DIR}/apps/ai-worker/.env.
JEEVO_BACKEND_URL=http://127.0.0.1:${PORT}
JEEVO_WORKER_TOKEN=${WORKER_TOKEN}
JEEVO_MODEL_CACHE=${INSTALL_DIR}/apps/ai-worker/models
JEEVO_DEVICE=auto
JEEVO_LOG_LEVEL=info
EOF
unset AUTH_PASSWORD WORKER_TOKEN VAPID_PRIVATE_KEY VAPID_PAIR

# The backend has no PATH fallback for ffmpeg: when the npm static build is
# missing (offline install, --omit=optional, an arch without a prebuild), the
# distro package installed above is used instead.
if [[ ! -x "$INSTALL_DIR/apps/api/node_modules/ffmpeg-static/ffmpeg" ]] \
  || [[ ! -e "$INSTALL_DIR/apps/api/node_modules/ffprobe-static" ]]; then
  {
    echo "FFMPEG_PATH=/usr/bin/ffmpeg"
    echo "FFPROBE_PATH=/usr/bin/ffprobe"
  } >> "$BACKEND_ENV"
  warn "npm ffmpeg/ffprobe binaries are missing; using the system ones."
fi

# The apps keep loading their own .env files; symlinks point them at the
# protected copies in /etc/jeevo so updates never touch configuration.
ln -sfn "$BACKEND_ENV" "$INSTALL_DIR/apps/api/.env"
ln -sfn "$WORKER_ENV"  "$INSTALL_DIR/apps/ai-worker/.env"
ok "Settings and secrets written to ${CONF_DIR}"
if [[ "$PUSH_ENABLED" == 1 ]]; then
  ok "Push notification keys generated ${DIM}(contact: ${VAPID_EMAIL})${RESET}"
else
  ok "Push notification keys generated ${DIM}(push is OFF until a contact email is set)${RESET}"
fi

# `pnpm -r run build` builds in dependency order (packages/shared first, then
# the API and the web app).
FAIL_HINT="The build failed. The web build also type-checks, so a TypeScript error in the repository stops the install. Fix it upstream or install a different version."
run "Building Jeevo (API and web app)" \
  as_jeevo env VITE_API_URL= pnpm --dir "$INSTALL_DIR" -r --if-present run build
[[ -f "$INSTALL_DIR/apps/api/dist/main.js" ]] \
  || die "The build finished but apps/api/dist/main.js is missing."
[[ -f "$INSTALL_DIR/apps/web/dist/index.html" ]] \
  || die "The build finished but apps/web/dist/index.html is missing."

# ---------------------------------------------------------- 8. services

step "Starting Jeevo"

if [[ "$SYSTEMD" == 1 ]]; then
  cat > /etc/systemd/system/jeevo-api.service <<EOF
[Unit]
Description=Jeevo API
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}/apps/api
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} dist/main.js
Restart=on-failure
RestartSec=5

# The API only ever writes inside its own data directories.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR} ${SERVICE_HOME} ${INSTALL_DIR}/apps/ai-worker/models

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/jeevo-worker.service <<EOF
[Unit]
Description=Jeevo AI worker (NSFW scanning)
After=network.target jeevo-api.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}/apps/ai-worker
ExecStart=${INSTALL_DIR}/apps/ai-worker/.venv/bin/python -m src.main
Restart=always
RestartSec=5

# Scanning is CPU-heavy; keep it out of the way of interactive work.
Nice=10

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}/apps/ai-worker/models

[Install]
WantedBy=multi-user.target
EOF
  ok "Service units installed ${DIM}(jeevo-api, jeevo-worker)${RESET}"

  SITE_HOST="$(printf '%s' "$SITE_URL" | sed -E 's#^https?://##; s#[/:].*$##')"
  [[ -n "$SITE_HOST" ]] || SITE_HOST="_"
  cat > /etc/nginx/sites-available/jeevo <<EOF
server {
    listen 80 default_server;
    server_name ${SITE_HOST};

    root ${INSTALL_DIR}/apps/web/dist;
    index index.html;

    # Uploads are multipart up to UPLOAD_MAX_MB; leave matching headroom.
    client_max_body_size ${UPLOAD_MAX_MB}m;

    # Video streaming must never be buffered by the proxy.
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location /api/ {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        # Pass the public host and scheme so generated media URLs are correct.
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
    }

    # Hashed assets are immutable; index.html, the service worker and the
    # manifest never are (a stale service worker would pin users to an old build).
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    location = /sw.js         { add_header Cache-Control "no-cache, must-revalidate"; }
    location = /registerSW.js { add_header Cache-Control "no-cache, must-revalidate"; }
    location = /manifest.webmanifest {
        default_type application/manifest+json;
        add_header Cache-Control "no-cache, must-revalidate";
    }
    location = /index.html    { add_header Cache-Control "no-cache, must-revalidate"; }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
  ln -sfn /etc/nginx/sites-available/jeevo /etc/nginx/sites-enabled/jeevo
  rm -f /etc/nginx/sites-enabled/default
  FAIL_HINT="The generated nginx configuration is invalid. Fix /etc/nginx/sites-available/jeevo and re-run."
  run "Checking the nginx configuration" nginx -t
  ok "nginx site 'jeevo' ${DIM}(port 80, ${SITE_HOST})${RESET}"

  systemctl daemon-reload
  run "Starting the API and AI worker" systemctl enable --now jeevo-api jeevo-worker
  run "Reloading nginx" reload_nginx

  if ! _run "Waiting for the API to respond" health_check; then
    dump_log_tail
    journalctl -u jeevo-api -n 30 --no-pager >&2 || true
    die "The API did not answer its health check within 30s. Fix the error above, then run: systemctl restart jeevo-api"
  fi
else
  warn "JEEVO_SYSTEMD=0: skipping systemd units and nginx (test/container mode)."
  # Test mode: boot the freshly built API directly, probe it, then stop it.
  as_jeevo_in "$INSTALL_DIR/apps/api" env NODE_ENV=production \
    "$NODE_BIN" dist/main.js >/tmp/jeevo-health.log 2>&1 &
  API_PID=$!
  if ! _run "Waiting for the API to respond (manual probe)" health_check; then
    cat /tmp/jeevo-health.log >&2 || true
    pkill -u "$SERVICE_USER" -f 'dist/main.js' 2>/dev/null || true
    kill "$API_PID" 2>/dev/null || true
    die "The API did not answer its health check."
  fi
  pkill -u "$SERVICE_USER" -f 'dist/main.js' 2>/dev/null || true
  kill "$API_PID" 2>/dev/null || true
  wait "$API_PID" 2>/dev/null || true
fi

# --------------------------------------------------- 9. metadata + admin CLI

step "Finishing up"

VERSION_SHA="$(gitv rev-parse --short=12 HEAD)"
VERSION_DESC="$(gitv describe --tags --always 2>/dev/null || echo "$VERSION_SHA")"

install -m 640 -o root -g "$SERVICE_USER" /dev/null "$CONF"
cat > "$CONF" <<EOF
# Jeevo installation metadata. Written by install.sh; read by the jeevo CLI.
# Secrets are NOT stored here — they live in backend.env / worker.env.
INSTALL_DIR=${INSTALL_DIR}
DATA_DIR=${DATA_DIR}
SERVICE_HOME=${SERVICE_HOME}
PORT=${PORT}
SITE_URL=${SITE_URL}
REPO_URL=${REPO_URL}
GIT_KIND=${GIT_KIND}
UPDATE_MODE=${UPDATE_MODE}
REF=${REF}
SYSTEMD=${SYSTEMD}
UPLOAD_MAX_MB=${UPLOAD_MAX_MB}
VERSION=${VERSION_SHA}
VERSION_DESC=${VERSION_DESC}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
ok "Installation record written ${DIM}(${CONF})${RESET}"

cat > "$BIN_PATH" <<'JEEVO_CLI'
#!/usr/bin/env bash
#
# jeevo — admin CLI for an installation made by scripts/install.sh.
#
#   jeevo --help
#   jeevo version                       installed version
#   jeevo status                        services + health overview
#   jeevo logs [api|worker] [lines]     follow logs (or print the last N lines)
#   jeevo restart [api|worker|all]      restart services
#   sudo jeevo update [--yes] [--ref X] update to the newest tracked release
#
set -euo pipefail

CONF=/etc/jeevo/install.conf
SERVICE_USER=jeevo
LOG=/var/log/jeevo-update.log

# ---- terminal UI (same look as the installer) -----------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  TTY_UI=1
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  TTY_UI=0
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) UTF=1 ;;
  *) UTF=0 ;;
esac
if [[ "$UTF" == 1 ]]; then
  S_OK="✔"; S_FAIL="✘"; S_WARN="▲"; S_ARROW="›"
  SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  S_OK="ok"; S_FAIL="xx"; S_WARN="!!"; S_ARROW=">"
  SPIN=('-' '\' '|' '/')
fi

ok()   { printf '  %s%s%s %s\n' "$GREEN" "$S_OK" "$RESET" "$*"; }
warn() { printf '  %s%s%s %s\n' "$YELLOW" "$S_WARN" "$RESET" "$*" >&2; }
kv()   { printf '  %s%-10s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }
die()  { printf '  %s%s%s %s\n' "$RED" "$S_FAIL" "$RESET" "$*" >&2; exit 1; }
trap 'if [[ "$TTY_UI" == 1 ]]; then printf "\033[?25h"; fi' EXIT

# _run "Message" command... — output goes to $LOG; spinner while it runs.
_run() {
  local msg="$1" start=$SECONDS rc=0 pid i=0 t extra=""
  shift
  printf '\n[%s] %s\n' "$(date +%T)" "$msg" >>"$LOG"
  if [[ "$TTY_UI" == 1 ]]; then
    "$@" >>"$LOG" 2>&1 </dev/null &
    pid=$!
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r\033[K  %s%s%s %s %s%ds%s' \
        "$CYAN" "${SPIN[i % ${#SPIN[@]}]}" "$RESET" "$msg" "$DIM" "$((SECONDS - start))" "$RESET"
      i=$((i + 1))
      sleep 0.1
    done
    wait "$pid" || rc=$?
    printf '\r\033[K\033[?25h'
  else
    printf '  ... %s\n' "$msg"
    "$@" >>"$LOG" 2>&1 </dev/null || rc=$?
  fi
  t=$((SECONDS - start))
  if [[ "$t" -ge 2 ]]; then extra=" ${DIM}(${t}s)${RESET}"; fi
  if [[ "$rc" -eq 0 ]]; then
    printf '  %s%s%s %s%s\n' "$GREEN" "$S_OK" "$RESET" "$msg" "$extra"
  else
    printf '  %s%s%s %s\n' "$RED" "$S_FAIL" "$RESET" "$msg" >&2
  fi
  return "$rc"
}

tail_log() {
  printf '\n  %sLast lines of %s:%s\n' "$DIM" "$LOG" "$RESET" >&2
  tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
}
# ---------------------------------------------------------------------------

[[ -f "$CONF" ]] || die "no installation found (${CONF} is missing)"

get() { sed -n "s/^$1=//p" "$CONF" | head -1; }
INSTALL_DIR="$(get INSTALL_DIR)"
PORT="$(get PORT)"
UPDATE_MODE="$(get UPDATE_MODE)"
REF="$(get REF)"
GIT_KIND="$(get GIT_KIND)"
SYSTEMD="$(get SYSTEMD)"
SERVICE_HOME="$(get SERVICE_HOME)"

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; }

require_root() { [[ $EUID -eq 0 ]] || die "run this command with sudo"; }
require_systemd() { [[ "$SYSTEMD" == 1 ]] || die "this installation has systemd integration disabled"; }

# Read-only git queries as root (the repo belongs to the service user).
cgit() { git -c safe.directory="$INSTALL_DIR" -C "$INSTALL_DIR" "$@"; }

# All git/pnpm/pip operations run as the service user with the stored auth.
git_env() {
  local -a envs=("HOME=${SERVICE_HOME:-/var/lib/jeevo}" "GIT_TERMINAL_PROMPT=0")
  case "$GIT_KIND" in
    https)
      envs+=("GIT_ASKPASS=/etc/jeevo/git-askpass.sh" "SSH_ASKPASS=/etc/jeevo/git-askpass.sh")
      ;;
    ssh)
      envs+=("GIT_SSH_COMMAND=ssh -i /etc/jeevo/jeevo_deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/etc/jeevo/known_hosts -o StrictHostKeyChecking=yes")
      ;;
  esac
  runuser -u "$SERVICE_USER" -- env "${envs[@]}" "$@"
}

# The pnpm version the (newly checked-out) repository pins in package.json.
pinned_pnpm() {
  local pm v
  pm="$(node -p "require('${INSTALL_DIR}/package.json').packageManager || ''" 2>/dev/null || true)"
  [[ "$pm" == pnpm@* ]] || return 1
  v="${pm#pnpm@}"
  v="${v%%+*}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  printf '%s' "$v"
}

# A release can bump the pinned pnpm, so match it before installing packages.
ensure_pnpm() {
  local want have
  want="$(pinned_pnpm)" || { echo "package.json does not pin pnpm in packageManager" >&2; return 1; }
  have="$(pnpm --version 2>/dev/null || true)"
  [[ "$have" == "$want" ]] && return 0
  npm install -g "pnpm@${want}"
}

api_healthy() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${PORT}/api/health" 2>/dev/null | grep -q '"ok"'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

usage_update() { echo "usage: jeevo update [--yes] [--ref <tag-or-branch>]"; }

do_update() {
  local yes=0 explicit_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      --ref)
        explicit_ref="${2:-}"
        [[ -n "$explicit_ref" ]] || { usage_update >&2; exit 2; }
        shift
        ;;
      -h|--help) usage_update; exit 0 ;;
      *) usage_update >&2; exit 2 ;;
    esac
    shift
  done
  require_root

  # One update at a time.
  exec 9>/var/lock/jeevo-update.lock
  flock -n 9 || die "another update is already running"
  install -m 600 /dev/null "$LOG"

  printf '\n  %sJeevo update%s\n\n' "$BOLD" "$RESET"

  if ! _run "Checking for updates" git_env git -C "$INSTALL_DIR" fetch --tags --quiet origin; then
    tail_log
    die "fetch failed — check the stored credentials (INSTALL.md, 'Private repository authentication'). The current installation is untouched."
  fi

  local current target
  current="$(cgit rev-parse HEAD)"
  if [[ -n "$explicit_ref" ]]; then
    target="$(cgit rev-parse --verify -q "refs/tags/${explicit_ref}^{commit}" || true)"
    [[ -n "$target" ]] || target="$(cgit rev-parse --verify -q "refs/remotes/origin/${explicit_ref}^{commit}" || true)"
    [[ -n "$target" ]] || die "unknown ref '${explicit_ref}' (not a tag, nor a branch on origin)"
  elif [[ "$UPDATE_MODE" == tags ]]; then
    local latest
    latest="$(cgit tag -l 'v[0-9]*' | sort -V | tail -1)"
    [[ -n "$latest" ]] || die "UPDATE_MODE=tags but no v* tags found. Publish a tag, or run: sudo jeevo update --ref <branch>"
    target="$(cgit rev-parse "refs/tags/${latest}^{commit}")"
  else
    target="$(cgit rev-parse --verify -q "refs/remotes/origin/${REF}^{commit}" || true)"
    [[ -n "$target" ]] || die "branch '${REF}' not found on origin"
  fi

  local cur_desc tgt_desc
  cur_desc="$(cgit describe --tags --always HEAD)"
  tgt_desc="$(cgit describe --tags --always "$target")"
  kv "Installed" "${cur_desc} ${DIM}($(cgit log -1 --format=%cs HEAD))${RESET}"
  kv "Available" "${tgt_desc} ${DIM}($(cgit log -1 --format=%cs "$target"))${RESET}"
  printf '\n'

  if [[ "$current" == "$target" ]]; then
    ok "Already up to date."
    printf '\n'
    exit 0
  fi

  if [[ "$yes" != 1 ]]; then
    local reply
    read -r -p "  ${CYAN}?${RESET} Update now? ${DIM}[y/N]${RESET} ${S_ARROW} " reply || reply=""
    if [[ "$reply" != y && "$reply" != Y ]]; then
      printf '\n  Aborted. Nothing was changed.\n\n'
      exit 0
    fi
    printf '\n'
  fi

  # Record the previous version for the manual recovery instructions printed on
  # failure. This is NOT automatic rollback — nothing is restored by itself.
  sed -i "/^PREV_VERSION=.*/d" "$CONF"
  echo "PREV_VERSION=${current}" >> "$CONF"

  fail_recover() {
    tail_log
    echo >&2
    printf '  %s%s%s Update failed: %s\n' "$RED" "$S_FAIL" "$RESET" "$*" >&2
    echo "    The services were NOT restarted. The database, configuration and media" >&2
    echo "    were not touched. To retry:     sudo jeevo update" >&2
    echo "    To try the previous version:    sudo jeevo update --ref $(cgit rev-parse --short=12 "$current")" >&2
    if [[ "$SYSTEMD" == 1 ]]; then
      echo "    Recent API logs (if it started at some point):" >&2
      journalctl -u jeevo-api -n 20 --no-pager >&2 2>/dev/null || true
    fi
    exit 1
  }
  # step "Message" command... — run it, or stop with recovery instructions.
  step() {
    local msg="$1"
    _run "$@" || fail_recover "$msg"
  }

  if [[ "$SYSTEMD" == 1 ]]; then
    systemctl stop jeevo-api jeevo-worker 2>/dev/null || true
    ok "Stopped services"
  fi

  step "Checking out ${tgt_desc}" git_env git -C "$INSTALL_DIR" checkout -f --detach "$target"
  step "Matching the pinned pnpm version" ensure_pnpm
  step "Installing packages (pnpm)" git_env pnpm --dir "$INSTALL_DIR" install --frozen-lockfile
  if [[ ! -x "$INSTALL_DIR/apps/ai-worker/.venv/bin/python" ]]; then
    step "Creating the Python environment" git_env python3 -m venv "$INSTALL_DIR/apps/ai-worker/.venv"
  fi
  step "Updating pip" git_env "$INSTALL_DIR/apps/ai-worker/.venv/bin/python" -m pip install --quiet --upgrade pip
  step "AI worker packages (pip)" git_env "$INSTALL_DIR/apps/ai-worker/.venv/bin/python" -m pip install --quiet \
    -r "$INSTALL_DIR/apps/ai-worker/requirements.txt"
  step "Building Jeevo (API and web app)" \
    git_env env VITE_API_URL= pnpm --dir "$INSTALL_DIR" -r --if-present run build

  # Database migrations are additive and run automatically the next time the
  # API starts (apps/api/src/db/db.ts). Nothing here touches the database, the
  # configuration, or the push (VAPID) keys in backend.env.
  sed -i "s/^VERSION=.*/VERSION=$(cgit rev-parse --short=12 HEAD)/" "$CONF"
  sed -i "s/^VERSION_DESC=.*/VERSION_DESC=$(cgit describe --tags --always 2>/dev/null || true)/" "$CONF"

  if [[ "$SYSTEMD" == 1 ]]; then
    step "Starting services" systemctl start jeevo-api jeevo-worker
    step "Waiting for the API to respond" api_healthy
    printf '\n  %s%s Updated to %s%s\n\n' "$GREEN$BOLD" "$S_OK" "$tgt_desc" "$RESET"
  else
    printf '\n  %s%s Updated to %s%s %s(systemd disabled; start the API manually to verify)%s\n\n' \
      "$GREEN$BOLD" "$S_OK" "$tgt_desc" "$RESET" "$DIM" "$RESET"
  fi
}

cmd_status() {
  if [[ "$SYSTEMD" == 1 ]]; then
    systemctl status jeevo-api jeevo-worker --no-pager -l || true
  else
    echo "systemd integration disabled for this installation"
  fi
  echo
  echo -n "API health: "
  curl -fsS "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || echo "not answering"
  echo
}

cmd_logs() {
  local svc="${1:-api}" lines="${2:-}"
  case "$svc" in
    api|worker) ;;
    *) die "unknown service '$svc' (use: api or worker)" ;;
  esac
  require_systemd
  if [[ -n "$lines" ]]; then
    [[ "$lines" =~ ^[0-9]+$ ]] || die "lines must be a number"
    journalctl -u "jeevo-${svc}" -n "$lines" --no-pager
  else
    journalctl -u "jeevo-${svc}" -f
  fi
}

cmd_restart() {
  local what="${1:-all}"
  require_root
  require_systemd
  case "$what" in
    api)    systemctl restart jeevo-api ;;
    worker) systemctl restart jeevo-worker ;;
    all)    systemctl restart jeevo-api jeevo-worker ;;
    *) die "unknown target '$what' (use: api, worker or all)" ;;
  esac
  ok "Restarted: $what"
}

case "${1:-}" in
  --help|-h|help|"") usage ;;
  version)  echo "$(get VERSION_DESC) ($(get VERSION), installed $(get INSTALLED_AT))" ;;
  status)   cmd_status ;;
  logs)     shift; cmd_logs "$@" ;;
  restart)  shift; cmd_restart "$@" ;;
  update)   shift; do_update "$@" ;;
  *)        die "unknown command '$1' (try: jeevo --help)" ;;
esac
JEEVO_CLI
chmod 755 "$BIN_PATH"
ok "Admin command installed ${DIM}(${BIN_PATH})${RESET}"

# ---------------------------------------------------------------- summary

printf '\n'
rule
printf '  %s%s Jeevo is installed%s\n' "${GREEN}${BOLD}" "$S_OK" "$RESET"
rule

section "Sign in"
kv "Open"      "${BOLD}${SITE_URL}${RESET}"
kv "Username"  "$AUTH_USERNAME"
if [[ "$PW_GENERATED" == 1 ]]; then
  kv "Password" "${BOLD}${PW_SHOWN}${RESET}  ${DIM}(generated — save it now, it is not shown again)${RESET}"
else
  kv "Password" "the one you entered"
fi
note "The password is only used on first start. Change it in Settings -> Administration -> Users."

section "Push notifications"
if [[ "$PUSH_ENABLED" == 1 ]]; then
  kv "Status" "enabled ${DIM}(contact: ${VAPID_EMAIL})${RESET}"
else
  kv "Status" "${BOLD}off${RESET} ${DIM}(no contact email was given)${RESET}"
  note "To turn it on, set VAPID_SUBJECT=mailto:you@yourdomain in ${BACKEND_ENV}"
  note "then run: sudo jeevo restart api"
fi
note "The key pair was generated once and lives in backend.env. Never regenerate"
note "it: every phone would have to turn notifications on again."

section "Where things are"
kv "Version"   "${VERSION_DESC} (${VERSION_SHA})"
kv "Code"      "$INSTALL_DIR"
kv "Config"    "${BACKEND_ENV}, ${WORKER_ENV}"
kv "Database"  "${SERVICE_HOME}/jeevo.sqlite"
kv "Media"     "${DATA_DIR}/media-store, ${DATA_DIR}/artwork"
kv "Install log" "$LOG"

section "Manage"
kv "Status"    "jeevo status"
kv "Logs"      "jeevo logs api   |   jeevo logs worker"
kv "Restart"   "sudo jeevo restart"
kv "Update"    "sudo jeevo update"

printf '\n'
warn "HTTPS is not configured. Push notifications and installing Jeevo as an"
warn "app on phones only work over HTTPS, so put a certificate in front of nginx"
warn "yourself (for example: certbot --nginx)."
warn "After switching to https://, set CORS_ORIGIN to the new address in"
warn "${BACKEND_ENV} and run: sudo jeevo restart api"
printf '\n'

}

# Everything above is only DEFINITIONS; nothing has executed yet. Because this
# is the last line, bash has read the entire script before running main().
main "$@"
