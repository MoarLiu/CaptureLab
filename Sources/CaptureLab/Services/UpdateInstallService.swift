import AppKit
import Darwin
import Foundation

struct UpdateInstallService {
    static let installLockTimeoutSeconds = 180

    struct PackageMetadata: Equatable {
        var version: String
        var architecture: String
    }

    private let fileManager: FileManager
    private let swapHelperURL: URL

    init(
        fileManager: FileManager = .default,
        swapHelperURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CaptureLabUpdateSwap", isDirectory: false)
    ) {
        self.fileManager = fileManager
        self.swapHelperURL = swapHelperURL
    }

    func installAndRelaunch(
        dmgURL: URL,
        expectedVersion: String? = nil,
        expectedArchitecture: String? = nil,
        expectedBundleIdentifier: String = "com.crazyjal.CaptureLab",
        targetBundleURL: URL = Bundle.main.bundleURL,
        processID: pid_t = getpid()
    ) throws {
        let standardizedTargetBundleURL = targetBundleURL.standardizedFileURL
        guard standardizedTargetBundleURL.isFileURL,
              standardizedTargetBundleURL.pathExtension == "app"
        else {
            throw UpdateInstallError.invalidBundleLocation
        }
        guard Self.isRegularExecutableFile(at: swapHelperURL) else {
            throw UpdateInstallError.invalidSwapHelper
        }

        let metadata = try Self.packageMetadata(from: dmgURL)
        let version = expectedVersion ?? metadata.version
        let architecture = expectedArchitecture ?? metadata.architecture
        guard !version.isEmpty,
              ["arm64", "x86_64"].contains(architecture),
              !expectedBundleIdentifier.isEmpty
        else {
            throw UpdateInstallError.invalidUpdatePackage
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("CaptureLab", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let scriptURL = directory.appendingPathComponent(
            "install-capturelab-update-\(UUID().uuidString).sh"
        )
        try Self.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let lockURL = Self.installLockURL(for: standardizedTargetBundleURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            Self.installLauncherScript,
            "capturelab-update-launcher",
            lockURL.path,
            "\(Self.installLockTimeoutSeconds)",
            scriptURL.path,
            "\(processID)",
            dmgURL.path,
            standardizedTargetBundleURL.path,
            expectedBundleIdentifier,
            version,
            architecture,
            swapHelperURL.path
        ]

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: scriptURL)
            throw UpdateInstallError.installerLaunchFailed(error.localizedDescription)
        }
    }

    static func installLockURL(for targetBundleURL: URL) -> URL {
        targetBundleURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".CaptureLab.update.lock", isDirectory: false)
    }

    static func isRegularExecutableFile(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var status = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &status) == 0
                && status.st_mode & S_IFMT == S_IFREG
                && access(path, X_OK) == 0
        }
    }

    static func packageMetadata(from dmgURL: URL) throws -> PackageMetadata {
        let name = dmgURL.lastPathComponent
        let prefix = "CaptureLab-"
        let suffix = ".dmg"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            throw UpdateInstallError.invalidUpdatePackage
        }

        let body = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        for architecture in ["arm64", "x86_64"] {
            let marker = "-macos-\(architecture)"
            guard body.hasSuffix(marker) else { continue }
            let version = String(body.dropLast(marker.count))
            guard !version.isEmpty,
                  version.range(of: "^[0-9]+(?:\\.[0-9]+)*(?:[-+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil
            else {
                throw UpdateInstallError.invalidUpdatePackage
            }
            return PackageMetadata(version: version, architecture: architecture)
        }
        throw UpdateInstallError.invalidUpdatePackage
    }

    static let safeRelaunchShellFunctions = #"""
capturelab_relaunch_command_matches_binary() {
  local command="$1"
  local expected_binary="$2"
  local double_quoted_binary="\"$expected_binary\""
  local single_quoted_binary="'$expected_binary'"

  [[ "$command" == "$expected_binary" || "$command" == "$expected_binary "* ]] ||
    [[ "$command" == "$double_quoted_binary" || "$command" == "$double_quoted_binary "* ]] ||
    [[ "$command" == "$single_quoted_binary" || "$command" == "$single_quoted_binary "* ]]
}

capturelab_target_process_is_running() {
  local expected_binary="$1"
  local pid
  local command

  while IFS= read -r pid; do
    [[ "$pid" == <-> && "$pid" -gt 1 ]] || continue
    command="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$command" ]] || continue
    capturelab_relaunch_command_matches_binary "$command" "$expected_binary" && return 0
  done <<< "$(/usr/bin/pgrep -x CaptureLab 2>/dev/null || true)"
  return 1
}

