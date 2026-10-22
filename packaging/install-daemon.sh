#!/bin/bash
# Installs usbtetherd as a root LaunchDaemon. The daemon is copied OUT of the
# (user-writable) app bundle into a root-owned path, so no user-writable file is ever run as root.
# Residual risk: a same-user process could tamper with the staged bundle in the sub-second install
# window; closing that needs Developer ID signing or a root-owned pkg.
# Test-only env: USBTETHER_ROOT (destination prefix), USBTETHER_SKIP_LAUNCHCTL=1.
set -euo pipefail

SCRIPT_DIR_RAW="$(dirname "$0")"
SRC="$(cd "$SCRIPT_DIR_RAW" && pwd)"
PREFIX="${USBTETHER_ROOT:-}"
LABEL="com.philipp.usbtether"
SELF="$SRC/$(basename "$0")"

if [ "$(id -u)" -eq 0 ]; then
    # Test overrides must be inert under real root (they would redirect a root install).
    if [ -n "$PREFIX" ] || [ -n "${USBTETHER_SKIP_LAUNCHCTL+x}" ]; then
        echo "USBTETHER_ROOT / USBTETHER_SKIP_LAUNCHCTL are test-only and refused when running as root" >&2
        exit 1
    fi
elif [ -z "$PREFIX" ]; then
    echo "install-daemon.sh must be run as root" >&2
    exit 1
fi

# Refuse sources that a non-root user could swap: symlinks, non-regular files, group/world-writable.
not_writable_by_others() { [ $(( 8#$(stat -f '%Lp' "$1") & 8#022 )) -eq 0 ]; }
if [ -L "$SCRIPT_DIR_RAW" ] || [ ! -d "$SRC" ] || ! not_writable_by_others "$SRC"; then
    echo "refusing to install: script directory is a symlink or is group/world-writable: $SRC" >&2
    exit 1
fi
for f in "$SRC/usbtetherd" "$SRC/$LABEL.plist"; do
    if [ -L "$f" ] || [ ! -f "$f" ] || ! not_writable_by_others "$f"; then
        echo "refusing to install: not a regular, non-group/world-writable file: $f" >&2
        exit 1
    fi
done

# Owner flags only when really root (test mode runs as the invoking user).
OWNER=""; LOG_OWNER=""
if [ "$(id -u)" -eq 0 ]; then
    OWNER="-o root -g wheel"; LOG_OWNER="-o root -g admin"
fi

HELPER_DIR="$PREFIX/Library/PrivilegedHelperTools"
DAEMON_DIR="$PREFIX/Library/LaunchDaemons"
SUPPORT_DIR="$PREFIX/Library/Application Support/usbtether"
LOG_DIR="$PREFIX/var/log"
LOG="$LOG_DIR/usbtether.log"
PLIST_DEST="$DAEMON_DIR/$LABEL.plist"

if [ "${USBTETHER_SKIP_LAUNCHCTL:-0}" != "1" ]; then
    # Stop any running instance before replacing files, and wait until it is really gone.
    launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

# Never alter macOS's own existing directories (stock PrivilegedHelperTools is 1755).
for d in "$HELPER_DIR" "$DAEMON_DIR" "$LOG_DIR"; do
    # shellcheck disable=SC2086
    [ -d "$d" ] || install -d -m 755 $OWNER "$d"
done
# shellcheck disable=SC2086
install -d -m 755 $OWNER "$SUPPORT_DIR"
# shellcheck disable=SC2086
install -m 755 $OWNER "$SRC/usbtetherd" "$HELPER_DIR/usbtetherd"
# shellcheck disable=SC2086
install -m 644 $OWNER "$SRC/$LABEL.plist" "$PLIST_DEST"

# Verify the installed (root-owned) copy matches what was vetted.
if ! cmp -s "$SRC/usbtetherd" "$HELPER_DIR/usbtetherd"; then
    rm -f "$HELPER_DIR/usbtetherd"
    echo "installed daemon does not match the source; aborting" >&2
    exit 1
fi

if [ ! -e "$LOG" ]; then
    # shellcheck disable=SC2086
    install -m 640 $LOG_OWNER /dev/null "$LOG"
fi

if [ "${USBTETHER_SKIP_LAUNCHCTL:-0}" != "1" ]; then
    if ! launchctl bootstrap system "$PLIST_DEST"; then
        sleep 2
        if ! launchctl bootstrap system "$PLIST_DEST"; then
            echo "daemon installed but not started; re-run $SELF as root or reboot" >&2
            exit 1
        fi
    fi
fi
echo "usbtetherd installed"
