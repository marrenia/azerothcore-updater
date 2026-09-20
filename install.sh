#!/usr/bin/env bash
# Install acore-update. Copies two scripts, an example config and (optionally)
# a systemd timer. Nothing is overwritten without saying so.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN:-/usr/local/sbin}"

install -m 0755 "$HERE/acore-update" "$BIN/acore-update"
install -m 0755 "$HERE/acore-patch"  "$BIN/acore-patch"
echo "installed $BIN/acore-update and $BIN/acore-patch"

mkdir -p /etc/acore-update/patches /var/lib/acore-update
if [[ -f /etc/acore-update.conf ]]; then
    echo "kept existing /etc/acore-update.conf"
else
    install -m 0644 "$HERE/acore-update.conf.example" /etc/acore-update.conf
    echo "wrote /etc/acore-update.conf (all values commented out - detection does the work)"
fi

echo
echo "Checking what it detects on this host:"
echo
"$BIN/acore-update" detect || {
    echo
    echo "Detection failed. Edit /etc/acore-update.conf and re-run: acore-update detect"
    exit 1
}
echo
echo "Looks right? Try a dry run, which changes nothing:"
echo "    sudo acore-update --dry-run"
echo
if [[ -d /run/systemd/system ]]; then
    read -r -p "Install the daily 05:30 systemd timer? [y/N] " a
    if [[ "${a,,}" == y* ]]; then
        install -m 0644 "$HERE/systemd/acore-update.service" /etc/systemd/system/
        install -m 0644 "$HERE/systemd/acore-update.timer"   /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable --now acore-update.timer
        systemctl list-timers acore-update.timer --no-pager | head -2
    fi
fi