capturelab_safe_relaunch_target() {
  local target_bundle="$1"
  local expected_bundle_id="$2"
  local expected_arch="$3"
  local originating_pid="$4"
  local log_path="$5"
  local info_plist="$target_bundle/Contents/Info.plist"
  local executable="$target_bundle/Contents/MacOS/CaptureLab"
  local bundle_id
  local version
  local architectures
  local version_pattern='^[0-9]+(\.[0-9]+)*([-+][A-Za-z0-9.-]+)?$'

  if [[ "$originating_pid" == <-> && "$originating_pid" -gt 1 ]]; then
    for _ in {1..50}; do
      /bin/kill -0 "$originating_pid" 2>/dev/null || break
      /bin/sleep 0.1
    done
  fi

  [[ -d "$target_bundle" && ! -L "$target_bundle" ]] || return 1
  [[ -f "$info_plist" && -x "$executable" && ! -L "$executable" ]] || return 1
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null)" || return 1
  [[ "$bundle_id" == "$expected_bundle_id" ]] || return 1
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null)" || return 1
  [[ "$version" =~ "$version_pattern" ]] || return 1
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target_bundle" >/dev/null 2>&1 || return 1
  architectures="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)" || return 1
  [[ " $architectures " == *" $expected_arch "* ]] || return 1

  capturelab_target_process_is_running "$executable" && return 0
  /usr/bin/open "$target_bundle" >/dev/null 2>&1
}
"""#

    static let installLauncherScript = #"""
LOCK_PATH="$1"
LOCK_TIMEOUT_SECONDS="$2"
INSTALL_SCRIPT="$3"
shift 3

TMP_ROOT="${TMPDIR:-/tmp}"
LOG_PATH="$TMP_ROOT/capturelab-update.log"
"""# + "\n" + safeRelaunchShellFunctions + #"""

relaunch_after_launcher_failure() {
  local app_pid="$1"
  local target_bundle="$3"
  local expected_bundle_id="$4"
  local expected_arch="$6"

  capturelab_safe_relaunch_target \
    "$target_bundle" \
    "$expected_bundle_id" \
    "$expected_arch" \
    "$app_pid" \
    "$LOG_PATH" || true
}

if [[ "$LOCK_TIMEOUT_SECONDS" != <-> || "$LOCK_TIMEOUT_SECONDS" -le 0 ]]; then
  /bin/rm -f "$INSTALL_SCRIPT" >/dev/null 2>&1 || true
  relaunch_after_launcher_failure "$@"
  exit 64
fi

/usr/bin/lockf -k -s -w -t "$LOCK_TIMEOUT_SECONDS" "$LOCK_PATH" \
  /bin/zsh -c '
    /bin/zsh "$@"
    command_status="$?"
    [[ "$command_status" == "0" ]] && exit 0
    exit 1
  ' capturelab-update-command "$INSTALL_SCRIPT" "$@"
LOCK_STATUS="$?"
/bin/rm -f "$INSTALL_SCRIPT" >/dev/null 2>&1 || true

case "$LOCK_STATUS" in
  0)
    exit 0
    ;;
  75)
    LOCK_FAILURE_MESSAGE="Another CaptureLab update is already being installed. Please try again after it finishes."
    ;;
  73)
    LOCK_FAILURE_MESSAGE="CaptureLab could not create the update lock beside the app. Check that the app's folder is writable."
    ;;
  1)
    relaunch_after_launcher_failure "$@"
    exit 1
    ;;
  *)
    LOCK_FAILURE_MESSAGE="CaptureLab could not start the serialized update installer safely. Please try again."
    ;;
esac

relaunch_after_launcher_failure "$@"
echo "$LOCK_FAILURE_MESSAGE" >> "$TMP_ROOT/capturelab-update.log" 2>/dev/null || true
/usr/bin/osascript -e "display dialog \"$LOCK_FAILURE_MESSAGE\" buttons {\"OK\"} default button \"OK\" with icon caution" >/dev/null 2>&1 || true
exit "$LOCK_STATUS"
"""#

    static let updateDecisionShellFunctions = #"""
capturelab_version_is_valid() {
  local version="$1"
  local pattern='^[0-9]+(\.[0-9]+)*([-+][A-Za-z0-9.-]+)?$'

  [[ "$version" =~ "$pattern" ]] || return 1
  if [[ "$version" == *-* ]]; then
    local prerelease="${version#*-}"
    [[ "$prerelease" != .* && "$prerelease" != *. && "$prerelease" != *..* ]] || return 1
  fi
}

