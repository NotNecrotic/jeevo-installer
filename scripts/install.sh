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
#
# Unattended piped install (sudo strips the environment, so pass it via env):
#     curl -fsSL <url>/install.sh | sudo env JEEVO_ASSUME_YES=1 \
#         GITHUB_TOKEN=... AUTH_PASSWORD=... bash
#
set -euo pipefail

CONF_DIR=/etc/jeevo
CONF="${CONF_DIR}/install.conf"
BIN_PATH=/usr/local/bin/jeevo
SERVICE_USER=jeevo
SERVICE_HOME=/var/lib/jeevo

SYSTEMD="${JEEVO_SYSTEMD:-1}"
ASSUME_YES="${JEEVO_ASSUME_YES:-0}"
UPLOAD_MAX_MB=2048

info() { printf '\n\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[0;32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[0;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '  \033[0;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# prompt VAR "Question" "default" — default wins on empty input (and always,
# in JEEVO_ASSUME_YES mode). A variable already set in the environment wins
# over everything (used by the automated tests and for scripted installs).
# Input is read from /dev/tty so that piped installs (curl | bash) work.
prompt() {
  local var="$1" q="$2" def="$3" reply
  if [[ -n "${!var:-}" ]]; then
    printf '  %s [%s] %s (from environment)\n' "$q" "$def" "${!var}"
    return
  fi
  if [[ "$ASSUME_YES" == 1 ]]; then
    printf -v "$var" '%s' "$def"
    printf '  %s [%s] %s\n' "$q" "$def" "$def"
    return
  fi
  read -r -p "  $q [$def]: " reply </dev/tty || true
  printf -v "$var" '%s' "${reply:-$def}"
}

# prompt_secret VAR "Question" [default] — input is not echoed.
prompt_secret() {
  local var="$1" q="$2" def="${3:-}" reply
  if [[ -n "${!var:-}" ]]; then
    printf '  %s [hidden] (from environment)\n' "$q"
    return
  fi
  if [[ "$ASSUME_YES" == 1 ]]; then
    printf -v "$var" '%s' "$def"
    printf '  %s [hidden]\n' "$q"
    return
  fi
  while true; do
    read -r -s -p "  $q: " reply </dev/tty
    printf '\n'
    reply="${reply:-$def}"
    if [[ -n "$reply" ]]; then printf -v "$var" '%s' "$reply"; return; fi
    printf '  (cannot be empty)\n'
  done
}

require_abs_path() {
  [[ "$1" == /* && "$1" != *[[:space:]]* ]] \
    || die "$2 must be an absolute path without spaces (got: '$1')"
}

# All git operations run as the service user, with the configured auth
# environment. Filled in during the authentication phase.
GIT_ENV=()
as_jeevo() { runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" "${GIT_ENV[@]}" "$@"; }

main() {

# ---------------------------------------------------------------- 0. guards

info "Checking the system"

[[ $EUID -eq 0 ]] || die "Run this installer as root: curl -fsSL <url>/install.sh | sudo bash"

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
  x86_64|aarch64) ok "architecture $ARCH" ;;
  *) die "Unsupported architecture '$ARCH'. Supported: x86_64 and aarch64." ;;
esac

if [[ -f "$CONF" ]]; then
  die "Jeevo is already installed (${CONF} exists). Use 'sudo jeevo update' to update it, or edit the installation by hand. This installer never overwrites an existing installation."
fi

command -v runuser >/dev/null 2>&1 || die "runuser is missing (package util-linux); it is required."
command -v flock  >/dev/null 2>&1 || die "flock is missing (package util-linux); it is required."
exec 9>/var/lock/jeevo-install.lock
flock -n 9 || die "Another jeevo installation is already running."

# ---------------------------------------------------------------- 1. prompts

info "Install options (press Enter to accept the shown default)"

DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
DEFAULT_IP="${DEFAULT_IP:-127.0.0.1}"

prompt INSTALL_DIR "Application install directory (code; replaceable)" "/opt/jeevo"
require_abs_path "$INSTALL_DIR" "Install directory"

prompt DATA_DIR "Data directory for LARGE FILES (uploads + artwork; may be network storage)" "/srv/jeevo-data"
require_abs_path "$DATA_DIR" "Data directory"

prompt PORT "Backend port (only nginx and loopback should reach it)" "3000"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "PORT must be 1-65535 (got '$PORT')"

prompt SITE_URL "Public site URL (shown at the end; used for CORS)" "http://${DEFAULT_IP}"
[[ "$SITE_URL" != *[[:space:]]* ]] || die "SITE_URL must not contain spaces."

prompt UPLOAD_MAX_MB "Maximum upload size in MB" "$UPLOAD_MAX_MB"
[[ "$UPLOAD_MAX_MB" =~ ^[0-9]+$ ]] || die "UPLOAD_MAX_MB must be a number."

prompt REPO_URL "Jeevo git repository (private is fine)" "https://github.com/NotNecrotic/jeevo.git"

case "$REPO_URL" in
  https://*)                 GIT_KIND=https ;;
  ssh://*|git@*)             GIT_KIND=ssh ;;
  /*|file://*)               GIT_KIND=local ;;   # test/local mirrors only
  *) die "Repository URL must be https://…, git@…:… (SSH), or a local path." ;;
esac

prompt AUTH_USERNAME "Owner account username (created on first start)" "admin"
AUTH_PASSWORD_DEFAULT="$(openssl rand -base64 24 2>/dev/null || echo "changeme-$(date +%s)")"
prompt_secret AUTH_PASSWORD "Owner account password (shown once at the end; change it in the app later)" "$AUTH_PASSWORD_DEFAULT"

# ------------------------------------------------------- 2. system dependencies

info "Installing system dependencies (apt)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates openssl python3 python3-venv \
  python3-pip nginx ffmpeg util-linux >/dev/null
ok "git, curl, openssl, python3, nginx, ffmpeg"

if ! command -v node >/dev/null 2>&1 \
  || [[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 20 ]]; then
  info "Installing Node.js 20 (Nodesource)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 20 ]] || die "Node.js 20+ is required; found $(node --version)."
ok "node $(node --version), npm $(npm --version)"

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  if [[ "${JEEVO_SKIP_PYTHON_CHECK:-0}" == 1 ]]; then
    warn "Python $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])') is older than 3.9 (JEEVO_SKIP_PYTHON_CHECK=1)."
  else
    die "Python 3.9+ is required for the AI worker (found $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')). Install python3.9+ and re-run."
  fi
else
  ok "python3 $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
fi

# ---------------------------------------------------------------- 3. accounts

info "Creating the service account"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  ok "user '$SERVICE_USER' already exists"
else
  useradd --system --user-group --home-dir "$SERVICE_HOME" --create-home \
    --shell /usr/sbin/nologin "$SERVICE_USER"
  ok "user '$SERVICE_USER' (system, no login)"
fi

# --------------------------------------------------------------- 4. directories

info "Creating directories"
install -d -m 750 -o root -g "$SERVICE_USER" "$CONF_DIR"
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$SERVICE_HOME"
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$DATA_DIR" "$DATA_DIR/media-store" "$DATA_DIR/artwork"
ok "$CONF_DIR (config, root-owned)"
ok "$SERVICE_HOME (database lives here, on host storage)"
ok "$DATA_DIR/media-store and $DATA_DIR/artwork (the large files)"
if ! mountpoint -q "$DATA_DIR"; then
  warn "$DATA_DIR is not a mount point. Fine for a local disk; if this is"
  warn "network storage (NFS/CIFS), mount it there BEFORE the first start —"
  warn "the backend refuses to start when its media path is missing."
fi
runuser -u "$SERVICE_USER" -- touch "$DATA_DIR/.write-test" \
  && rm -f "$DATA_DIR/.write-test" \
  || die "$DATA_DIR is not writable by user '$SERVICE_USER'. Fix the permissions/mount and re-run."

# --------------------------------------------------------- 5. repository access

info "Configuring access to the Jeevo repository"

case "$GIT_KIND" in
  https)
    prompt_secret GITHUB_TOKEN "GitHub token (fine-grained, READ-ONLY: Contents: Read-only, scoped to the Jeevo repo)"
    [[ -n "$GITHUB_TOKEN" ]] || die "The token cannot be empty."
    TOKEN_FILE="${CONF_DIR}/git-credentials"
    umask 077
    printf '%s' "$GITHUB_TOKEN" > "$TOKEN_FILE"
    unset GITHUB_TOKEN
    chown root:"$SERVICE_USER" "$TOKEN_FILE"
    chmod 640 "$TOKEN_FILE"
    cat > "${CONF_DIR}/git-askpass.sh" <<'ASKPASS'
#!/usr/bin/env bash
# git credential helper used ONLY through GIT_ASKPASS on our own git calls.
# Prints the stored token; never writes it anywhere else.
exec cat /etc/jeevo/git-credentials
ASKPASS
    chown root:"$SERVICE_USER" "${CONF_DIR}/git-askpass.sh"
    chmod 755 "${CONF_DIR}/git-askpass.sh"
    GIT_ENV+=(
      "GIT_ASKPASS=${CONF_DIR}/git-askpass.sh"
      "SSH_ASKPASS=${CONF_DIR}/git-askpass.sh"
      "GIT_TERMINAL_PROMPT=0"
    )
    ok "token stored in ${TOKEN_FILE} (mode 640, never logged)"
    ;;
  ssh)
    prompt KEY_SRC "Path to a READ-ONLY SSH deploy private key (its .pub must be registered on GitHub as a deploy key)"
    [[ -f "$KEY_SRC" ]] || die "No such key file: ${KEY_SRC:-<empty>}. Create one with 'ssh-keygen -t ed25519 -f jeevo_deploy_key -N \"\"' and register the .pub as a read-only deploy key on the repository."
    install -m 600 -o root -g "$SERVICE_USER" "$KEY_SRC" "${CONF_DIR}/jeevo_deploy_key"
    ok "deploy key copied to ${CONF_DIR}/jeevo_deploy_key (mode 600)"
    SSH_HOST="$(printf '%s' "$REPO_URL" | sed -E 's#^ssh://##; s#^git@##; s#[/:].*$##')"
    [[ -n "$SSH_HOST" ]] || SSH_HOST=github.com
    ssh-keyscan -H "$SSH_HOST" > "${CONF_DIR}/known_hosts" 2>/dev/null \
      || die "Could not fetch host keys for ${SSH_HOST}."
    chmod 644 "${CONF_DIR}/known_hosts"
    ok "host keys pinned for ${SSH_HOST}"
    GIT_ENV+=(
      "GIT_SSH_COMMAND=ssh -i ${CONF_DIR}/jeevo_deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=${CONF_DIR}/known_hosts -o StrictHostKeyChecking=yes"
      "GIT_TERMINAL_PROMPT=0"
    )
    ;;
  local)
    ok "local repository (no credentials needed)"
    GIT_ENV+=("GIT_TERMINAL_PROMPT=0")
    ;;
esac

info "Verifying the repository is reachable"
as_jeevo git ls-remote --heads --tags "$REPO_URL" >/dev/null 2>&1 \
  || die "Cannot reach ${REPO_URL} with the supplied credentials. Check the URL, the token's access to the repository, or the deploy key. Nothing has been installed."
ok "repository reachable"

# Which ref should `jeevo update` track? Versioned tags (v*) are preferred;
# tracking a plain development branch requires an explicit confirmation.
if as_jeevo git ls-remote --tags "$REPO_URL" | grep -qE 'refs/tags/v[0-9]'; then
  UPDATE_MODE=tags
  REF=""
  ok "versioned release tags found — updates will track the latest v* tag"
else
  UPDATE_MODE=ref
  prompt REF "No v* release tags found. Which ref should 'jeevo update' track?" "master"
  if [[ "$ASSUME_YES" != 1 ]]; then
    read -r -p "  '${REF}' is a development branch, not a release. Track it anyway? [y/N]: " REPLY </dev/tty || true
    [[ "${REPLY:-}" == y || "${REPLY:-}" == Y ]] || die "Aborted. Create versioned tags (v1.2.3) on the repository, or re-run and accept tracking ${REF}."
  fi
  warn "Updates will track '${REF}'. Once v* release tags exist on the repository,"
  warn "'jeevo update' switches to the latest tag automatically."
fi

# ------------------------------------------------------------------ 6. clone

info "Cloning Jeevo into ${INSTALL_DIR}"
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$INSTALL_DIR"
as_jeevo git clone --quiet "$REPO_URL" "$INSTALL_DIR"
ok "checked out $(git -C "$INSTALL_DIR" describe --tags --always)"

# -------------------------------------------------------- 7. app dependencies

info "Installing application dependencies (npm ci; this also fetches ffmpeg)"
as_jeevo npm --prefix "$INSTALL_DIR/backend" ci --no-audit --no-fund
as_jeevo npm --prefix "$INSTALL_DIR/frontend" ci --no-audit --no-fund
ok "backend + frontend dependencies"

info "Installing AI worker dependencies (Python venv)"
as_jeevo python3 -m venv "$INSTALL_DIR/ai-worker/.venv"
as_jeevo "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet --upgrade pip
as_jeevo "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet \
  -r "$INSTALL_DIR/ai-worker/requirements.txt"
ok "ai-worker/.venv ready"

# --------------------------------------------------------------- 8. secrets

info "Generating configuration and secrets"
WORKER_TOKEN="$(openssl rand -hex 32)"
[[ -n "$WORKER_TOKEN" ]] || die "Could not generate WORKER_TOKEN (openssl failed)."

# ------------------------------------------------------------- 9. config files

BACKEND_ENV="${CONF_DIR}/backend.env"
WORKER_ENV="${CONF_DIR}/worker.env"

umask 027
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
  warn "npm ffmpeg/ffprobe binaries are missing; falling back to the system ones."
fi

chown root:"$SERVICE_USER" "$BACKEND_ENV" "$WORKER_ENV"
chmod 640 "$BACKEND_ENV" "$WORKER_ENV"

# The apps keep loading their own .env files; symlinks point them at the
# protected copies in /etc/jeevo so updates never touch configuration.
ln -sfn "$BACKEND_ENV" "$INSTALL_DIR/backend/.env"
ln -sfn "$WORKER_ENV"  "$INSTALL_DIR/ai-worker/.env"
ok "backend.env + worker.env written to ${CONF_DIR} and symlinked into the app"

# ----------------------------------------------------------------- 10. build

info "Building for production"
as_jeevo npm --prefix "$INSTALL_DIR/backend" run build
as_jeevo env VITE_API_URL= npm --prefix "$INSTALL_DIR/frontend" run build
ok "backend dist/ + frontend dist/ built"

# -------------------------------------------------------------- 11. services

if [[ "$SYSTEMD" == 1 ]]; then
  info "Installing systemd services"

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

  info "Configuring nginx"
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
  nginx -t >/dev/null 2>&1 || die "Generated nginx configuration failed 'nginx -t'. Fix /etc/nginx/sites-available/jeevo and re-run."
  ok "nginx site 'jeevo' (port 80, ${SITE_HOST})"

  systemctl daemon-reload
  systemctl enable --now jeevo-api jeevo-worker >/dev/null 2>&1
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
  ok "jeevo-api + jeevo-worker enabled and started"
else
  warn "JEEVO_SYSTEMD=0: skipping systemd units and nginx (test/container mode)."
fi

# ------------------------------------------------------------- 12. health check

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

info "Verifying Jeevo starts"
if [[ "$SYSTEMD" == 1 ]]; then
  if health_check; then
    ok "API healthy on http://127.0.0.1:${PORT}/api/health"
  else
    warn "The API did not answer its health check within 30s. Recent logs:"
    journalctl -u jeevo-api -n 30 --no-pager >&2 || true
    die "Installation stopped here; fix the error above and 'systemctl restart jeevo-api'."
  fi
else
  # Test mode: boot the freshly built API directly, probe it, then stop it.
  runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" NODE_ENV=production \
    node dist/main.js >/tmp/jeevo-health.log 2>&1 &
  API_PID=$!
  if health_check; then
    ok "API healthy on http://127.0.0.1:${PORT}/api/health (manual probe; systemd disabled)"
  else
    cat /tmp/jeevo-health.log >&2 || true
    kill "$API_PID" 2>/dev/null || true
    die "The API did not answer its health check."
  fi
  kill "$API_PID" 2>/dev/null || true
  wait "$API_PID" 2>/dev/null || true
fi

# ------------------------------------------------------------ 13. install.conf

VERSION_SHA="$(git -C "$INSTALL_DIR" rev-parse --short=12 HEAD)"
VERSION_DESC="$(git -C "$INSTALL_DIR" describe --tags --always 2>/dev/null || echo "$VERSION_SHA")"

umask 027
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
chown root:"$SERVICE_USER" "$CONF"
chmod 640 "$CONF"
ok "${CONF} written"

# ------------------------------------------------------------------- 14. CLI

info "Installing the 'jeevo' admin CLI"
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

die() { echo "jeevo: $*" >&2; exit 1; }
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

# All git operations run as the service user with the stored auth.
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

  echo "==> Fetching from the configured source"
  git_env git -C "$INSTALL_DIR" fetch --tags --quiet origin \
    || die "fetch failed — check the stored credentials (INSTALL.md, 'Private repository authentication'). The current installation is untouched."

  local current target
  current="$(git -C "$INSTALL_DIR" rev-parse HEAD)"
  if [[ -n "$explicit_ref" ]]; then
    target="$(git -C "$INSTALL_DIR" rev-parse --verify -q "refs/tags/${explicit_ref}^{commit}" || true)"
    [[ -n "$target" ]] || target="$(git -C "$INSTALL_DIR" rev-parse --verify -q "refs/remotes/origin/${explicit_ref}^{commit}" || true)"
    [[ -n "$target" ]] || die "unknown ref '${explicit_ref}' (not a tag, nor a branch on origin)"
  elif [[ "$UPDATE_MODE" == tags ]]; then
    local latest
    latest="$(git -C "$INSTALL_DIR" tag -l 'v[0-9]*' | sort -V | tail -1)"
    [[ -n "$latest" ]] || die "UPDATE_MODE=tags but no v* tags found. Publish a tag, or run: sudo jeevo update --ref <branch>"
    target="$(git -C "$INSTALL_DIR" rev-parse "refs/tags/${latest}^{commit}")"
  else
    target="$(git -C "$INSTALL_DIR" rev-parse --verify -q "refs/remotes/origin/${REF}^{commit}" || true)"
    [[ -n "$target" ]] || die "branch '${REF}' not found on origin"
  fi

  local cur_desc tgt_desc
  cur_desc="$(git -C "$INSTALL_DIR" describe --tags --always HEAD)"
  tgt_desc="$(git -C "$INSTALL_DIR" describe --tags --always "$target")"
  echo "    Installed: ${cur_desc} ($(git -C "$INSTALL_DIR" log -1 --format=%cs HEAD))"
  echo "    Available: ${tgt_desc} ($(git -C "$INSTALL_DIR" log -1 --format=%cs "$target"))"

  if [[ "$current" == "$target" ]]; then
    echo "==> Already up to date."
    exit 0
  fi

  if [[ "$yes" != 1 ]]; then
    local reply
    read -r -p "    Update now? [y/N]: " reply
    [[ "$reply" == y || "$reply" == Y ]] || { echo "==> Aborted. Nothing was changed."; exit 0; }
  fi

  # Record the previous version for the manual recovery instructions printed on
  # failure. This is NOT automatic rollback — nothing is restored by itself.
  sed -i "/^PREV_VERSION=.*/d" "$CONF"
  echo "PREV_VERSION=${current}" >> "$CONF"

  fail_recover() {
    echo >&2
    echo "Update FAILED: $*" >&2
    echo "The services were NOT restarted. The database, configuration and media" >&2
    echo "were not touched. To retry:     sudo jeevo update" >&2
    echo "To try the previous version:    sudo jeevo update --ref $(git -C "$INSTALL_DIR" rev-parse --short=12 "$current")" >&2
    if [[ "$SYSTEMD" == 1 ]]; then
      echo "Recent API logs (if it started at some point):" >&2
      journalctl -u jeevo-api -n 20 --no-pager >&2 2>/dev/null || true
    fi
    exit 1
  }

  echo "==> Stopping services"
  if [[ "$SYSTEMD" == 1 ]]; then
    systemctl stop jeevo-api jeevo-worker 2>/dev/null || true
  fi

  echo "==> Checking out ${tgt_desc}"
  git_env git -C "$INSTALL_DIR" checkout -f --detach "$target" >/dev/null 2>&1 \
    || fail_recover "git checkout"

  echo "==> Installing dependencies"
  git_env npm --prefix "$INSTALL_DIR/backend" ci --no-audit --no-fund >/dev/null \
    || fail_recover "npm ci (backend)"
  git_env npm --prefix "$INSTALL_DIR/frontend" ci --no-audit --no-fund >/dev/null \
    || fail_recover "npm ci (frontend)"
  if [[ ! -x "$INSTALL_DIR/ai-worker/.venv/bin/python" ]]; then
    git_env python3 -m venv "$INSTALL_DIR/ai-worker/.venv" || fail_recover "venv creation"
  fi
  git_env "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet --upgrade pip
  git_env "$INSTALL_DIR/ai-worker/.venv/bin/python" -m pip install --quiet \
    -r "$INSTALL_DIR/ai-worker/requirements.txt" || fail_recover "pip install"

  echo "==> Building"
  git_env npm --prefix "$INSTALL_DIR/backend" run build >/dev/null \
    || fail_recover "backend build"
  git_env env VITE_API_URL= npm --prefix "$INSTALL_DIR/frontend" run build >/dev/null \
    || fail_recover "frontend build"

  # Database migrations are additive and run automatically the next time the
  # API starts (backend/src/db/db.ts). Nothing here touches the database.
  sed -i "s/^VERSION=.*/VERSION=$(git -C "$INSTALL_DIR" rev-parse --short=12 HEAD)/" "$CONF"
  sed -i "s/^VERSION_DESC=.*/VERSION_DESC=$(git -C "$INSTALL_DIR" describe --tags --always 2>/dev/null || true)/" "$CONF"

  echo "==> Starting services"
  if [[ "$SYSTEMD" == 1 ]]; then
    systemctl start jeevo-api jeevo-worker || fail_recover "systemctl start"
    local i
    for i in $(seq 1 30); do
      if curl -fsS "http://127.0.0.1:${PORT}/api/health" 2>/dev/null | grep -q '"ok"'; then
        echo "==> Updated to ${tgt_desc}. API is healthy."
        exit 0
      fi
      sleep 1
    done
    fail_recover "the API did not become healthy within 30s"
  else
    echo "==> Updated to ${tgt_desc} (systemd disabled; start the API manually to verify)."
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
  echo "restarted: $what"
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
ok "${BIN_PATH} installed"

# ---------------------------------------------------------------- 15. summary

cat <<EOF

Jeevo is installed.

  Site:        ${SITE_URL}
  Version:     ${VERSION_DESC} (${VERSION_SHA})
  API:         http://127.0.0.1:${PORT} (behind nginx; not exposed directly)
  Owner login: ${AUTH_USERNAME}  (the password you entered is stored in
               ${BACKEND_ENV} and used only on the FIRST start; change it
               later in Settings -> Administration -> Users)
  Code:        ${INSTALL_DIR}
  Config:      ${BACKEND_ENV}, ${WORKER_ENV}
  Database:    ${SERVICE_HOME}/jeevo.sqlite
  Large files: ${DATA_DIR}/media-store, ${DATA_DIR}/artwork

  Service status:  jeevo status
  Update:          sudo jeevo update
  Logs:            jeevo logs api   |   jeevo logs worker
  Restart:         sudo jeevo restart

  TLS is not configured. Before exposing Jeevo beyond your LAN, put a
  certificate in front of nginx (e.g. certbot) and see INSTALL.md.
EOF

}

# Everything above is only DEFINITIONS; nothing has executed yet. Because this
# is the last line, bash has read the entire script before running main().
main "$@"
