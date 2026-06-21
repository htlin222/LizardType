#!/bin/bash
# Build LizardType.app with swiftc (no Xcode required — CLT only).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LizardType"
BUNDLE_ID="com.lizardtype.app"
BUILD_DIR="build"
# Deployment target. macOS 14 is the floor: RecordingOverlay uses the
# `.symbolEffect(.variableColor…, options: .repeating)` API (14.0+).
# Building on a newer SDK (e.g. macOS 26 CI) would otherwise stamp the
# binary's minos at the SDK version and lock out every older Mac.
MACOS_TARGET="${MACOS_TARGET:-arm64-apple-macosx14.0}"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "▸ cleaning"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "▸ compiling sources"
SOURCES=$(find Sources -name '*.swift' | sort)
swiftc -O \
  -parse-as-library \
  $SOURCES \
  -o "$MACOS_DIR/$APP_NAME" \
  -target "$MACOS_TARGET" \
  -framework AppKit -framework WebKit -framework AVFoundation \
  -framework SwiftUI -framework Combine -framework Carbon -framework UserNotifications

echo "▸ assembling bundle"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: generate AppIcon.icns from the 1024² source PNG if it's missing,
# so fresh clones / CI get an icon without committing the binary .icns.
ICON_SRC="Resources/AppIcon-source.png"
ICON_ICNS="Resources/AppIcon.icns"
if [ ! -f "$ICON_ICNS" ] && [ -f "$ICON_SRC" ]; then
  echo "  generating $ICON_ICNS from $ICON_SRC"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
  rm -rf "$ICONSET"
fi
[ -f "$ICON_ICNS" ] && cp "$ICON_ICNS" "$RES_DIR/AppIcon.icns" || true

echo "▸ signing"
# Prefer the stable self-signed identity (so TCC grants persist across rebuilds);
# fall back to ad-hoc if it isn't installed.
IDENTITY="LizardType Self-Signed"
ENT="Resources/LizardType.entitlements"
SIGNED=""
# no -v — the cert is self-signed/untrusted, fine for local signing.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  if codesign --force --deep --sign "$IDENTITY" --entitlements "$ENT" "$APP" 2>/tmp/lt-codesign.err; then
    SIGNED="$IDENTITY"
  else
    echo "  ⚠ cert signing failed: $(cat /tmp/lt-codesign.err 2>/dev/null)"
    echo "    enable it once with: security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db"
  fi
fi
if [ -z "$SIGNED" ]; then
  codesign --force --deep --sign - --entitlements "$ENT" "$APP"
  SIGNED="ad-hoc"
fi
echo "  signed as: $SIGNED"

echo "✓ built $APP"
echo "  run: open $APP    (or $MACOS_DIR/$APP_NAME for console logs)"