capturelab_normalize_decimal() {
  local value="$1"

  while [[ "${#value}" -gt 1 && "$value" == 0* ]]; do
    value="${value#0}"
  done
  /usr/bin/printf '%s\n' "$value"
}

capturelab_compare_decimal() {
  local left
  local right

  left="$(capturelab_normalize_decimal "$1")" || return 2
  right="$(capturelab_normalize_decimal "$2")" || return 2
  if [[ "${#left}" -lt "${#right}" ]]; then
    echo -1
  elif [[ "${#left}" -gt "${#right}" ]]; then
    echo 1
  elif [[ "$left" == "$right" ]]; then
    echo 0
  elif [[ "$left" < "$right" ]]; then
    echo -1
  else
    echo 1
  fi
}

capturelab_compare_versions() {
  local left_version="$1"
  local right_version="$2"
  local left_core
  local right_core
  local left_prerelease=""
  local right_prerelease=""
  local comparison
  local index
  local count
  local left_part
  local right_part
  local left_is_numeric
  local right_is_numeric
  local -a left_parts
  local -a right_parts

  capturelab_version_is_valid "$left_version" || return 2
  capturelab_version_is_valid "$right_version" || return 2
  left_core="${left_version%%[-+]*}"
  right_core="${right_version%%[-+]*}"
  left_parts=("${(@s:.:)left_core}")
  right_parts=("${(@s:.:)right_core}")
  count="${#left_parts[@]}"
  [[ "${#right_parts[@]}" -gt "$count" ]] && count="${#right_parts[@]}"

  for (( index = 1; index <= count; index++ )); do
    left_part="${left_parts[index]:-0}"
    right_part="${right_parts[index]:-0}"
    comparison="$(capturelab_compare_decimal "$left_part" "$right_part")" || return 2
    if [[ "$comparison" != "0" ]]; then
      echo "$comparison"
      return 0
    fi
  done

  [[ "$left_version" == *-* ]] && left_prerelease="${left_version#*-}"
  [[ "$right_version" == *-* ]] && right_prerelease="${right_version#*-}"
  if [[ -z "$left_prerelease" && -z "$right_prerelease" ]]; then
    echo 0
    return 0
  fi
  if [[ -z "$left_prerelease" ]]; then
    echo 1
    return 0
  fi
  if [[ -z "$right_prerelease" ]]; then
    echo -1
    return 0
  fi

  left_parts=("${(@s:.:)left_prerelease}")
  right_parts=("${(@s:.:)right_prerelease}")
  count="${#left_parts[@]}"
  [[ "${#right_parts[@]}" -gt "$count" ]] && count="${#right_parts[@]}"
  for (( index = 1; index <= count; index++ )); do
    if [[ "$index" -gt "${#left_parts[@]}" ]]; then
      echo -1
      return 0
    fi
    if [[ "$index" -gt "${#right_parts[@]}" ]]; then
      echo 1
      return 0
    fi

    left_part="${left_parts[index]}"
    right_part="${right_parts[index]}"
    [[ "$left_part" == <-> ]] && left_is_numeric=1 || left_is_numeric=0
    [[ "$right_part" == <-> ]] && right_is_numeric=1 || right_is_numeric=0
    if [[ "$left_is_numeric" == "1" && "$right_is_numeric" == "1" ]]; then
      comparison="$(capturelab_compare_decimal "$left_part" "$right_part")" || return 2
      if [[ "$comparison" != "0" ]]; then
        echo "$comparison"
        return 0
      fi
    elif [[ "$left_is_numeric" == "1" ]]; then
      echo -1
      return 0
    elif [[ "$right_is_numeric" == "1" ]]; then
      echo 1
      return 0
    elif [[ "$left_part" != "$right_part" ]]; then
      [[ "$left_part" < "$right_part" ]] && echo -1 || echo 1
      return 0
    fi
  done

  echo 0
}

capturelab_update_decision() {
  local current_version="$1"
  local expected_version="$2"
  local running_target_pids="$3"
  local comparison

  comparison="$(capturelab_compare_versions "$current_version" "$expected_version")" || return 2
  if [[ "$comparison" != "-1" ]]; then
    echo noop
  elif [[ -n "$running_target_pids" ]]; then
    echo blocked
  else
    echo install
  fi
}
"""#

    static let processHealthShellFunctions = #"""
is_safe_process_id() {
  local pid="$1"
  [[ "$pid" == <-> && "$pid" -gt 1 ]]
}

pid_snapshot_contains() {
  local snapshot="$1"
  local expected_pid="$2"
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "$expected_pid" ]] && return 0
  done <<< "$snapshot"
  return 1
}

