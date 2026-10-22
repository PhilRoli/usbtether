#!/bin/bash
# Builds build/UsbTether.app and build/UsbTether-<version>.zip.
# UNIVERSAL=0 builds the host architecture only (default 1: arm64 + x86_64).
set -euo pipefail

VERSION="${1:?Usage: package.sh <version>}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    echo "invalid version: $VERSION" >&2
    exit 1
fi
BUILD_VERSION="${VERSION%%-*}"   # CFBundleVersion must be numeric, so drop any -suffix
UNIVERSAL="${UNIVERSAL:-1}"
TARGET_DIR="${CARGO_TARGET_DIR:-target}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
APP="$REPO/build/UsbTether.app"
RES="$APP/Contents/Resources"

export USBTETHER_VERSION="$VERSION"

if [ "$UNIVERSAL" = "1" ]; then
    for t in aarch64-apple-darwin x86_64-apple-darwin; do
        if command -v rustup >/dev/null 2>&1; then
            rustup target list --installed | grep -qx "$t" || rustup target add "$t"
        elif [ ! -d "$(rustc --print sysroot)/lib/rustlib/$t" ]; then
            echo "rust target $t is missing and rustup is not available" >&2
            exit 1
        fi
    done
    cargo build --locked --release --target aarch64-apple-darwin
    cargo build --locked --release --target x86_64-apple-darwin
    DAEMON_BIN="$REPO/build/usbtetherd.universal"
    mkdir -p "$REPO/build"
    lipo -create -output "$DAEMON_BIN" \
        "$TARGET_DIR"/aarch64-apple-darwin/release/usbtetherd \
        "$TARGET_DIR"/x86_64-apple-darwin/release/usbtetherd
    (cd app && swift build -c release --arch arm64 --arch x86_64)
    APP_BIN="$(cd app && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/UsbTether"
else
    cargo build --locked --release
    DAEMON_BIN="$TARGET_DIR/release/usbtetherd"
    (cd app && swift build -c release)
    APP_BIN="$(cd app && swift build -c release --show-bin-path)/UsbTether"
fi

if [ "$UNIVERSAL" = "1" ]; then
    lipo "$DAEMON_BIN" -verify_arch arm64 x86_64
    lipo "$APP_BIN" -verify_arch arm64 x86_64
fi

rm -rf "$APP" "$REPO/build/UsbTether-$VERSION.zip"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$APP_BIN" "$APP/Contents/MacOS/UsbTether"
cp "$DAEMON_BIN" "$RES/usbtetherd"
cp packaging/install-daemon.sh packaging/uninstall-daemon.sh \
   packaging/com.philipp.usbtether.plist packaging/AppIcon.icns "$RES/"
chmod 755 "$APP/Contents/MacOS/UsbTether" "$RES/usbtetherd" "$RES/install-daemon.sh" "$RES/uninstall-daemon.sh"
sed -e "s/\$(VERSION)/$VERSION/g" -e "s/\$(BUILD_VERSION)/$BUILD_VERSION/g" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
rm -f "$REPO/build/usbtetherd.universal"

codesign --force --deep -s - "$APP"

(cd build && zip -r -y -q "UsbTether-$VERSION.zip" UsbTether.app)
echo "Built build/UsbTether.app and build/UsbTether-$VERSION.zip"
