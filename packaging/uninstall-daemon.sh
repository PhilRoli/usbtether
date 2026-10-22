#!/bin/bash
# Removes the daemon, its plist and runtime files. Keeps the approved list and the log.
# Test-only env: USBTETHER_ROOT (destination prefix), USBTETHER_SKIP_LAUNCHCTL=1.
set -euo pipefail

PREFIX="${USBTETHER_ROOT:-}"
LABEL="com.philipp.usbtether"

if [ "$(id -u)" -ne 0 ] && [ -z "$PREFIX" ]; then
    echo "uninstall-daemon.sh must be run as root" >&2
    exit 1
fi

if [ "${USBTETHER_SKIP_LAUNCHCTL:-0}" != "1" ]; then
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
fi

rm -f "$PREFIX/Library/PrivilegedHelperTools/usbtetherd" \
      "$PREFIX/Library/LaunchDaemons/$LABEL.plist" \
      "$PREFIX/var/run/usbtether.sock" \
      "$PREFIX/var/run/usbtetherd.pid"
echo "usbtetherd uninstalled"