command_matches_expected_binary() {
  local command="$1"
  local expected_binary="$2"
  local double_quoted_binary="\"$expected_binary\""
  local single_quoted_binary="'$expected_binary'"

  [[ "$command" == "$expected_binary" || "$command" == "$expected_binary "* ]] ||
    [[ "$command" == "$double_quoted_binary" || "$command" == "$double_quoted_binary "* ]] ||
    [[ "$command" == "$single_quoted_binary" || "$command" == "$single_quoted_binary "* ]]
}

process_start_token() {
  local pid="$1"
  local start_token

  is_safe_process_id "$pid" || return 1
  start_token="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null || true)"
  [[ -n "$start_token" ]] || return 1
  /usr/bin/printf '%s\n' "$start_token"
}

tracked_start_token_for_pid() {
  local expected_pid="$1"
  local pid
  local start_token

  while IFS=$'\t' read -r pid start_token; do
    [[ "$pid" == "$expected_pid" && -n "$start_token" ]] || continue
    /usr/bin/printf '%s\n' "$start_token"
    return 0
  done <<< "$TRACKED_UPDATE_START_RECORDS"
  return 1
}

process_generation_is_still_tracked() {
  local pid="$1"
  local tracked_start_token
  local current_start_token

  tracked_start_token="$(tracked_start_token_for_pid "$pid" || true)"
  [[ -n "$tracked_start_token" ]] || return 1
  current_start_token="$(process_start_token "$pid" || true)"
  [[ -n "$current_start_token" && "$current_start_token" == "$tracked_start_token" ]]
}

select_new_expected_pid_from_records() {
  local preexisting_pids="$1"
  local expected_binary="$2"
  local records="$3"
  local pid
  local start_token
  local command

  while IFS=$'\t' read -r pid start_token command; do
    [[ -n "$pid" && -n "$start_token" && -n "$command" ]] || continue
    is_safe_process_id "$pid" || continue
    pid_snapshot_contains "$preexisting_pids" "$pid" && continue
    command_matches_expected_binary "$command" "$expected_binary" || continue
    echo "$pid"
    return 0
  done <<< "$records"
  return 1
}

remember_update_pid() {
  local pid="$1"
  local start_token="$2"

  is_safe_process_id "$pid" || return 1
  [[ -n "$start_token" ]] || return 1
  pid_snapshot_contains "$PREEXISTING_PIDS" "$pid" && return 1
  pid_snapshot_contains "$TRACKED_UPDATE_PIDS" "$pid" && return 0
  if [[ -n "$TRACKED_UPDATE_PIDS" ]]; then
    TRACKED_UPDATE_PIDS+=$'\n'
  fi
  TRACKED_UPDATE_PIDS+="$pid"
  if [[ -n "$TRACKED_UPDATE_START_RECORDS" ]]; then
    TRACKED_UPDATE_START_RECORDS+=$'\n'
  fi
  TRACKED_UPDATE_START_RECORDS+="$pid"$'\t'"$start_token"
}

track_new_expected_pids_from_records() {
  local records="$1"
  local pid
  local start_token
  local command

  while IFS=$'\t' read -r pid start_token command; do
    [[ -n "$pid" && -n "$start_token" && -n "$command" ]] || continue
    is_safe_process_id "$pid" || continue
    pid_snapshot_contains "$PREEXISTING_PIDS" "$pid" && continue
    command_matches_expected_binary "$command" "$EXPECTED_BINARY" || continue
    remember_update_pid "$pid" "$start_token"
  done <<< "$records"
}

signal_tracked_update_pids() {
  local signal="$1"
  local pid

  while IFS= read -r pid; do
    is_safe_process_id "$pid" || continue
    pid_snapshot_contains "$PREEXISTING_PIDS" "$pid" && continue
    /bin/kill -0 "$pid" 2>/dev/null || continue
    process_generation_is_still_tracked "$pid" || continue
    /bin/kill "-$signal" "$pid" 2>/dev/null || true
  done <<< "$TRACKED_UPDATE_PIDS"
}

