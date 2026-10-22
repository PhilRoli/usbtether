#!/bin/bash
# Tests for packaging/ and scripts/package.sh. Needs no root and touches no system paths.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

FAILS=0
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { # check <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
# %Lp drops the sticky bit, so mode_full_is compares the 4-digit mode (e.g. 1755).
mode_full_is() { [ "$(stat -f '%Mp%Lp' "$1" 2>/dev/null)" = "$2" ]; }
mode_is() { [ "$(stat -f '%Lp' "$1" 2>/dev/null)" = "$2" ]; }

# Stand-in daemon so install/uninstall tests do not need a build.
FAKE="$TMP/fake-resources"
mkdir -p "$FAKE"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/usbtetherd"
chmod 755 "$FAKE/usbtetherd"
cp packaging/install-daemon.sh packaging/uninstall-daemon.sh packaging/com.philipp.usbtether.plist "$FAKE/" 2>/dev/null

ROOT="$TMP/root"
mkdir -p "$ROOT"
export USBTETHER_ROOT="$ROOT" USBTETHER_SKIP_LAUNCHCTL=1
DAEMON="$ROOT/Library/PrivilegedHelperTools/usbtetherd"
PLIST="$ROOT/Library/LaunchDaemons/com.philipp.usbtether.plist"
APPSUP="$ROOT/Library/Application Support/usbtether"

check "install run 1 exits 0" "$FAKE/install-daemon.sh"
check "daemon installed" test -f "$DAEMON"
check "daemon mode 755" mode_is "$DAEMON" 755
check "plist installed" test -f "$PLIST"
check "plist mode 644" mode_is "$PLIST" 644
check "Application Support dir exists" test -d "$APPSUP"
check "installed daemon identical to source" cmp -s "$FAKE/usbtetherd" "$DAEMON"
check "Application Support dir mode 755" mode_is "$APPSUP" 755
check "log created" test -f "$ROOT/var/log/usbtether.log"
check "log mode 640" mode_is "$ROOT/var/log/usbtether.log" 640
check "install run 2 (idempotent) exits 0" "$FAKE/install-daemon.sh"
check "daemon still present after rerun" test -f "$DAEMON"

touch "$APPSUP/allowed.json"
mkdir -p "$ROOT/var/run"
touch "$ROOT/var/run/usbtether.sock" "$ROOT/var/run/usbtetherd.pid"
check "uninstall run 1 exits 0" "$FAKE/uninstall-daemon.sh"
check "daemon removed" test ! -e "$DAEMON"
check "plist removed" test ! -e "$PLIST"
check "pidfile removed" test ! -e "$ROOT/var/run/usbtetherd.pid"
check "log survives uninstall" test -f "$ROOT/var/log/usbtether.log"
check "socket removed" test ! -e "$ROOT/var/run/usbtether.sock"
check "uninstall run 2 exits 0" "$FAKE/uninstall-daemon.sh"
check "Application Support left alone" test -f "$APPSUP/allowed.json"

# Existing system dirs must never be altered (stock PrivilegedHelperTools is 1755).
ROOT2="$TMP/root2"
mkdir -p "$ROOT2/Library/PrivilegedHelperTools" "$ROOT2/Library/LaunchDaemons" "$ROOT2/var/log"
chmod 1755 "$ROOT2/Library/PrivilegedHelperTools"
chmod 750 "$ROOT2/Library/LaunchDaemons" "$ROOT2/var/log"
check "install into pre-existing dirs" env USBTETHER_ROOT="$ROOT2" "$FAKE/install-daemon.sh"
check "PrivilegedHelperTools mode unchanged" mode_full_is "$ROOT2/Library/PrivilegedHelperTools" 1755
check "LaunchDaemons mode unchanged" mode_is "$ROOT2/Library/LaunchDaemons" 750
check "var/log mode unchanged" mode_is "$ROOT2/var/log" 750


# Source hardening: group-writable and symlinked sources are refused.
ROOT3="$TMP/root3"; mkdir -p "$ROOT3"
GW="$TMP/gw"; cp -R "$FAKE" "$GW"; chmod 775 "$GW/usbtetherd"
# shellcheck disable=SC2016
check "group-writable source refused" bash -c '! USBTETHER_ROOT="$1" "$2/install-daemon.sh"' _ "$ROOT3" "$GW"
check "nothing installed from group-writable source" test ! -e "$ROOT3/Library/PrivilegedHelperTools/usbtetherd"
SL="$TMP/sl"; cp -R "$FAKE" "$SL"; rm "$SL/usbtetherd"; ln -s "$FAKE/usbtetherd" "$SL/usbtetherd"
# shellcheck disable=SC2016
check "symlinked source refused" bash -c '! USBTETHER_ROOT="$1" "$2/install-daemon.sh"' _ "$ROOT3" "$SL"
check "nothing installed from symlinked source" test ! -e "$ROOT3/Library/PrivilegedHelperTools/usbtetherd"

# verify_daemon (sourced, not executed): a mismatching copy removes the daemon AND the plist.
V="$TMP/verify"; mkdir -p "$V"
echo good > "$V/src"; echo bad > "$V/daemon"; echo plist > "$V/plist"
# shellcheck disable=SC2016
check "verify_daemon mismatch fails" bash -c '! ( source "$1"; verify_daemon "$2/src" "$2/daemon" "$2/plist" )' _ "$FAKE/install-daemon.sh" "$V"
check "mismatch removes daemon" test ! -e "$V/daemon"
check "mismatch removes plist" test ! -e "$V/plist"
echo good > "$V/daemon"; echo plist > "$V/plist"
# shellcheck disable=SC2016
check "verify_daemon match succeeds" bash -c '( source "$1"; verify_daemon "$2/src" "$2/daemon" "$2/plist" )' _ "$FAKE/install-daemon.sh" "$V"
check "match keeps plist" test -f "$V/plist"

# Failing daemon install (read-only PrivilegedHelperTools) must leave no plist behind.
ROOT4="$TMP/root4"; mkdir -p "$ROOT4/Library/PrivilegedHelperTools"
chmod 555 "$ROOT4/Library/PrivilegedHelperTools"
# shellcheck disable=SC2016
check "install fails with read-only helper dir" bash -c '! USBTETHER_ROOT="$1" "$2/install-daemon.sh"' _ "$ROOT4" "$FAKE"
check "no plist after failed daemon install" test ! -e "$ROOT4/Library/LaunchDaemons/com.philipp.usbtether.plist"
chmod 755 "$ROOT4/Library/PrivilegedHelperTools"
unset USBTETHER_ROOT USBTETHER_SKIP_LAUNCHCTL

if [ "$(id -u)" -ne 0 ]; then
    # shellcheck disable=SC2016
    check "install refuses non-root without prefix" bash -c '! "$1/install-daemon.sh"' _ "$FAKE"
fi

check "plutil lint daemon plist" plutil -lint packaging/com.philipp.usbtether.plist
check "plutil lint Info.plist" plutil -lint packaging/Info.plist

if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    check "shellcheck all scripts" shellcheck $(find packaging scripts -name '*.sh')
else
    echo "SKIP: shellcheck not installed"
fi

check "package.sh 0.0.0-test" env UNIVERSAL=0 scripts/package.sh 0.0.0-test
APP="build/UsbTether.app"
check "app executable" test -x "$APP/Contents/MacOS/UsbTether"
check "Info.plist present" test -f "$APP/Contents/Info.plist"
for f in usbtetherd install-daemon.sh uninstall-daemon.sh; do
    check "Resources/$f executable" test -x "$APP/Contents/Resources/$f"
done
check "Resources/com.philipp.usbtether.plist" test -f "$APP/Contents/Resources/com.philipp.usbtether.plist"
check "Resources/AppIcon.icns" test -f "$APP/Contents/Resources/AppIcon.icns"
check "codesign verify" codesign --verify --deep --strict "$APP"
check "LSUIElement is true" test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null)" = true
check "CFBundleShortVersionString is 0.0.0-test" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)" = 0.0.0-test
check "CFBundleVersion is 0.0.0" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)" = 0.0.0
check "zip exists" test -f build/UsbTether-0.0.0-test.zip
check "zip lists app executable" bash -c "unzip -l build/UsbTether-0.0.0-test.zip | grep -q 'UsbTether.app/Contents/MacOS/UsbTether'"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "All checks passed"
