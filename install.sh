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

# Failed runs leave a text report in the home directory of whoever installed
# this. Under sudo that is SUDO_USER; logged in as root, it is root. Recorded
# now because the nightly timer runs as root and cannot know who you are.
INSTALL_USER="${SUDO_USER:-root}"
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
if grep -qE '^[[:space:]]*ACORE_REPORT_DIR=' /etc/acore-update.conf; then
    echo "kept existing failure-report setting in /etc/acore-update.conf"
elif [[ -n "$INSTALL_HOME" && -d "$INSTALL_HOME" ]]; then
    {
        echo
        echo "# Recorded by install.sh on $(date -u +%Y-%m-%d): failed runs write"
        echo "# acore-update-FAILED-<time>.txt here, as this user."
        printf 'ACORE_REPORT_DIR=%q\n' "$INSTALL_HOME"
        printf 'ACORE_REPORT_OWNER=%q\n' "$INSTALL_USER"
    } >> /etc/acore-update.conf
    echo "failure reports will be written to $INSTALL_HOME (as $INSTALL_USER)"
else
    echo "could not find a home directory for '$INSTALL_USER' - failure reports stay off;"
    echo "set ACORE_REPORT_DIR / ACORE_REPORT_OWNER in /etc/acore-update.conf to enable them"
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
echo "and check where failure reports will land:"
echo "    sudo acore-update test-report"
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