wait_for_tracked_update_pids_to_exit() {
  local attempts="$1"
  local attempt
  local pid
  local found_running

  for (( attempt = 0; attempt < attempts; attempt++ )); do
    found_running=0
    while IFS= read -r pid; do
      is_safe_process_id "$pid" || continue
      pid_snapshot_contains "$PREEXISTING_PIDS" "$pid" && continue
      if /bin/kill -0 "$pid" 2>/dev/null &&
          process_generation_is_still_tracked "$pid"; then
        found_running=1
        break
      fi
    done <<< "$TRACKED_UPDATE_PIDS"
    [[ "$found_running" == "0" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

terminate_tracked_update_pids() {
  signal_tracked_update_pids TERM
  wait_for_tracked_update_pids_to_exit 20 && return 0
  signal_tracked_update_pids KILL
  wait_for_tracked_update_pids_to_exit 10 || true
}

capturelab_pid_snapshot() {
  /usr/bin/pgrep -x "$APP_NAME" 2>/dev/null | /usr/bin/sort -n || true
}

capturelab_process_records() {
  local snapshot
  local pid
  local start_token
  local command

  snapshot="$(capturelab_pid_snapshot)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    start_token="$(process_start_token "$pid" || true)"
    [[ -n "$start_token" ]] || continue
    command="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$command" ]] || continue
    /usr/bin/printf '%s\t%s\t%s\n' "$pid" "$start_token" "$command"
  done <<< "$snapshot"
}
"""#

    static let installScript = #"""
#!/bin/zsh
set -euo pipefail
export LC_ALL=C

APP_NAME="CaptureLab"
APP_PID="$1"
DMG_PATH="$2"
TARGET_BUNDLE="$3"
EXPECTED_BUNDLE_ID="$4"
EXPECTED_VERSION="$5"
EXPECTED_ARCH="$6"
CURRENT_SWAP_HELPER="$7"
TMP_ROOT="${TMPDIR:-/tmp}"
LOG_PATH="$TMP_ROOT/capturelab-update.log"
MOUNT_DIR=""
TARGET_PARENT="$(/usr/bin/dirname "$TARGET_BUNDLE")"
STAGING_PARENT=""
STAGED_BUNDLE=""
SWAP_HELPER=""
REPLACEMENT_STARTED=0
UPDATE_LAUNCH_STARTED=0
PREEXISTING_PIDS=""
EXPECTED_BINARY="$TARGET_BUNDLE/Contents/MacOS/$APP_NAME"
TRACKED_UPDATE_PIDS=""
TRACKED_UPDATE_START_RECORDS=""
"""# + "\n" + safeRelaunchShellFunctions + "\n" + updateDecisionShellFunctions + "\n" + processHealthShellFunctions + #"""

terminate_launched_update_processes() {
  [[ "$UPDATE_LAUNCH_STARTED" == "1" ]] || return 0
  local process_records

  # Catch every matching process from this launch, including a sibling that was
  # not selected for the health check. Signal promptly, then keep observing for
  # a short grace period in case LaunchServices completes asynchronously.
  for _ in {1..5}; do
    process_records="$(capturelab_process_records)"
    track_new_expected_pids_from_records "$process_records"
    signal_tracked_update_pids TERM
    /bin/sleep 0.1
  done

  terminate_tracked_update_pids
  UPDATE_LAUNCH_STARTED=0
}

is_regular_executable() {
  local executable="$1"
  [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]]
}

binary_contains_expected_architecture() {
  local executable="$1"
  local architectures

  architectures="$(/usr/bin/lipo -archs "$executable" 2>> "$LOG_PATH")" || return 1
  [[ " $architectures " == *" $EXPECTED_ARCH "* ]]
}

verify_swap_helper() {
  local helper="$1"

  is_regular_executable "$helper" || return 1
  /usr/bin/codesign --verify --strict --verbose=2 "$helper" >> "$LOG_PATH" 2>&1 || return 1
  binary_contains_expected_architecture "$helper"
}

remove_downloaded_asset_set() {
  local update_directory

  update_directory="$(/usr/bin/dirname "$DMG_PATH")"
  /bin/rm -f "$DMG_PATH" "$DMG_PATH.sha256" "$DMG_PATH.sig"
  /bin/rmdir "$update_directory" 2>/dev/null || true
}

