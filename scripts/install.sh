#!/usr/bin/env bash
#
# Jeevo — Linux installer.
#
# Installs Jeevo (Node backend API + web bundle + Python AI worker) as
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
#     /etc/jeevo            configuration, secrets, install metadata
#     /var/lib/jeevo        database (host storage) + service user home
#     <data dir>            LARGE FILES: media-store/ and artwork/
#                           (point this at your network storage if you like)
#     /usr/local/bin/jeevo  admin CLI
#     systemd units: jeevo-api, jeevo-worker; nginx site "jeevo"
#
# It never overwrites an existing installation: if /etc/jeevo/install.conf
# exists the script exits and tells you to use `sudo jeevo update` instead.
#
# The repository is private; the installer never contains credentials. You
# provide either a read-only GitHub token or a read-only SSH deploy key at
# install time, and it is stored under /etc/jeevo with tight permissions.
#
# What you see: a numbered step list with a spinner for slow tasks. All
# command output (apt, npm, pip, build...) goes to /var/log/jeevo-install.log
# and is shown only if something fails.
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
#         GITHUB_TOKEN=... AUTH_PASSWORD=... bash
#
set -Eeuo pipefail

CONF_DIR=/etc/jeevo
CONF="${CONF_DIR}/install.conf"
BIN_PATH=/usr/local/bin/jeevo
SERVICE_USER=jeevo
SERVICE_HOME=/var/lib/jeevo
LOG=/var/log/jeevo-install.log

SYSTEMD="${JEEVO_SYSTEMD:-1}"
ASSUME_YES="${JEEVO_ASSUME_YES:-0}"
UPLOAD_MAX_MB=2048

TOTAL_STEPS=9
STEP=0
FAIL_HINT=""
PW_GENERATED=0
PW_SHOWN=""

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

