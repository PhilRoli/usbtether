#!/bin/bash
# Installs usbtetherd as a root LaunchDaemon. The daemon is copied OUT of the
# (user-writable) app bundle into a root-owned path, so no user-writable file is ever run as root.
# Residual risk: a same-user process could tamper with the staged bundle in the sub-second install
# window; closing that needs Developer ID signing or a root-owned pkg.
# Test-only env: USBTETHER_ROOT (destination prefix), USBTETHER_SKIP_LAUNCHCTL=1.
set -euo pipefail


# Compares the installed daemon with the vetted source; on mismatch removes it and the plist.
verify_daemon() { # verify_daemon <source> <installed daemon> <installed plist>
    if ! cmp -s "$1" "$2"; then
        rm -f "$2" "$3"
        echo "installed daemon does not match the source; nothing installed" >&2
        return 1
    fi
}

cleanup_on_failure() {
    if [ "$COMMITTED" != 1 ]; then
        rm -f "$HELPER_DIR/usbtetherd" "$PLIST_DEST"
        echo "install failed; nothing installed; re-run $SELF as root" >&2
    fi
}

# Homebrew quarantines the cask download (whose checksum it has just verified) and install(1)
# copies the flag, so Gatekeeper could refuse the unnotarized daemon and app. Strip it from the
# verified root-owned daemon, and from the enclosing app only when this script runs from
# <dir>/UsbTether.app/Contents/Resources and that path holds no symlinks. -s: never follow a
# symlink. As real root the recursive strip over the (user-writable) bundle runs as the bundle's
# owner, so it can only touch what that user owns already; a root-owned bundle (or an odd owner
# name) only gets the bundle directory and its executable stripped, non-recursively.
strip_quarantine() { # strip_quarantine <installed daemon> <script dir>
    /usr/bin/xattr -d com.apple.quarantine "$1" 2>/dev/null || true
    case "$2" in
        */UsbTether.app/Contents/Resources) ;;
        *) return 0 ;;
    esac
    local app="${2%/Contents/Resources}" p owner
    for p in "$app" "$app/Contents" "$app/Contents/Resources"; do
        if [ ! -d "$p" ] || [ -L "$p" ]; then
            return 0
        fi
    done
    if [ "$(id -u)" -ne 0 ]; then
        # Test mode (USBTETHER_ROOT as a normal user): the strip already runs as the owner.
        /usr/bin/xattr -drs com.apple.quarantine "$app" 2>/dev/null || true
        return 0
    fi
    owner="$(/usr/bin/stat -f %Su "$app" 2>/dev/null || true)"
    if [ "$owner" != root ] && [[ "$owner" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
        /usr/bin/sudo -n -u "$owner" /usr/bin/xattr -drs com.apple.quarantine "$app" 2>/dev/null || true
    else
        /usr/bin/xattr -ds com.apple.quarantine "$app" 2>/dev/null || true
        /usr/bin/xattr -ds com.apple.quarantine "$app/Contents/MacOS/UsbTether" 2>/dev/null || true
    fi
}

main() {
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

    # From here the old daemon is gone: on any failure before bootstrap, leave nothing installed.
    COMMITTED=0
    trap cleanup_on_failure EXIT

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
    # Daemon first, verified, and only then the plist: a failure never leaves a plist without a binary.
    # shellcheck disable=SC2086
    install -m 755 $OWNER "$SRC/usbtetherd" "$HELPER_DIR/usbtetherd"
    verify_daemon "$SRC/usbtetherd" "$HELPER_DIR/usbtetherd" "$PLIST_DEST"
    strip_quarantine "$HELPER_DIR/usbtetherd" "$SRC"
    # shellcheck disable=SC2086
    install -m 644 $OWNER "$SRC/$LABEL.plist" "$PLIST_DEST"

    if [ ! -e "$LOG" ]; then
        # shellcheck disable=SC2086
        install -m 640 $LOG_OWNER /dev/null "$LOG"
    fi

    COMMITTED=1   # a failed bootstrap keeps the files installed
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
}

# Run only when executed, not when sourced (tests source this file to unit-test the functions).
if ! (return 0 2>/dev/null); then
    main "$@"
fi
