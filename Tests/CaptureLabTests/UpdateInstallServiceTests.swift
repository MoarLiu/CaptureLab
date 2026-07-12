import XCTest
@testable import CaptureLab

final class UpdateInstallServiceTests: XCTestCase {
    func testPackageMetadataParsesVersionAndArchitecture() throws {
        XCTAssertEqual(
            try UpdateInstallService.packageMetadata(
                from: URL(fileURLWithPath: "/tmp/CaptureLab-1.2.3-macos-arm64.dmg")
            ),
            .init(version: "1.2.3", architecture: "arm64")
        )
        XCTAssertEqual(
            try UpdateInstallService.packageMetadata(
                from: URL(fileURLWithPath: "/tmp/CaptureLab-2.0.0-beta.1-macos-x86_64.dmg")
            ),
            .init(version: "2.0.0-beta.1", architecture: "x86_64")
        )
    }

    func testPackageMetadataRejectsUntrustedFileNames() {
        for name in [
            "CaptureLab-latest.dmg",
            "Other-1.0.0-macos-arm64.dmg",
            "CaptureLab-1.0.0-macos-universal.dmg",
            "CaptureLab-../1.0.0-macos-arm64.dmg"
        ] {
            XCTAssertThrowsError(try UpdateInstallService.packageMetadata(
                from: URL(fileURLWithPath: "/tmp/\(name)")
            ), "Expected rejection for \(name)")
        }
    }

