#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

CONF=/etc/jeevo/install.conf
get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }
INSTALL_DIR="$(get INSTALL_DIR)"; INSTALL_DIR="${INSTALL_DIR:-/opt/jeevo}"
DATA_DIR="$(get DATA_DIR)";       DATA_DIR="${DATA_DIR:-/srv/jeevo-data}"
SERVICE_HOME="$(get SERVICE_HOME)"; SERVICE_HOME="${SERVICE_HOME:-/var/lib/jeevo}"

# Refuse anything that is not a plausible, specific absolute path.
for p in "$INSTALL_DIR" "$DATA_DIR" "$SERVICE_HOME"; do
  case "$p" in
    /|/etc|/var|/var/lib|/srv|/opt|/usr|/home|/root|/mnt|/media|"") echo "Refusing unsafe path: '$p'"; exit 1 ;;
    /?*) ;;
    *) echo "Refusing non-absolute path: '$p'"; exit 1 ;;
  esac
done

echo "This will DELETE:"
echo "  services   jeevo-api, jeevo-worker"
echo "  nginx site jeevo"
echo "  code       $INSTALL_DIR"
echo "  config     /etc/jeevo"
echo "  database   $SERVICE_HOME  (users, playlists, history)"
echo "  CLI        /usr/local/bin/jeevo"
echo
read -r -p "Type 'wipe jeevo' to continue: " ans
[[ "$ans" == "wipe jeevo" ]] || { echo "Cancelled. Nothing changed."; exit 0; }

# Services
systemctl disable --now jeevo-api jeevo-worker 2>/dev/null || true
rm -f /etc/systemd/system/jeevo-api.service /etc/systemd/system/jeevo-worker.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# nginx
rm -f /etc/nginx/sites-enabled/jeevo /etc/nginx/sites-available/jeevo
if command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null; then
  systemctl reload nginx 2>/dev/null || true
fi

# Code, config, database, CLI, logs, locks
rm -rf "$INSTALL_DIR" /etc/jeevo "$SERVICE_HOME"
rm -f /usr/local/bin/jeevo
rm -f /var/log/jeevo-install.log /var/log/jeevo-update.log /var/lock/jeevo-*.lock

echo "App, config and database removed."

# Media is a separate decision.
echo
echo "Media under $DATA_DIR (media-store, artwork):"
read -r -p "Delete it too? Type 'delete media' to confirm, anything else keeps it: " ans2
if [[ "$ans2" == "delete media" ]]; then
  # Only the two folders the installer created, never the directory itself:
  # it may be a mount point for network storage.
  rm -rf "$DATA_DIR/media-store" "$DATA_DIR/artwork"
  echo "Media deleted."
else
  echo "Media kept."
fi

echo
echo "Done. The 'jeevo' system user and system packages were left in place."