validated_target_version() {
  local target_plist="$TARGET_BUNDLE/Contents/Info.plist"
  local target_binary="$TARGET_BUNDLE/Contents/MacOS/$APP_NAME"
  local target_bundle_id
  local target_version

  [[ -d "$TARGET_BUNDLE" && ! -L "$TARGET_BUNDLE" ]] || return 1
  [[ -f "$target_plist" && -x "$target_binary" && ! -L "$target_binary" ]] || return 1
  target_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_plist" 2>> "$LOG_PATH")" || return 1
  [[ "$target_bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || return 1
  target_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target_plist" 2>> "$LOG_PATH")" || return 1
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE" >> "$LOG_PATH" 2>&1 || return 1
  binary_contains_expected_architecture "$target_binary" || return 1
  /usr/bin/printf '%s\n' "$target_version"
}

target_binary_running_pids() {
  local records
  local pid
  local start_token
  local command

  records="$(capturelab_process_records)"
  while IFS=$'\t' read -r pid start_token command; do
    [[ -n "$pid" && -n "$start_token" && -n "$command" ]] || continue
    command_matches_expected_binary "$command" "$EXPECTED_BINARY" || continue
    /usr/bin/printf '%s\n' "$pid"
  done <<< "$records"
}

evaluate_target_update_decision() {
  local current_version
  local running_target_pids

  current_version="$(validated_target_version)" || return 2
  running_target_pids="$(target_binary_running_pids)"
  capturelab_update_decision "$current_version" "$EXPECTED_VERSION" "$running_target_pids"
}

finish_without_replacing_target() {
  remove_downloaded_asset_set
  capturelab_safe_relaunch_target \
    "$TARGET_BUNDLE" \
    "$EXPECTED_BUNDLE_ID" \
    "$EXPECTED_ARCH" \
    "$APP_PID" \
    "$LOG_PATH" || true
  exit 0
}

rollback_replacement() {
  [[ "$REPLACEMENT_STARTED" == "1" ]] || return 0
  [[ -n "$SWAP_HELPER" && -n "$STAGED_BUNDLE" ]] || return 1
  [[ -d "$TARGET_BUNDLE" && ! -L "$TARGET_BUNDLE" ]] || return 1
  [[ -d "$STAGED_BUNDLE" && ! -L "$STAGED_BUNDLE" ]] || return 1
  verify_swap_helper "$SWAP_HELPER" || return 1
  "$SWAP_HELPER" "$TARGET_BUNDLE" "$STAGED_BUNDLE" >> "$LOG_PATH" 2>&1 || return 1
  REPLACEMENT_STARTED=0
}

fail() {
  local message="$1"
  local target_can_be_relaunched=0

  echo "$message" >> "$LOG_PATH"
  terminate_launched_update_processes
  if [[ "$REPLACEMENT_STARTED" == "1" ]]; then
    if rollback_replacement; then
      target_can_be_relaunched=1
    else
      echo "Could not atomically restore the previous CaptureLab bundle; it remains in $STAGED_BUNDLE." >> "$LOG_PATH"
    fi
  else
    target_can_be_relaunched=1
  fi
  if [[ "$target_can_be_relaunched" == "1" ]]; then
    capturelab_safe_relaunch_target \
      "$TARGET_BUNDLE" \
      "$EXPECTED_BUNDLE_ID" \
      "$EXPECTED_ARCH" \
      "$APP_PID" \
      "$LOG_PATH" || true
  fi
  /usr/bin/osascript -e 'display dialog "CaptureLab rejected or could not install this update safely. The existing app was preserved. Please download a fresh release from the official CaptureLab repository." buttons {"OK"} default button "OK" with icon caution' >/dev/null 2>&1 || true
  exit 1
}

cleanup() {
  local exit_status="$?"
  trap - EXIT

  if [[ "$REPLACEMENT_STARTED" == "1" ]]; then
    terminate_launched_update_processes
    if rollback_replacement; then
      capturelab_safe_relaunch_target \
        "$TARGET_BUNDLE" \
        "$EXPECTED_BUNDLE_ID" \
        "$EXPECTED_ARCH" \
        "$APP_PID" \
        "$LOG_PATH" || true
    else
      echo "Could not atomically restore the previous CaptureLab bundle; preserving $STAGING_PARENT." >> "$LOG_PATH"
    fi
  fi
  if [[ -n "$MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    /bin/rm -rf "$MOUNT_DIR" || true
  fi
  if [[ "$REPLACEMENT_STARTED" == "0" && -n "$STAGING_PARENT" ]]; then
    /bin/rm -rf "$STAGING_PARENT" || true
  fi
  exit "$exit_status"
}
trap cleanup EXIT

MOUNT_DIR="$(/usr/bin/mktemp -d "$TMP_ROOT/capturelab-update-mount.XXXXXX")" || fail "Could not create a temporary update mount directory."

for _ in {1..300}; do
  /bin/kill -0 "$APP_PID" 2>/dev/null || break
  /bin/sleep 0.2
done
/bin/kill -0 "$APP_PID" 2>/dev/null && fail "CaptureLab did not quit in time; the update was not installed."

TARGET_DECISION="$(evaluate_target_update_decision)" || fail "The installed CaptureLab bundle could not be validated before updating."
case "$TARGET_DECISION" in
  noop)
    finish_without_replacing_target
    ;;
  blocked)
    fail "Another CaptureLab instance is still running from the target bundle; the update was not installed."
    ;;
  install)
    ;;
  *)
    fail "The installed CaptureLab version could not be compared safely."
    ;;
