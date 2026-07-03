#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CaptureLab"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.env"

ARCH="${CAPTURELAB_ARCH:-$(uname -m)}"
BUNDLE_ID="$CAPTURELAB_BUNDLE_ID"
MIN_SYSTEM_VERSION="$CAPTURELAB_MIN_SYSTEM_VERSION"
case "$ARCH" in
  arm64)
    SWIFT_TRIPLE="arm64-apple-macosx$MIN_SYSTEM_VERSION"
    ;;
  x86_64)
    SWIFT_TRIPLE="x86_64-apple-macosx$MIN_SYSTEM_VERSION"
    ;;
  *)
    echo "Unsupported CAPTURELAB_ARCH: $ARCH. Use arm64 or x86_64." >&2
    exit 2
    ;;
esac

export MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION"

DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
STAGING_DIR="$DIST_DIR/dmg-staging"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/CaptureLab.icns"
DMG_NAME="$APP_NAME-$CAPTURELAB_VERSION-macos-$ARCH.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

swift build --package-path "$ROOT_DIR" --configuration release --triple "$SWIFT_TRIPLE" --product "$APP_NAME"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --configuration release --triple "$SWIFT_TRIPLE" --show-bin-path)/$APP_NAME"

if [[ ! -f "$ICON_FILE" || "$ROOT_DIR/script/generate_app_icon.swift" -nt "$ICON_FILE" ]]; then
  swift "$ROOT_DIR/script/generate_app_icon.swift" "$ROOT_DIR"
fi

rm -rf "$APP_BUNDLE" "$STAGING_DIR" "$DMG_PATH" "$CHECKSUM_PATH"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$RELEASE_DIR" "$STAGING_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
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

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME $CAPTURELAB_VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$DMG_NAME" >"$(basename "$CHECKSUM_PATH")"
  shasum -a 256 -c "$(basename "$CHECKSUM_PATH")"
)

echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
