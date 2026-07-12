#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CaptureLab"
SWAP_HELPER_NAME="CaptureLabUpdateSwap"
UPDATE_SIGNING_PUBLIC_KEY="jBXKIXZ5O9KxP1YiHixdKc2BzzxLpUoTdRWdM1fjMLE="
LOCAL_CODE_SIGNING_IDENTITY_SHA1="636F51D5E5F9240F862327A82C3863C2F5EE7DFF"
LOCAL_CODE_SIGNING_CERTIFICATE_SHA1="636f51d5e5f9240f862327a82c3863c2f5ee7dff"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.env"

ARCH="${CAPTURELAB_ARCH:-$(uname -m)}"
BUNDLE_ID="$CAPTURELAB_BUNDLE_ID"
SWAP_HELPER_BUNDLE_ID="$BUNDLE_ID.UpdateSwap"
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
RELEASE_DIR="${CAPTURELAB_RELEASE_DIR:-$DIST_DIR/release}"
STAGING_DIR="$DIST_DIR/dmg-staging"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
SWAP_HELPER="$APP_HELPERS/$SWAP_HELPER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/CaptureLab.icns"
DMG_NAME="$APP_NAME-$CAPTURELAB_VERSION-macos-$ARCH.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
SIGNATURE_PATH="$DMG_PATH.sig"
RELEASE_WORK_DIR=""
WORK_DMG_PATH=""
WORK_CHECKSUM_PATH=""
WORK_SIGNATURE_PATH=""
PUBLISH_COMPLETE=0
UPDATE_SIGNING_TOOL="$ROOT_DIR/script/update_signing.swift"
UPDATE_SIGNING_PRIVATE_KEY="${CAPTURELAB_UPDATE_SIGNING_KEY:-$HOME/Library/Application Support/CaptureLab/Release/update-signing-private-key}"

cleanup_release_assets() {
  local exit_status="$?"
  trap - EXIT

  if [[ "$PUBLISH_COMPLETE" != "1" ]]; then
    /bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH" "$SIGNATURE_PATH" || true
  fi
  if [[ -n "$RELEASE_WORK_DIR" ]]; then
    /bin/rm -rf "$RELEASE_WORK_DIR" || true
  fi
  exit "$exit_status"
}
trap cleanup_release_assets EXIT

mkdir -p "$RELEASE_DIR"
/bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH" "$SIGNATURE_PATH"
RELEASE_WORK_DIR="$(/usr/bin/mktemp -d "$RELEASE_DIR/.$DMG_NAME.build.XXXXXX")"
WORK_DMG_PATH="$RELEASE_WORK_DIR/$DMG_NAME"
WORK_CHECKSUM_PATH="$WORK_DMG_PATH.sha256"
WORK_SIGNATURE_PATH="$WORK_DMG_PATH.sig"

if [[ ! -f "$UPDATE_SIGNING_PRIVATE_KEY" ]]; then
  echo "Missing CaptureLab update signing key: $UPDATE_SIGNING_PRIVATE_KEY" >&2
  echo "CaptureLab already embeds a locked update-signing public key." >&2
  echo "Expected public key: $UPDATE_SIGNING_PUBLIC_KEY" >&2
  echo "Restore the matching private key from its encrypted backup; a replacement key will not work." >&2
  echo "Existing installations will reject releases signed by any other key." >&2
  exit 1
fi

ACTUAL_UPDATE_SIGNING_PUBLIC_KEY="$(swift "$UPDATE_SIGNING_TOOL" public-key "$UPDATE_SIGNING_PRIVATE_KEY")"
if [[ "$ACTUAL_UPDATE_SIGNING_PUBLIC_KEY" != "$UPDATE_SIGNING_PUBLIC_KEY" ]]; then
  echo "The configured update signing key does not match CaptureLab's embedded public key." >&2
  echo "Expected public key: $UPDATE_SIGNING_PUBLIC_KEY" >&2
  echo "Restore the matching private key from its encrypted backup; a replacement key will not work." >&2
  echo "Refusing to build an update that existing installations would reject." >&2
  exit 1
fi

