import AppKit
import Foundation

struct UpdateInstallService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func installAndRelaunch(
        dmgURL: URL,
        targetBundleURL: URL = Bundle.main.bundleURL,
        processID: pid_t = getpid()
    ) throws {
        guard targetBundleURL.pathExtension == "app" else {
            throw UpdateInstallError.invalidBundleLocation
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("CaptureLab", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let scriptURL = directory.appendingPathComponent("install-capturelab-update.sh")
        try Self.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            scriptURL.path,
            "\(processID)",
            dmgURL.path,
            targetBundleURL.path
        ]

        do {
            try process.run()
        } catch {
            throw UpdateInstallError.installerLaunchFailed(error.localizedDescription)
        }
    }

    private static let installScript = #"""
#!/bin/zsh
set -euo pipefail

APP_NAME="CaptureLab"
APP_PID="$1"
DMG_PATH="$2"
TARGET_BUNDLE="$3"
TMP_ROOT="${TMPDIR:-/tmp}"
LOG_PATH="$TMP_ROOT/capturelab-update.log"
MOUNT_DIR="$(/usr/bin/mktemp -d "$TMP_ROOT/capturelab-update-mount.XXXXXX")"

fail() {
  local message="$1"
  echo "$message" >> "$LOG_PATH"
  /usr/bin/open "$DMG_PATH" >/dev/null 2>&1 || true
  /usr/bin/osascript -e 'display dialog "CaptureLab could not install the update automatically. The downloaded disk image has been opened so you can install it manually." buttons {"OK"} default button "OK" with icon caution' >/dev/null 2>&1 || true
  exit 1
}

cleanup() {
  /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  /bin/rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

while /bin/kill -0 "$APP_PID" 2>/dev/null; do
  /bin/sleep 0.2
done

/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet || fail "Could not mount update disk image."
SOURCE_APP="$MOUNT_DIR/$APP_NAME.app"
[[ -d "$SOURCE_APP" ]] || fail "Update disk image does not contain $APP_NAME.app."

TARGET_PARENT="$(/usr/bin/dirname "$TARGET_BUNDLE")"
STAGING_PARENT="$TARGET_PARENT/.$APP_NAME.update.$$"
STAGED_BUNDLE="$STAGING_PARENT/$APP_NAME.app"

/bin/rm -rf "$STAGING_PARENT"
/bin/mkdir -p "$STAGING_PARENT" || fail "Could not create update staging directory."
/usr/bin/ditto "$SOURCE_APP" "$STAGED_BUNDLE" || fail "Could not stage updated app."
/bin/rm -rf "$TARGET_BUNDLE" || fail "Could not remove current app bundle."
/bin/mv "$STAGED_BUNDLE" "$TARGET_BUNDLE" || fail "Could not install updated app bundle."
/bin/rm -rf "$STAGING_PARENT"
/bin/rm -f "$DMG_PATH"

/usr/bin/open "$TARGET_BUNDLE" || fail "Could not relaunch updated app."
"""#
}

enum UpdateInstallError: LocalizedError {
    case invalidBundleLocation
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBundleLocation:
            return L10n.updateInstallFailed("The current app bundle could not be located.")
        case .installerLaunchFailed(let message):
            return L10n.updateInstallFailed(message)
        }
    }
}