    func testSwapHelperFailFastValidationRequiresANonSymlinkExecutableFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab Helper Validation \(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("CaptureLabUpdateSwap")
        let nonExecutable = root.appendingPathComponent("not-executable")
        let symlink = root.appendingPathComponent("helper-link")
        let directory = root.appendingPathComponent("helper-directory", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("helper".utf8).write(to: nonExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)

        XCTAssertTrue(UpdateInstallService.isRegularExecutableFile(at: executable))
        XCTAssertFalse(UpdateInstallService.isRegularExecutableFile(at: nonExecutable))
        XCTAssertFalse(UpdateInstallService.isRegularExecutableFile(at: symlink))
        XCTAssertFalse(UpdateInstallService.isRegularExecutableFile(at: directory))
        XCTAssertFalse(UpdateInstallService.isRegularExecutableFile(
            at: root.appendingPathComponent("missing-helper")
        ))
    }

    func testInstallFailsBeforeLaunchingScriptWhenSwapHelperIsInvalid() {
        let service = UpdateInstallService(
            swapHelperURL: URL(fileURLWithPath: "/missing/CaptureLabUpdateSwap")
        )

        XCTAssertThrowsError(try service.installAndRelaunch(
            dmgURL: URL(fileURLWithPath: "/tmp/CaptureLab-0.4.1-macos-arm64.dmg"),
            targetBundleURL: URL(fileURLWithPath: "/Applications/CaptureLab.app")
        )) { error in
            guard case UpdateInstallError.invalidSwapHelper = error else {
                return XCTFail("Expected invalidSwapHelper, got \(error)")
            }
        }
    }

    func testInstallerScriptValidatesCandidateBeforeAtomicSwap() throws {
        let script = UpdateInstallService.installScript

        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("CFBundleIdentifier"))
        XCTAssertTrue(script.contains("CFBundleShortVersionString"))
        XCTAssertTrue(script.contains("lipo -archs"))
        XCTAssertTrue(script.contains(#"CURRENT_SWAP_HELPER="$7""#))
        XCTAssertTrue(script.contains(#"SWAP_HELPER="$STAGING_PARENT/$APP_NAME-update-swap""#))
        XCTAssertTrue(script.contains(#"/usr/bin/ditto "$CURRENT_SWAP_HELPER" "$SWAP_HELPER""#))
        XCTAssertTrue(script.contains(#"verify_swap_helper "$STAGED_EMBEDDED_HELPER""#))
        XCTAssertFalse(script.contains("BACKUP_BUNDLE"))
        XCTAssertFalse(script.contains("BACKUP_PARENT"))
        XCTAssertFalse(script.contains(#"/bin/mv "$TARGET_BUNDLE""#))
        XCTAssertFalse(script.contains(#"/bin/mv "$STAGED_BUNDLE""#))
        XCTAssertFalse(script.contains(#"rm -rf "$TARGET_BUNDLE""#))
        XCTAssertFalse(script.contains(#"mv "$STAGED_BUNDLE" "$TARGET_BUNDLE""#))
        XCTAssertTrue(script.contains("PREEXISTING_PIDS=\"$(capturelab_pid_snapshot)\""))
        XCTAssertTrue(script.contains("select_new_expected_pid_from_records"))
        XCTAssertTrue(script.contains("track_new_expected_pids_from_records"))
        XCTAssertTrue(script.contains("terminate_launched_update_processes"))
        XCTAssertTrue(script.contains("signal_tracked_update_pids TERM"))
        XCTAssertTrue(script.contains("signal_tracked_update_pids KILL"))
        XCTAssertTrue(script.contains("ps -p \"$pid\" -o lstart="))
        XCTAssertTrue(script.contains("process_generation_is_still_tracked \"$pid\""))
        XCTAssertGreaterThanOrEqual(
            script.components(separatedBy: "process_generation_is_still_tracked \"$NEW_PID\"").count - 1,
            2
        )
        let terminateFunctionRange = try XCTUnwrap(script.range(of: "terminate_tracked_update_pids() {"))
        let termRange = try XCTUnwrap(script.range(
            of: "signal_tracked_update_pids TERM",
            range: terminateFunctionRange.upperBound..<script.endIndex
        ))
        let boundedWaitRange = try XCTUnwrap(script.range(
            of: "wait_for_tracked_update_pids_to_exit 20",
            range: termRange.upperBound..<script.endIndex
        ))
        let killRange = try XCTUnwrap(script.range(
            of: "signal_tracked_update_pids KILL",
            range: boundedWaitRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(termRange.lowerBound, boundedWaitRange.lowerBound)
        XCTAssertLessThan(boundedWaitRange.lowerBound, killRange.lowerBound)
        XCTAssertTrue(script.contains("kill -0 \"$NEW_PID\""))
        XCTAssertTrue(script.contains("ps -ww -p \"$NEW_PID\" -o command="))
        XCTAssertTrue(script.contains("$TARGET_BUNDLE/Contents/MacOS/$APP_NAME"))
        XCTAssertFalse(script.contains("pgrep -nx"))
        XCTAssertFalse(script.contains("open \"$DMG_PATH\""))
        XCTAssertGreaterThanOrEqual(
            script.components(separatedBy: "TARGET_DECISION=\"$(evaluate_target_update_decision)\"").count - 1,
            2
        )
        XCTAssertTrue(script.contains("validated_target_version()"))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict --verbose=2 \"$TARGET_BUNDLE\""))
        XCTAssertTrue(script.contains("capturelab_update_decision \"$current_version\" \"$EXPECTED_VERSION\""))
        XCTAssertTrue(script.contains("Another CaptureLab instance is still running from the target bundle"))
        XCTAssertTrue(script.contains("A CaptureLab instance started while the update was being staged"))

        let stagedRange = try XCTUnwrap(script.range(of: #"STAGED_BUNDLE="$STAGING_PARENT/$APP_NAME.app""#))
        let stagedBundleIDRange = try XCTUnwrap(script.range(
            of: "STAGED_BUNDLE_ID=",
            range: stagedRange.upperBound..<script.endIndex
        ))
        let stagedVersionRange = try XCTUnwrap(script.range(
            of: "STAGED_VERSION=",
            range: stagedBundleIDRange.upperBound..<script.endIndex
        ))
        let stagedSignatureRange = try XCTUnwrap(script.range(
            of: #"codesign --verify --deep --strict --verbose=2 "$STAGED_BUNDLE""#,
            range: stagedVersionRange.upperBound..<script.endIndex
        ))
        let stagedArchitectureRange = try XCTUnwrap(script.range(
            of: #"binary_contains_expected_architecture "$STAGED_BINARY""#,
            range: stagedSignatureRange.upperBound..<script.endIndex
        ))
        let stagedHelperRange = try XCTUnwrap(script.range(
            of: #"verify_swap_helper "$STAGED_EMBEDDED_HELPER""#,
            range: stagedArchitectureRange.upperBound..<script.endIndex
        ))
        let installSwapRange = try XCTUnwrap(script.range(
            of: #""$SWAP_HELPER" "$TARGET_BUNDLE" "$STAGED_BUNDLE""#,
            range: stagedHelperRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(stagedBundleIDRange.lowerBound, stagedVersionRange.lowerBound)
        XCTAssertLessThan(stagedVersionRange.lowerBound, stagedSignatureRange.lowerBound)
        XCTAssertLessThan(stagedSignatureRange.lowerBound, stagedArchitectureRange.lowerBound)
        XCTAssertLessThan(stagedArchitectureRange.lowerBound, stagedHelperRange.lowerBound)
        XCTAssertLessThan(stagedHelperRange.lowerBound, installSwapRange.lowerBound)

        let snapshotRange = try XCTUnwrap(script.range(of: "PREEXISTING_PIDS=\"$(capturelab_pid_snapshot)\""))
        let openRange = try XCTUnwrap(script.range(of: "/usr/bin/open -n \"$TARGET_BUNDLE\"", range: snapshotRange.upperBound..<script.endIndex))
        XCTAssertLessThan(snapshotRange.lowerBound, openRange.lowerBound)

        let failRange = try XCTUnwrap(script.range(of: "fail() {"))
        let terminateRange = try XCTUnwrap(script.range(
            of: "terminate_launched_update_processes",
            range: failRange.upperBound..<script.endIndex
        ))
        let restoreRange = try XCTUnwrap(script.range(
            of: "if rollback_replacement; then",
            range: terminateRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(terminateRange.lowerBound, restoreRange.lowerBound)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("installer.zsh")
        try Data(script.utf8).write(to: scriptURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", scriptURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testInstallerLauncherUsesFixedTargetLockWithTimeoutAndFailureMapping() throws {
        let targetBundle = URL(fileURLWithPath: "/Applications/CaptureLab.app", isDirectory: true)
        XCTAssertEqual(
            UpdateInstallService.installLockURL(for: targetBundle).path,
            "/Applications/.CaptureLab.update.lock"
        )
        XCTAssertEqual(UpdateInstallService.installLockTimeoutSeconds, 180)

        let launcher = UpdateInstallService.installLauncherScript
        XCTAssertTrue(launcher.contains(#"/usr/bin/lockf -k -s -w -t "$LOCK_TIMEOUT_SECONDS" "$LOCK_PATH""#))
        XCTAssertTrue(launcher.contains("Another CaptureLab update is already being installed"))
        XCTAssertTrue(launcher.contains("could not create the update lock beside the app"))
        XCTAssertTrue(launcher.contains("could not start the serialized update installer safely"))
        XCTAssertTrue(launcher.contains(#"/bin/rm -f "$INSTALL_SCRIPT""#))
        XCTAssertTrue(launcher.contains("relaunch_after_launcher_failure"))
        XCTAssertTrue(launcher.contains("capturelab_safe_relaunch_target"))
        XCTAssertTrue(launcher.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(launcher.contains("capturelab_target_process_is_running"))
        XCTAssertTrue(launcher.contains(#"/usr/bin/open "$target_bundle""#))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", "-c", launcher]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testLockAndPreSwapFailuresRelaunchOnlyAValidatedNonrunningTarget() throws {
        let launcher = UpdateInstallService.installLauncherScript
        let script = UpdateInstallService.installScript
        let relaunchFunctions = UpdateInstallService.safeRelaunchShellFunctions

        let bundleIDRange = try XCTUnwrap(relaunchFunctions.range(of: "CFBundleIdentifier"))
        let versionRange = try XCTUnwrap(relaunchFunctions.range(
            of: "CFBundleShortVersionString",
            range: bundleIDRange.upperBound..<relaunchFunctions.endIndex
        ))
        let signatureRange = try XCTUnwrap(relaunchFunctions.range(
            of: "codesign --verify --deep --strict",
            range: versionRange.upperBound..<relaunchFunctions.endIndex
        ))
        let architectureRange = try XCTUnwrap(relaunchFunctions.range(
            of: "lipo -archs",
            range: signatureRange.upperBound..<relaunchFunctions.endIndex
        ))
        let runningProcessRange = try XCTUnwrap(relaunchFunctions.range(
            of: "capturelab_target_process_is_running",
            range: architectureRange.upperBound..<relaunchFunctions.endIndex
        ))
        let openRange = try XCTUnwrap(relaunchFunctions.range(
            of: #"/usr/bin/open "$target_bundle""#,
            range: runningProcessRange.upperBound..<relaunchFunctions.endIndex
        ))
        XCTAssertLessThan(bundleIDRange.lowerBound, versionRange.lowerBound)
        XCTAssertLessThan(versionRange.lowerBound, signatureRange.lowerBound)
        XCTAssertLessThan(signatureRange.lowerBound, architectureRange.lowerBound)
        XCTAssertLessThan(architectureRange.lowerBound, runningProcessRange.lowerBound)
        XCTAssertLessThan(runningProcessRange.lowerBound, openRange.lowerBound)
        XCTAssertFalse(relaunchFunctions.contains("/usr/bin/open -n"))

        let invalidTimeoutRange = try XCTUnwrap(launcher.range(of: #"if [[ "$LOCK_TIMEOUT_SECONDS""#))
        let invalidTimeoutRelaunchRange = try XCTUnwrap(launcher.range(
            of: #"relaunch_after_launcher_failure "$@""#,
            range: invalidTimeoutRange.upperBound..<launcher.endIndex
        ))
        let lockFailureCaseRange = try XCTUnwrap(launcher.range(of: #"case "$LOCK_STATUS" in"#))
        let lockFailureRelaunchRange = try XCTUnwrap(launcher.range(
            of: #"relaunch_after_launcher_failure "$@""#,
            range: lockFailureCaseRange.upperBound..<launcher.endIndex
        ))
        let installerFailureCaseRange = try XCTUnwrap(launcher.range(
            of: "1)\n    relaunch_after_launcher_failure",
            range: lockFailureCaseRange.upperBound..<launcher.endIndex
        ))
        XCTAssertLessThan(invalidTimeoutRange.lowerBound, invalidTimeoutRelaunchRange.lowerBound)
        XCTAssertLessThan(lockFailureCaseRange.lowerBound, lockFailureRelaunchRange.lowerBound)
        XCTAssertLessThan(lockFailureCaseRange.lowerBound, installerFailureCaseRange.lowerBound)

        let trapRange = try XCTUnwrap(script.range(of: "trap cleanup EXIT"))
        let mountDirectoryRange = try XCTUnwrap(script.range(
            of: #"MOUNT_DIR="$(/usr/bin/mktemp -d"#,
            range: trapRange.upperBound..<script.endIndex
        ))
        let mountFailureRange = try XCTUnwrap(script.range(
            of: #"|| fail "Could not create a temporary update mount directory.""#,
            range: mountDirectoryRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(trapRange.lowerBound, mountDirectoryRange.lowerBound)
        XCTAssertLessThan(mountDirectoryRange.lowerBound, mountFailureRange.lowerBound)

        let failRange = try XCTUnwrap(script.range(of: "fail() {"))
        let preSwapRelaunchRange = try XCTUnwrap(script.range(
            of: "capturelab_safe_relaunch_target",
            range: failRange.upperBound..<script.endIndex
        ))
        let swapRange = try XCTUnwrap(script.range(
            of: #""$SWAP_HELPER" "$TARGET_BUNDLE" "$STAGED_BUNDLE""#,
            range: preSwapRelaunchRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(preSwapRelaunchRange.lowerBound, swapRange.lowerBound)
    }

    func testInstallerLauncherSerializesConcurrentWorkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab Installer Lock Tests \(UUID().uuidString)", isDirectory: true)
        let lockURL = root.appendingPathComponent(".CaptureLab.update.lock")
        let activeURL = root.appendingPathComponent("active", isDirectory: true)
        let eventsURL = root.appendingPathComponent("events.txt")
        let firstWorkerURL = root.appendingPathComponent("first-worker.zsh")
        let secondWorkerURL = root.appendingPathComponent("second-worker.zsh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let worker = #"""
#!/bin/zsh
set -euo pipefail
ACTIVE_PATH="$1"
EVENTS_PATH="$2"
NAME="$3"
if ! /bin/mkdir "$ACTIVE_PATH"; then
  echo "$NAME-overlap" >> "$EVENTS_PATH"
  exit 99
fi
echo "$NAME-start" >> "$EVENTS_PATH"
/bin/sleep 0.5
/bin/rmdir "$ACTIVE_PATH"
echo "$NAME-end" >> "$EVENTS_PATH"
"""#
        try Data(worker.utf8).write(to: firstWorkerURL)
        try Data(worker.utf8).write(to: secondWorkerURL)

        let first = makeInstallLauncherProcess(
            lockURL: lockURL,
            workerURL: firstWorkerURL,
            activeURL: activeURL,
            eventsURL: eventsURL,
            name: "first"
        )
        try first.run()

        let startDeadline = Date().addingTimeInterval(3)
        while Date() < startDeadline {
            let events = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? ""
            if events.contains("first-start") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(first.isRunning, "The first worker should still hold the installer lock.")
        XCTAssertTrue(
            ((try? String(contentsOf: eventsURL, encoding: .utf8)) ?? "").contains("first-start")
        )

        let second = makeInstallLauncherProcess(
            lockURL: lockURL,
            workerURL: secondWorkerURL,
            activeURL: activeURL,
            eventsURL: eventsURL,
            name: "second"
        )
        try second.run()
        first.waitUntilExit()
        second.waitUntilExit()

        XCTAssertEqual(first.terminationStatus, 0)
        XCTAssertEqual(second.terminationStatus, 0)
        let events = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
    }

    func testQueuedSameOrHigherVersionInstallerBecomesANoop() throws {
        XCTAssertEqual(
            try runUpdateDecisionHelper(
                currentVersion: "0.4.2",
                expectedVersion: "0.4.2",
                runningTargetPIDs: "101"
            ),
            .init(status: 0, output: "noop")
        )
        XCTAssertEqual(
            try runUpdateDecisionHelper(
                currentVersion: "0.4.3",
                expectedVersion: "0.4.2",
                runningTargetPIDs: ""
            ),
            .init(status: 0, output: "noop")
        )
    }

    func testQueuedNewerInstallerContinuesOnlyWithoutRunningTargetProcess() throws {
        XCTAssertEqual(
            try runUpdateDecisionHelper(
                currentVersion: "0.4.2",
                expectedVersion: "0.4.3",
                runningTargetPIDs: "202"
            ),
            .init(status: 0, output: "blocked")
        )
        XCTAssertEqual(
            try runUpdateDecisionHelper(
                currentVersion: "0.4.2",
                expectedVersion: "0.4.3",
                runningTargetPIDs: ""
            ),
            .init(status: 0, output: "install")
        )
    }

    func testVersionDecisionSupportsPrereleasesAndUnboundedNumericComponents() throws {
        XCTAssertEqual(
            try runUpdateDecisionHelper(
                currentVersion: "1.0.0-beta.2",
                expectedVersion: "1.0.0-beta.11",
                runningTargetPIDs: ""
            ),
            .init(status: 0, output: "install")
        )
        XCTAssertEqual(
            try runUpdateDecisionHelper(
                currentVersion: "999999999999999999999999999999.0",
                expectedVersion: "2.0",
                runningTargetPIDs: ""
            ),
            .init(status: 0, output: "noop")
        )
    }

    func testInstallerRollbackAndCleanupUseTheSameAtomicSwapHelper() throws {
        let script = UpdateInstallService.installScript
        let swapInvocation = #""$SWAP_HELPER" "$TARGET_BUNDLE" "$STAGED_BUNDLE""#
        XCTAssertEqual(script.components(separatedBy: swapInvocation).count - 1, 2)

        let rollbackRange = try XCTUnwrap(script.range(of: "rollback_replacement() {"))
        let rollbackSwapRange = try XCTUnwrap(script.range(
            of: swapInvocation,
            range: rollbackRange.upperBound..<script.endIndex
        ))
        let rollbackCommitRange = try XCTUnwrap(script.range(
            of: "REPLACEMENT_STARTED=0",
            range: rollbackSwapRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(rollbackSwapRange.lowerBound, rollbackCommitRange.lowerBound)

        let cleanupRange = try XCTUnwrap(script.range(of: "cleanup() {"))
        let activeRange = try XCTUnwrap(script.range(
            of: #"if [[ "$REPLACEMENT_STARTED" == "1" ]]"#,
            range: cleanupRange.upperBound..<script.endIndex
        ))
        let terminateRange = try XCTUnwrap(script.range(
            of: "terminate_launched_update_processes",
            range: activeRange.upperBound..<script.endIndex
        ))
        let rollbackCleanupRange = try XCTUnwrap(script.range(
            of: "if rollback_replacement; then",
            range: terminateRange.upperBound..<script.endIndex
        ))
        let guardedRemovalRange = try XCTUnwrap(script.range(
            of: #"if [[ "$REPLACEMENT_STARTED" == "0" && -n "$STAGING_PARENT" ]]"#,
            range: rollbackCleanupRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(activeRange.lowerBound, terminateRange.lowerBound)
        XCTAssertLessThan(terminateRange.lowerBound, rollbackCleanupRange.lowerBound)
        XCTAssertLessThan(rollbackCleanupRange.lowerBound, guardedRemovalRange.lowerBound)

        let stableCheckRange = try XCTUnwrap(script.range(
            of: #"command_matches_expected_binary "$STABLE_COMMAND" "$EXPECTED_BINARY""#
        ))
        let finalVersionRange = try XCTUnwrap(script.range(
            of: "FINAL_VERSION=",
            range: stableCheckRange.upperBound..<script.endIndex
        ))
        let finalSignatureRange = try XCTUnwrap(script.range(
            of: #"codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE""#,
            range: finalVersionRange.upperBound..<script.endIndex
        ))
        let finalArchitectureRange = try XCTUnwrap(script.range(
            of: #"binary_contains_expected_architecture "$FINAL_BINARY""#,
            range: finalSignatureRange.upperBound..<script.endIndex
        ))
        let finalHelperRange = try XCTUnwrap(script.range(
            of: #"verify_swap_helper "$FINAL_EMBEDDED_HELPER""#,
            range: finalArchitectureRange.upperBound..<script.endIndex
        ))
        let replacementCommitRange = try XCTUnwrap(script.range(
            of: "REPLACEMENT_STARTED=0",
            range: finalHelperRange.upperBound..<script.endIndex
        ))
        let launchCommitRange = try XCTUnwrap(script.range(
            of: "UPDATE_LAUNCH_STARTED=0",
            range: replacementCommitRange.upperBound..<script.endIndex
        ))
        let oldBundleRemovalRange = try XCTUnwrap(script.range(
            of: #"/bin/rm -rf "$STAGING_PARENT""#,
            range: launchCommitRange.upperBound..<script.endIndex
        ))
        XCTAssertLessThan(stableCheckRange.lowerBound, finalVersionRange.lowerBound)
        XCTAssertLessThan(finalVersionRange.lowerBound, finalSignatureRange.lowerBound)
        XCTAssertLessThan(finalSignatureRange.lowerBound, finalArchitectureRange.lowerBound)
        XCTAssertLessThan(finalArchitectureRange.lowerBound, finalHelperRange.lowerBound)
        XCTAssertLessThan(finalHelperRange.lowerBound, replacementCommitRange.lowerBound)
        XCTAssertLessThan(replacementCommitRange.lowerBound, launchCommitRange.lowerBound)
        XCTAssertLessThan(launchCommitRange.lowerBound, oldBundleRemovalRange.lowerBound)
    }

    func testSuccessfulInstallRemovesTheDownloadedAssetSetAndEmptyDirectory() throws {
        let script = UpdateInstallService.installScript
        let removalFunctionRange = try XCTUnwrap(script.range(of: "remove_downloaded_asset_set() {"))
        let assetRemovalRange = try XCTUnwrap(script.range(
            of: #"/bin/rm -f "$DMG_PATH" "$DMG_PATH.sha256" "$DMG_PATH.sig""#,
            range: removalFunctionRange.upperBound..<script.endIndex
        ))
        let directoryRemovalInFunctionRange = try XCTUnwrap(script.range(
            of: #"/bin/rmdir "$update_directory" 2>/dev/null || true"#,
            range: assetRemovalRange.upperBound..<script.endIndex
        ))
        let stableCheckRange = try XCTUnwrap(script.range(
            of: #"command_matches_expected_binary "$STABLE_COMMAND" "$EXPECTED_BINARY""#
        ))
        let removalRange = try XCTUnwrap(script.range(
            of: "remove_downloaded_asset_set",
            range: stableCheckRange.upperBound..<script.endIndex
        ))

        XCTAssertLessThan(assetRemovalRange.lowerBound, directoryRemovalInFunctionRange.lowerBound)
        XCTAssertLessThan(stableCheckRange.lowerBound, removalRange.lowerBound)
        XCTAssertFalse(script.contains(#"/bin/rm -rf "$UPDATE_DIRECTORY""#))
    }

    func testUpdateSwapHelperExchangesDirectoriesAndCanSwapThemBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab Atomic Swap Tests \(UUID().uuidString)", isDirectory: true)
        let targetBundle = root.appendingPathComponent("CaptureLab.app", isDirectory: true)
        let stagedBundle = root.appendingPathComponent("Staged CaptureLab.app", isDirectory: true)
        let targetMarker = targetBundle.appendingPathComponent("version.txt")
        let stagedMarker = stagedBundle.appendingPathComponent("version.txt")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: targetBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedBundle, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: targetMarker)
        try Data("new".utf8).write(to: stagedMarker)

        let helperURL = try updateSwapHelperURL()
        let install = try runSwapHelper(helperURL, targetBundle, stagedBundle)
        XCTAssertEqual(install.status, 0, install.output)
        XCTAssertEqual(try String(contentsOf: targetMarker, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: stagedMarker, encoding: .utf8), "old")

        let rollback = try runSwapHelper(helperURL, targetBundle, stagedBundle)
        XCTAssertEqual(rollback.status, 0, rollback.output)
        XCTAssertEqual(try String(contentsOf: targetMarker, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: stagedMarker, encoding: .utf8), "new")
    }

    func testProcessHealthHelperSelectsOnlyNewProcessAtExpectedBinary() throws {
        let result = try runProcessHealthHelper(
            preexistingPIDs: "101\n202",
            expectedBinary: "/Applications/CaptureLab.app/Contents/MacOS/CaptureLab",
            records: """
            101\tstart-101\t/Applications/CaptureLab.app/Contents/MacOS/CaptureLab
            303\tstart-303\t/Applications/Other.app/Contents/MacOS/CaptureLab
            404\tstart-404\t/Applications/CaptureLab.app/Contents/MacOS/CaptureLab --launched-by-open
            """
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "404")
    }

    func testProcessHealthHelperRejectsOldOrWrongPathProcesses() throws {
        let result = try runProcessHealthHelper(
            preexistingPIDs: "101\n202",
            expectedBinary: "/Applications/CaptureLab.app/Contents/MacOS/CaptureLab",
            records: """
            101\tstart-101\t/Applications/CaptureLab.app/Contents/MacOS/CaptureLab
            303\tstart-303\t/Applications/CaptureLab-Beta.app/Contents/MacOS/CaptureLab
            """
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testProcessHealthHelperMatchesFullExpectedPathContainingSpaces() throws {
        let result = try runProcessHealthHelper(
            preexistingPIDs: "101",
            expectedBinary: "/Applications/Capture Lab/CaptureLab.app/Contents/MacOS/CaptureLab",
            records: """
            202\tstart-202\t/Applications/Capture Lab/CaptureLab.app/Contents/MacOS/CaptureLab --updated
            """
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "202")
    }

    func testRollbackTerminationKillsOnlyNewExpectedPathProcesses() throws {
        let preexisting = try startSleeper()
        let selected = try startSleeper()
        let unselectedSibling = try startSleeper()
        let commandChanged = try startSleeper()
        let otherPath = try startSleeper()
        let reusedPID = try startSleeper()
        let processes = [preexisting, selected, unselectedSibling, commandChanged, otherPath, reusedPID]
        defer {
            for process in processes where process.isRunning {
                process.terminate()
            }
            for process in processes {
                process.waitUntilExit()
            }
        }

        let expectedBinary = "/Applications/Capture Lab/CaptureLab.app/Contents/MacOS/CaptureLab"
        let records = """
        \(preexisting.processIdentifier)\t\(expectedBinary)
        \(selected.processIdentifier)\t\(expectedBinary) --selected
        \(unselectedSibling.processIdentifier)\t\(expectedBinary) --sibling
        \(commandChanged.processIdentifier)\t\(expectedBinary) --command-changed-after-tracking
        \(otherPath.processIdentifier)\t/Applications/Other CaptureLab.app/Contents/MacOS/CaptureLab
        """
        let result = try runRollbackTerminationHelper(
            preexistingPIDs: "\(preexisting.processIdentifier)",
            expectedBinary: expectedBinary,
            records: records,
            reusedPIDsWithStaleGeneration: "\(reusedPID.processIdentifier)"
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            Set(result.output.split(separator: "\n").map(String.init)),
            Set([
                "\(selected.processIdentifier)",
                "\(unselectedSibling.processIdentifier)",
                "\(commandChanged.processIdentifier)",
                "\(reusedPID.processIdentifier)"
            ])
        )
        selected.waitUntilExit()
        unselectedSibling.waitUntilExit()
        commandChanged.waitUntilExit()
        XCTAssertFalse(selected.isRunning)
        XCTAssertFalse(unselectedSibling.isRunning)
        XCTAssertFalse(commandChanged.isRunning)
        XCTAssertTrue(preexisting.isRunning)
        XCTAssertTrue(otherPath.isRunning)
        XCTAssertTrue(reusedPID.isRunning)
    }

    private func runUpdateDecisionHelper(
        currentVersion: String,
        expectedVersion: String,
        runningTargetPIDs: String
    ) throws -> UpdateDecisionResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab Update Decision Tests \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let helperURL = root.appendingPathComponent("update-decision-helper.zsh")
        let harness = """
        #!/bin/zsh
        set -u
        \(UpdateInstallService.updateDecisionShellFunctions)
        capturelab_update_decision "$1" "$2" "$3"
        """
        try Data(harness.utf8).write(to: helperURL)

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path, currentVersion, expectedVersion, runningTargetPIDs]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateDecisionResult(status: process.terminationStatus, output: output)
    }

    private func runProcessHealthHelper(
        preexistingPIDs: String,
        expectedBinary: String,
        records: String
    ) throws -> (status: Int32, output: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallServiceHelperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let helperURL = root.appendingPathComponent("process-health-helper.zsh")
        let harness = """
        #!/bin/zsh
        set -u
        \(UpdateInstallService.processHealthShellFunctions)
        PREEXISTING_PIDS="$1"
        EXPECTED_BINARY="$2"
        RECORDS="$3"
        select_new_expected_pid_from_records "$PREEXISTING_PIDS" "$EXPECTED_BINARY" "$RECORDS"
        """
        try Data(harness.utf8).write(to: helperURL)

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path, preexistingPIDs, expectedBinary, records]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    private func runRollbackTerminationHelper(
        preexistingPIDs: String,
        expectedBinary: String,
        records: String,
        reusedPIDsWithStaleGeneration: String
    ) throws -> (status: Int32, output: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallServiceTerminationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let helperURL = root.appendingPathComponent("rollback-process-helper.zsh")
        let harness = """
        #!/bin/zsh
        set -u
        \(UpdateInstallService.processHealthShellFunctions)
        PREEXISTING_PIDS="$1"
        EXPECTED_BINARY="$2"
        TRACKED_UPDATE_PIDS=""
        TRACKED_UPDATE_START_RECORDS=""
        INPUT_RECORDS="$3"
        REUSED_PIDS="$4"
        NORMALIZED_RECORDS=""
        while IFS=$'\t' read -r pid command; do
          [[ -n "$pid" && -n "$command" ]] || continue
          start_token="$(process_start_token "$pid")"
          [[ -n "$NORMALIZED_RECORDS" ]] && NORMALIZED_RECORDS+=$'\n'
          NORMALIZED_RECORDS+="$pid"$'\t'"$start_token"$'\t'"$command"
        done <<< "$INPUT_RECORDS"
        track_new_expected_pids_from_records "$NORMALIZED_RECORDS"
        while IFS= read -r pid; do
          [[ -n "$pid" ]] || continue
          remember_update_pid "$pid" "stale-generation-token"
        done <<< "$REUSED_PIDS"
        terminate_tracked_update_pids
        /usr/bin/printf '%s\\n' "$TRACKED_UPDATE_PIDS"
        """
        try Data(harness.utf8).write(to: helperURL)

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path, preexistingPIDs, expectedBinary, records, reusedPIDsWithStaleGeneration]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    private func startSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func makeInstallLauncherProcess(
        lockURL: URL,
        workerURL: URL,
        activeURL: URL,
        eventsURL: URL,
        name: String
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            UpdateInstallService.installLauncherScript,
            "capturelab-update-launcher-test",
            lockURL.path,
            "5",
            workerURL.path,
            activeURL.path,
            eventsURL.path,
            name
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func updateSwapHelperURL() throws -> URL {
        let testBundleSibling = Bundle(for: UpdateInstallServiceTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("CaptureLabUpdateSwap", isDirectory: false)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let debugProduct = repositoryRoot
            .appendingPathComponent(".build/debug/CaptureLabUpdateSwap", isDirectory: false)

        return try XCTUnwrap(
            [testBundleSibling, debugProduct].first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            },
            "SwiftPM did not make the CaptureLabUpdateSwap executable available to the test bundle."
        )
    }

    private func runSwapHelper(
        _ helperURL: URL,
        _ firstDirectory: URL,
        _ secondDirectory: URL
    ) throws -> (status: Int32, output: String) {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [firstDirectory.path, secondDirectory.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}

private struct UpdateDecisionResult: Equatable {
    var status: Int32
    var output: String
}