esac

/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet || fail "Could not mount update disk image."
SOURCE_APP="$MOUNT_DIR/$APP_NAME.app"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || fail "Update disk image does not contain a regular $APP_NAME.app bundle."

SOURCE_PLIST="$SOURCE_APP/Contents/Info.plist"
SOURCE_BINARY="$SOURCE_APP/Contents/MacOS/$APP_NAME"
[[ -f "$SOURCE_PLIST" && -x "$SOURCE_BINARY" ]] || fail "The update app bundle is incomplete."

CANDIDATE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_PLIST" 2>> "$LOG_PATH")" || fail "Could not read the update bundle identifier."
[[ "$CANDIDATE_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "The update bundle identifier does not match CaptureLab."
CANDIDATE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_PLIST" 2>> "$LOG_PATH")" || fail "Could not read the update version."
[[ "$CANDIDATE_VERSION" == "$EXPECTED_VERSION" ]] || fail "The update version does not match the signed package."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP" >> "$LOG_PATH" 2>&1 || fail "The update app has an invalid code signature."
CANDIDATE_ARCHS="$(/usr/bin/lipo -archs "$SOURCE_BINARY" 2>> "$LOG_PATH")" || fail "Could not inspect the update architecture."
[[ " $CANDIDATE_ARCHS " == *" $EXPECTED_ARCH "* ]] || fail "The update does not contain the expected architecture."

STAGING_PARENT="$(/usr/bin/mktemp -d "$TARGET_PARENT/.$APP_NAME.update.XXXXXX")" || fail "Could not create update staging directory."
STAGED_BUNDLE="$STAGING_PARENT/$APP_NAME.app"
SWAP_HELPER="$STAGING_PARENT/$APP_NAME-update-swap"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_BUNDLE" || fail "Could not stage updated app."
verify_swap_helper "$CURRENT_SWAP_HELPER" || fail "The current app does not contain a valid update swap helper."
/usr/bin/ditto "$CURRENT_SWAP_HELPER" "$SWAP_HELPER" || fail "Could not stage the update swap helper."
verify_swap_helper "$SWAP_HELPER" || fail "The staged update swap helper is invalid."

STAGED_PLIST="$STAGED_BUNDLE/Contents/Info.plist"
STAGED_BINARY="$STAGED_BUNDLE/Contents/MacOS/$APP_NAME"
STAGED_EMBEDDED_HELPER="$STAGED_BUNDLE/Contents/Helpers/CaptureLabUpdateSwap"
[[ -d "$STAGED_BUNDLE" && ! -L "$STAGED_BUNDLE" ]] || fail "The staged update is not a regular app bundle."
[[ -f "$STAGED_PLIST" && -x "$STAGED_BINARY" ]] || fail "The staged update app bundle is incomplete."
STAGED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_PLIST" 2>> "$LOG_PATH")" || fail "Could not read the staged update bundle identifier."
[[ "$STAGED_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "The staged update bundle identifier does not match CaptureLab."
STAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_PLIST" 2>> "$LOG_PATH")" || fail "Could not read the staged update version."
[[ "$STAGED_VERSION" == "$EXPECTED_VERSION" ]] || fail "The staged update version does not match the signed package."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_BUNDLE" >> "$LOG_PATH" 2>&1 || fail "The staged update has an invalid code signature."
binary_contains_expected_architecture "$STAGED_BINARY" || fail "The staged update does not contain the expected architecture."
verify_swap_helper "$STAGED_EMBEDDED_HELPER" || fail "The staged update does not contain a valid update swap helper."

PREEXISTING_PIDS="$(capturelab_pid_snapshot)"
TARGET_DECISION="$(evaluate_target_update_decision)" || fail "The installed CaptureLab bundle changed while the update was being staged."
case "$TARGET_DECISION" in
  noop)
    finish_without_replacing_target
    ;;
  blocked)
    fail "A CaptureLab instance started while the update was being staged; the update was not installed."
    ;;
  install)
    ;;
  *)
    fail "The installed CaptureLab version changed unexpectedly before replacement."
    ;;
esac

"$SWAP_HELPER" "$TARGET_BUNDLE" "$STAGED_BUNDLE" >> "$LOG_PATH" 2>&1 || fail "Could not atomically install the updated app bundle."
REPLACEMENT_STARTED=1