AVAILABLE_CODE_SIGNING_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$AVAILABLE_CODE_SIGNING_IDENTITIES" != *"$LOCAL_CODE_SIGNING_IDENTITY_SHA1"* ]]; then
  echo "Missing CaptureLab's stable local code-signing identity: $LOCAL_CODE_SIGNING_IDENTITY_SHA1" >&2
  echo "Release packaging does not permit an ad-hoc or alternate-identity fallback." >&2
  echo "Restore the matching certificate and private key from their encrypted offline backup." >&2
  exit 1
fi

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

swift build --package-path "$ROOT_DIR" --configuration release --triple "$SWIFT_TRIPLE" --product "$APP_NAME"
swift build --package-path "$ROOT_DIR" --configuration release --triple "$SWIFT_TRIPLE" --product "$SWAP_HELPER_NAME"
BUILD_BIN_DIR="$(swift build --package-path "$ROOT_DIR" --configuration release --triple "$SWIFT_TRIPLE" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_SWAP_HELPER="$BUILD_BIN_DIR/$SWAP_HELPER_NAME"

if [[ ! -f "$ICON_FILE" || "$ROOT_DIR/script/generate_app_icon.swift" -nt "$ICON_FILE" ]]; then
  swift "$ROOT_DIR/script/generate_app_icon.swift" "$ROOT_DIR"
fi

rm -rf "$APP_BUNDLE" "$STAGING_DIR"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES" "$RELEASE_DIR" "$STAGING_DIR"
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

codesign --force --sign "$LOCAL_CODE_SIGNING_IDENTITY_SHA1" \
  --identifier "$SWAP_HELPER_BUNDLE_ID" \
  "$SWAP_HELPER"
codesign --force --sign "$LOCAL_CODE_SIGNING_IDENTITY_SHA1" \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE"
[[ -f "$SWAP_HELPER" && -x "$SWAP_HELPER" && ! -L "$SWAP_HELPER" ]]
codesign --verify --strict --verbose=2 "$SWAP_HELPER"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --verify --strict \
  -R="identifier \"$SWAP_HELPER_BUNDLE_ID\" and certificate root = H\"$LOCAL_CODE_SIGNING_CERTIFICATE_SHA1\"" \
  "$SWAP_HELPER"
codesign --verify --deep --strict \
  -R="identifier \"$BUNDLE_ID\" and certificate root = H\"$LOCAL_CODE_SIGNING_CERTIFICATE_SHA1\"" \
  "$APP_BUNDLE"
APP_BINARY_ARCHS="$(/usr/bin/lipo -archs "$APP_BINARY")"
[[ " $APP_BINARY_ARCHS " == *" $ARCH "* ]] || {
  echo "$APP_BINARY does not contain the expected $ARCH architecture." >&2
  exit 1
}
SWAP_HELPER_ARCHS="$(/usr/bin/lipo -archs "$SWAP_HELPER")"
[[ " $SWAP_HELPER_ARCHS " == *" $ARCH "* ]] || {
  echo "$SWAP_HELPER does not contain the expected $ARCH architecture." >&2
  exit 1
}

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME $CAPTURELAB_VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$WORK_DMG_PATH"

hdiutil verify "$WORK_DMG_PATH"

(
  cd "$RELEASE_WORK_DIR"
  shasum -a 256 "$DMG_NAME" >"$(basename "$WORK_CHECKSUM_PATH")"
  shasum -a 256 -c "$(basename "$WORK_CHECKSUM_PATH")"
)

swift "$UPDATE_SIGNING_TOOL" sign \
  "$UPDATE_SIGNING_PRIVATE_KEY" \
  "$UPDATE_SIGNING_PUBLIC_KEY" \
  "$WORK_DMG_PATH" \
  "$WORK_SIGNATURE_PATH"
swift "$UPDATE_SIGNING_TOOL" verify \
  "$UPDATE_SIGNING_PUBLIC_KEY" \
  "$WORK_DMG_PATH" \
  "$WORK_SIGNATURE_PATH"

/bin/mv "$WORK_DMG_PATH" "$DMG_PATH"
/bin/mv "$WORK_CHECKSUM_PATH" "$CHECKSUM_PATH"
/bin/mv "$WORK_SIGNATURE_PATH" "$SIGNATURE_PATH"
PUBLISH_COMPLETE=1

echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
echo "$SIGNATURE_PATH"
