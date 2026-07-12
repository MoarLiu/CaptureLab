#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CaptureLab"
SWAP_HELPER_NAME="CaptureLabUpdateSwap"
LOCAL_CODE_SIGNING_IDENTITY_SHA1="636F51D5E5F9240F862327A82C3863C2F5EE7DFF"
LOCAL_CODE_SIGNING_CERTIFICATE_SHA1="636f51d5e5f9240f862327a82c3863c2f5ee7dff"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.env"

BUNDLE_ID="$CAPTURELAB_BUNDLE_ID"
SWAP_HELPER_BUNDLE_ID="$BUNDLE_ID.UpdateSwap"
MIN_SYSTEM_VERSION="$CAPTURELAB_MIN_SYSTEM_VERSION"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
SWAP_HELPER="$APP_HELPERS/$SWAP_HELPER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/CaptureLab.icns"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR" --product "$APP_NAME"
swift build --package-path "$ROOT_DIR" --product "$SWAP_HELPER_NAME"
BUILD_BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_SWAP_HELPER="$BUILD_BIN_DIR/$SWAP_HELPER_NAME"

if [[ ! -f "$ICON_FILE" || "$ROOT_DIR/script/generate_app_icon.swift" -nt "$ICON_FILE" ]]; then
  swift "$ROOT_DIR/script/generate_app_icon.swift" "$ROOT_DIR"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$BUILD_SWAP_HELPER" "$SWAP_HELPER"
chmod +x "$SWAP_HELPER"
cp "$ICON_FILE" "$APP_RESOURCES/CaptureLab.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>CaptureLab</string>
  <key>CFBundleShortVersionString</key>
  <string>$CAPTURELAB_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$CAPTURELAB_BUILD</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

AVAILABLE_CODE_SIGNING_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$AVAILABLE_CODE_SIGNING_IDENTITIES" == *"$LOCAL_CODE_SIGNING_IDENTITY_SHA1"* ]]; then
  CODE_SIGNING_IDENTITY="$LOCAL_CODE_SIGNING_IDENTITY_SHA1"
  USES_STABLE_LOCAL_SIGNING=1
else
  CODE_SIGNING_IDENTITY="-"
  USES_STABLE_LOCAL_SIGNING=0
  echo "WARNING: CaptureLab's stable local code-signing identity is unavailable." >&2
  echo "Using ad-hoc signing for this development build only; Keychain access may not survive a rebuild." >&2
  echo "Release packaging will refuse this fallback." >&2
fi

codesign --force --sign "$CODE_SIGNING_IDENTITY" \
  --identifier "$SWAP_HELPER_BUNDLE_ID" \
  "$SWAP_HELPER"
codesign --force --sign "$CODE_SIGNING_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE"

verify_bundle() {
  [[ -x "$APP_BINARY" ]] || {
    echo "Missing executable: $APP_BINARY" >&2
    return 1
  }
  [[ -f "$SWAP_HELPER" && -x "$SWAP_HELPER" && ! -L "$SWAP_HELPER" ]] || {
    echo "Missing regular update swap helper: $SWAP_HELPER" >&2
    return 1
  }
  codesign --verify --strict --verbose=2 "$SWAP_HELPER"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  if [[ "$USES_STABLE_LOCAL_SIGNING" == "1" ]]; then
    codesign --verify --strict \
      -R="identifier \"$SWAP_HELPER_BUNDLE_ID\" and certificate root = H\"$LOCAL_CODE_SIGNING_CERTIFICATE_SHA1\"" \
      "$SWAP_HELPER"
    codesign --verify --deep --strict \
      -R="identifier \"$BUNDLE_ID\" and certificate root = H\"$LOCAL_CODE_SIGNING_CERTIFICATE_SHA1\"" \
      "$APP_BUNDLE"
  fi
  SWAP_HELPER_ARCHS="$(/usr/bin/lipo -archs "$SWAP_HELPER")"
  [[ " $SWAP_HELPER_ARCHS " == *" $(uname -m) "* ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == "$BUNDLE_ID" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" == "$CAPTURELAB_VERSION" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" == "$CAPTURELAB_BUILD" ]]
}

verify_bundle

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    verify_bundle
    open_app
    APP_PID=""
    for _ in {1..20}; do
      APP_PID="$(pgrep -nx "$APP_NAME" 2>/dev/null || true)"
      [[ -n "$APP_PID" ]] && break
      sleep 0.2
    done
    [[ -n "$APP_PID" ]] || {
      echo "$APP_NAME did not launch." >&2
      exit 1
    }
    sleep 1
    kill -0 "$APP_PID" 2>/dev/null || {
      echo "$APP_NAME exited during launch." >&2
      exit 1
    }
    RUNNING_COMMAND="$(ps -ww -p "$APP_PID" -o command=)"
    QUOTED_APP_BINARY="\"$APP_BINARY\""
    [[ "$RUNNING_COMMAND" == "$APP_BINARY" ||
       "$RUNNING_COMMAND" == "$APP_BINARY "* ||
       "$RUNNING_COMMAND" == "$QUOTED_APP_BINARY" ||
       "$RUNNING_COMMAND" == "$QUOTED_APP_BINARY "* ]] || {
      echo "Unexpected $APP_NAME process: $RUNNING_COMMAND" >&2
      exit 1
    }
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