# read_masked VAR — read from the terminal, echoing one * per character.
# Handles paste and backspace; Enter finishes.
read_masked() {
  local __var="$1" __ch __buf=""
  while IFS= read -r -s -n1 __ch </dev/tty; do
    if [[ -z "$__ch" ]]; then break; fi
    if [[ "$__ch" == $'\x7f' || "$__ch" == $'\b' ]]; then
      if [[ -n "$__buf" ]]; then __buf="${__buf%?}"; printf '\b \b'; fi
    elif [[ "$__ch" == $'\x1b' ]]; then
      continue
    else
      __buf+="$__ch"
      printf '*'
    fi
  done
  printf '\n'
  printf -v "$__var" '%s' "$__buf"
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
    printf '  %s%s%s %s %s ' "$CYAN" "$S_Q" "$RESET" "$q" "$S_ARROW"
    read_masked reply
    if [[ -z "$reply" && -n "$def" ]]; then
      reply="$def"
      printf '  %s(using the generated value)%s\n' "$DIM" "$RESET"
    elif [[ -n "$reply" ]]; then
      printf '  %sreceived %d characters%s\n' "$DIM" "${#reply}" "$RESET"
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

# All git operations run as the service user, with the configured auth
# environment. Filled in during the authentication phase.
GIT_ENV=()
as_jeevo() { runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" "${GIT_ENV[@]}" "$@"; }

# Read-only git queries as root: the repo is owned by the service user, so git
# must be told to trust it ("dubious ownership").
gitv() { git -c safe.directory="$INSTALL_DIR" -C "$INSTALL_DIR" "$@"; }

install_node() {
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
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
  die "No terminal available for prompts. Re-run from an interactive terminal, or set JEEVO_ASSUME_YES=1 and preset the variables (AUTH_PASSWORD, GITHUB_TOKEN, ...) in the environment."
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

section "Review"
kv "Code"         "$INSTALL_DIR"
kv "Media"        "$DATA_DIR"
kv "Site URL"     "$SITE_URL"
kv "API port"     "$PORT (internal)"
kv "Max upload"   "${UPLOAD_MAX_MB} MB"
kv "Repository"   "$REPO_URL"
kv "Owner"        "$AUTH_USERNAME"
printf '\n'
if ! confirm "Install with these settings?" y; then
  printf '\n  Cancelled. Nothing was changed.\n\n'
  exit 0
fi

# ------------------------------------------------------- 3. system packages

step "System packages"
export DEBIAN_FRONTEND=noninteractive
run "Updating package lists" apt-get update -qq
run "Installing git, nginx, ffmpeg and Python" \
  apt-get install -y -qq git curl ca-certificates openssl python3 python3-venv \
  python3-pip nginx ffmpeg util-linux

if ! command -v node >/dev/null 2>&1 \
  || [[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 20 ]]; then
  run "Installing Node.js 20" install_node
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 20 ]] || die "Node.js 20+ is required; found $(node --version)."
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
ok "${SERVICE_HOME} ${DIM}(database)${RESET}"
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

# -------------------------------------------------------- 6. dependencies

step "Installing dependencies"
run "Backend packages (npm)"  as_jeevo npm --prefix "$INSTALL_DIR/backend" ci --no-audit --no-fund
run "Frontend packages (npm)" as_jeevo npm --prefix "$INSTALL_DIR/frontend" ci --no-audit --no-fund
run "Creating the Python environment" as_jeevo python3 -m venv "$INSTALL_DIR/ai-worker/.venv"
run "Updating pip" as_jeevo "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet --upgrade pip
run "AI worker packages (pip)" as_jeevo "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet \
  -r "$INSTALL_DIR/ai-worker/requirements.txt"

# ------------------------------------------------------ 7. configure + build

step "Configuring and building"

WORKER_TOKEN="$(openssl rand -hex 32)"
[[ -n "$WORKER_TOKEN" ]] || die "Could not generate WORKER_TOKEN (openssl failed)."

BACKEND_ENV="${CONF_DIR}/backend.env"
WORKER_ENV="${CONF_DIR}/worker.env"
install -m 640 -o root -g "$SERVICE_USER" /dev/null "$BACKEND_ENV"
install -m 640 -o root -g "$SERVICE_USER" /dev/null "$WORKER_ENV"

cat > "$BACKEND_ENV" <<EOF
# Jeevo backend configuration. Written by install.sh — edit deliberately.
# Loaded through the symlink at ${INSTALL_DIR}/backend/.env.
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
JEEVO_PYTHON=${INSTALL_DIR}/ai-worker/.venv/bin/python
JEEVO_AI_WORKER_DIR=${INSTALL_DIR}/ai-worker
JEEVO_MODEL_CACHE=${INSTALL_DIR}/ai-worker/models
JEEVO_DEVICE=auto
NSFW_THRESHOLD=0.8
EOF

cat > "$WORKER_ENV" <<EOF
# Jeevo AI worker configuration. Written by install.sh — edit deliberately.
# Loaded through the symlink at ${INSTALL_DIR}/ai-worker/.env.
JEEVO_BACKEND_URL=http://127.0.0.1:${PORT}
JEEVO_WORKER_TOKEN=${WORKER_TOKEN}
JEEVO_MODEL_CACHE=${INSTALL_DIR}/ai-worker/models
JEEVO_DEVICE=auto
JEEVO_LOG_LEVEL=info
EOF
unset AUTH_PASSWORD WORKER_TOKEN

# The backend has no PATH fallback for ffmpeg: when the npm static build is
# missing (offline install, --omit=optional, an arch without a prebuild), the
# distro package installed above is used instead.
if [[ ! -x "$INSTALL_DIR/backend/node_modules/ffmpeg-static/ffmpeg" ]] \
  || [[ ! -e "$INSTALL_DIR/backend/node_modules/ffprobe-static" ]]; then
  {
    echo "FFMPEG_PATH=/usr/bin/ffmpeg"
    echo "FFPROBE_PATH=/usr/bin/ffprobe"
  } >> "$BACKEND_ENV"
  warn "npm ffmpeg/ffprobe binaries are missing; using the system ones."
fi

# The apps keep loading their own .env files; symlinks point them at the
# protected copies in /etc/jeevo so updates never touch configuration.
ln -sfn "$BACKEND_ENV" "$INSTALL_DIR/backend/.env"
ln -sfn "$WORKER_ENV"  "$INSTALL_DIR/ai-worker/.env"
ok "Settings and secrets written to ${CONF_DIR}"

run "Building the backend"  as_jeevo npm --prefix "$INSTALL_DIR/backend" run build
run "Building the web app"  as_jeevo env VITE_API_URL= npm --prefix "$INSTALL_DIR/frontend" run build

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
WorkingDirectory=${INSTALL_DIR}/backend
Environment=NODE_ENV=production
ExecStart=/usr/bin/node dist/main.js
Restart=on-failure
RestartSec=5

# The API only ever writes inside its own data directories.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR} ${SERVICE_HOME} ${INSTALL_DIR}/ai-worker/models

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
WorkingDirectory=${INSTALL_DIR}/ai-worker
ExecStart=${INSTALL_DIR}/ai-worker/.venv/bin/python -m src.main
Restart=always
RestartSec=5

# Scanning is CPU-heavy; keep it out of the way of interactive work.
Nice=10

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}/ai-worker/models

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

    root ${INSTALL_DIR}/frontend/dist;
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

    # Hashed assets are immutable; index.html and the service worker never are.
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    location = /sw.js      { add_header Cache-Control "no-cache, must-revalidate"; }
    location = /index.html { add_header Cache-Control "no-cache, must-revalidate"; }
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
  runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" NODE_ENV=production \
    node dist/main.js >/tmp/jeevo-health.log 2>&1 &
  API_PID=$!
  if ! _run "Waiting for the API to respond (manual probe)" health_check; then
    cat /tmp/jeevo-health.log >&2 || true
    kill "$API_PID" 2>/dev/null || true
    die "The API did not answer its health check."
  fi
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

# All git/npm/pip operations run as the service user with the stored auth.
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
  step "Backend packages (npm)"  git_env npm --prefix "$INSTALL_DIR/backend" ci --no-audit --no-fund
  step "Frontend packages (npm)" git_env npm --prefix "$INSTALL_DIR/frontend" ci --no-audit --no-fund
  if [[ ! -x "$INSTALL_DIR/ai-worker/.venv/bin/python" ]]; then
    step "Creating the Python environment" git_env python3 -m venv "$INSTALL_DIR/ai-worker/.venv"
  fi
  step "Updating pip" git_env "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet --upgrade pip
  step "AI worker packages (pip)" git_env "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet \
    -r "$INSTALL_DIR/ai-worker/requirements.txt"
  step "Building the backend" git_env npm --prefix "$INSTALL_DIR/backend" run build
  step "Building the web app" git_env env VITE_API_URL= npm --prefix "$INSTALL_DIR/frontend" run build

  # Database migrations are additive and run automatically the next time the
  # API starts (backend/src/db/db.ts). Nothing here touches the database.
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
warn "TLS is not configured. Before exposing Jeevo beyond your LAN, put a"
warn "certificate in front of nginx (e.g. certbot) and see INSTALL.md."
printf '\n'

}

# Everything above is only DEFINITIONS; nothing has executed yet. Because this
# is the last line, bash has read the entire script before running main().
main "$@"
