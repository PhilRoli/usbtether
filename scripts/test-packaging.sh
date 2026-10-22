#!/bin/bash
# Tests for packaging/ and scripts/package.sh. Needs no root and touches no system paths.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

FAILS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
check() { # check <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
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
check "install run 2 (idempotent) exits 0" "$FAKE/install-daemon.sh"
check "daemon still present after rerun" test -f "$DAEMON"

touch "$APPSUP/allowed.json" "$ROOT/var-run-marker"
mkdir -p "$ROOT/var/run"
touch "$ROOT/var/run/usbtether.sock"
check "uninstall run 1 exits 0" "$FAKE/uninstall-daemon.sh"
check "daemon removed" test ! -e "$DAEMON"
check "plist removed" test ! -e "$PLIST"
check "socket removed" test ! -e "$ROOT/var/run/usbtether.sock"
check "uninstall run 2 exits 0" "$FAKE/uninstall-daemon.sh"
check "Application Support left alone" test -f "$APPSUP/allowed.json"
unset USBTETHER_ROOT USBTETHER_SKIP_LAUNCHCTL

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
