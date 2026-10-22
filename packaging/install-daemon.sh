#!/bin/bash
# Installs usbtetherd as a root LaunchDaemon. The daemon is copied OUT of the
# (user-writable) app bundle into a root-owned path, so no user-writable file is ever run as root.
# Test-only env: USBTETHER_ROOT (destination prefix), USBTETHER_SKIP_LAUNCHCTL=1.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${USBTETHER_ROOT:-}"
LABEL="com.philipp.usbtether"

if [ "$(id -u)" -ne 0 ] && [ -z "$PREFIX" ]; then
    echo "install-daemon.sh must be run as root" >&2
    exit 1
fi

# Owner flags only when really root (test mode runs as the invoking user).
OWNER=""; LOG_OWNER=""
if [ "$(id -u)" -eq 0 ] && [ -z "$PREFIX" ]; then
    OWNER="-o root -g wheel"; LOG_OWNER="-o root -g admin"
fi

HELPER_DIR="$PREFIX/Library/PrivilegedHelperTools"
DAEMON_DIR="$PREFIX/Library/LaunchDaemons"
SUPPORT_DIR="$PREFIX/Library/Application Support/usbtether"
LOG="$PREFIX/var/log/usbtether.log"
PLIST_DEST="$DAEMON_DIR/$LABEL.plist"

# Stop any running instance before replacing files.
if [ "${USBTETHER_SKIP_LAUNCHCTL:-0}" != "1" ]; then
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
fi

# shellcheck disable=SC2086
install -d -m 755 $OWNER "$HELPER_DIR" "$DAEMON_DIR" "$SUPPORT_DIR" "$(dirname "$LOG")"
# shellcheck disable=SC2086
install -m 755 $OWNER "$SRC/usbtetherd" "$HELPER_DIR/usbtetherd"
# shellcheck disable=SC2086
install -m 644 $OWNER "$SRC/$LABEL.plist" "$PLIST_DEST"

if [ ! -e "$LOG" ]; then
    # shellcheck disable=SC2086
    install -m 640 $LOG_OWNER /dev/null "$LOG"
fi

if [ "${USBTETHER_SKIP_LAUNCHCTL:-0}" != "1" ]; then
    launchctl bootstrap system "$PLIST_DEST"
fi
echo "usbtetherd installed"