UPDATE_LAUNCH_STARTED=1
/usr/bin/open -n "$TARGET_BUNDLE" >> "$LOG_PATH" 2>&1 || fail "Could not relaunch updated app."
NEW_PID=""
for _ in {1..25}; do
  PROCESS_RECORDS="$(capturelab_process_records)"
  track_new_expected_pids_from_records "$PROCESS_RECORDS"
  NEW_PID="$(select_new_expected_pid_from_records "$PREEXISTING_PIDS" "$EXPECTED_BINARY" "$PROCESS_RECORDS" || true)"
  [[ -n "$NEW_PID" ]] && break
  /bin/sleep 0.2
done
[[ -n "$NEW_PID" ]] || fail "The updated app did not start; restoring the previous version."
process_generation_is_still_tracked "$NEW_PID" || fail "The updated app process identity changed during launch; restoring the previous version."
NEW_COMMAND="$(/bin/ps -ww -p "$NEW_PID" -o command= 2>/dev/null || true)"
command_matches_expected_binary "$NEW_COMMAND" "$EXPECTED_BINARY" || fail "A different CaptureLab process was detected; restoring the previous version."
/bin/sleep 2
/bin/kill -0 "$NEW_PID" 2>/dev/null || fail "The updated app exited during launch; restoring the previous version."
process_generation_is_still_tracked "$NEW_PID" || fail "The updated app process was replaced during launch; restoring the previous version."
STABLE_COMMAND="$(/bin/ps -ww -p "$NEW_PID" -o command= 2>/dev/null || true)"
command_matches_expected_binary "$STABLE_COMMAND" "$EXPECTED_BINARY" || fail "The updated app process changed during launch; restoring the previous version."
process_generation_is_still_tracked "$NEW_PID" || fail "The updated app process was replaced during validation; restoring the previous version."

FINAL_PLIST="$TARGET_BUNDLE/Contents/Info.plist"
FINAL_BINARY="$TARGET_BUNDLE/Contents/MacOS/$APP_NAME"
FINAL_EMBEDDED_HELPER="$TARGET_BUNDLE/Contents/Helpers/CaptureLabUpdateSwap"
[[ -d "$TARGET_BUNDLE" && ! -L "$TARGET_BUNDLE" ]] || fail "The installed update bundle changed unexpectedly; restoring the previous version."
[[ -f "$FINAL_PLIST" && -x "$FINAL_BINARY" ]] || fail "The installed update bundle is incomplete; restoring the previous version."
FINAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FINAL_PLIST" 2>> "$LOG_PATH")" || fail "Could not revalidate the installed bundle identifier."
[[ "$FINAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "The installed bundle identifier changed unexpectedly; restoring the previous version."
FINAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FINAL_PLIST" 2>> "$LOG_PATH")" || fail "Could not revalidate the installed update version."
[[ "$FINAL_VERSION" == "$EXPECTED_VERSION" ]] || fail "The installed update version changed unexpectedly; restoring the previous version."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE" >> "$LOG_PATH" 2>&1 || fail "The installed update signature changed unexpectedly; restoring the previous version."
binary_contains_expected_architecture "$FINAL_BINARY" || fail "The installed update architecture changed unexpectedly; restoring the previous version."
verify_swap_helper "$FINAL_EMBEDDED_HELPER" || fail "The installed update helper changed unexpectedly; restoring the previous version."
/bin/kill -0 "$NEW_PID" 2>/dev/null || fail "The updated app exited during final validation; restoring the previous version."
process_generation_is_still_tracked "$NEW_PID" || fail "The updated app process changed during final validation; restoring the previous version."
FINAL_COMMAND="$(/bin/ps -ww -p "$NEW_PID" -o command= 2>/dev/null || true)"
command_matches_expected_binary "$FINAL_COMMAND" "$EXPECTED_BINARY" || fail "The updated app executable changed during final validation; restoring the previous version."

REPLACEMENT_STARTED=0
UPDATE_LAUNCH_STARTED=0
/bin/rm -rf "$STAGING_PARENT"
STAGING_PARENT=""
STAGED_BUNDLE=""
SWAP_HELPER=""
remove_downloaded_asset_set
"""#
}

enum UpdateInstallError: LocalizedError {
    case invalidBundleLocation
    case invalidSwapHelper
    case invalidUpdatePackage
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBundleLocation:
            return L10n.updateInstallFailed("The current app bundle could not be located.")
        case .invalidSwapHelper:
            return L10n.updateInstallFailed("The bundled update helper is missing or invalid.")
        case .invalidUpdatePackage:
            return L10n.updateInstallFailed("The downloaded update package name is invalid.")
        case .installerLaunchFailed(let message):
            return L10n.updateInstallFailed(message)
        }
    }
}
