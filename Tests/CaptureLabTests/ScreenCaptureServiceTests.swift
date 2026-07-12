import Darwin
import XCTest
@testable import CaptureLab

final class ScreenCaptureServiceTests: XCTestCase {
    func testRegionCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(service.arguments(for: .region, outputURL: url), ["-i", "-x", "/tmp/capture.png"])
    }

    func testFullScreenCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(service.arguments(for: .fullScreen, outputURL: url), ["-x", "/tmp/capture.png"])
    }

    func testWindowCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(service.arguments(for: .window, outputURL: url), ["-i", "-w", "-x", "/tmp/capture.png"])
    }

    func testDelayedRegionCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(
            service.arguments(for: .delayedRegion(seconds: 5), outputURL: url),
            ["-T", "5", "-i", "-x", "/tmp/capture.png"]
        )
    }

    func testInteractiveNonzeroExitWithoutStderrIsCancellation() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let service = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, _ in .init(terminationStatus: 1, standardError: "") }
        )

        XCTAssertThrowsError(try service.captureFile(mode: .region)) { error in
            guard case CaptureLabError.captureCancelled = error else {
                return XCTFail("Expected captureCancelled, got \(error)")
            }
        }
    }

    func testFullScreenNonzeroExitWithoutStderrIsFailure() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let service = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, _ in .init(terminationStatus: 9, standardError: "") }
        )

        XCTAssertThrowsError(try service.captureFile(mode: .fullScreen)) { error in
            guard case CaptureLabError.captureFailed(let message) = error else {
                return XCTFail("Expected captureFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("status 9"))
        }
    }

    func testInteractiveSignalLikeExitWithoutStderrIsFailure() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let service = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, _ in .init(terminationStatus: 9, standardError: "") }
        )

        XCTAssertThrowsError(try service.captureFile(mode: .region)) { error in
            guard case CaptureLabError.captureFailed(let message) = error else {
                return XCTFail("Expected captureFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("status 9"))
        }
    }

    func testStderrIsSurfacedAndPartialCaptureIsRemoved() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let service = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                try Data("partial".utf8).write(to: URL(fileURLWithPath: arguments.last!))
                return .init(terminationStatus: 2, standardError: "screen recording permission denied\n")
            }
        )

        XCTAssertThrowsError(try service.captureFile(mode: .fullScreen)) { error in
            guard case CaptureLabError.captureFailed(let message) = error else {
                return XCTFail("Expected captureFailed, got \(error)")
            }
            XCTAssertEqual(message, "screen recording permission denied")
        }
        let remainingPNGs = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        XCTAssertTrue(remainingPNGs.isEmpty)
    }

    func testSeparateServiceInstancesDoNotDeleteEachOthersCaptures() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let firstService = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                try Data("first".utf8).write(to: URL(fileURLWithPath: arguments.last!))
                return .init(terminationStatus: 0, standardError: "")
            }
        )
        let secondService = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                try Data("second".utf8).write(to: URL(fileURLWithPath: arguments.last!))
                return .init(terminationStatus: 0, standardError: "")
            }
        )

        let firstURL = try firstService.captureFile(mode: .fullScreen)
        let secondURL = try secondService.captureFile(mode: .fullScreen)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("second".utf8))
    }

    func testOverlappingServiceInstancesKeepBothInFlightCaptures() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        var nestedCaptureURL: URL?
        let nestedService = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                let url = URL(fileURLWithPath: arguments.last!)
                try Data("nested".utf8).write(to: url)
                return .init(terminationStatus: 0, standardError: "")
            }
        )
        let outerService = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                let outerURL = URL(fileURLWithPath: arguments.last!)
                try Data("outer".utf8).write(to: outerURL)
                nestedCaptureURL = try nestedService.captureFile(mode: .window)
                XCTAssertTrue(FileManager.default.fileExists(atPath: outerURL.path))
                return .init(terminationStatus: 0, standardError: "")
            }
        )

        let outerURL = try outerService.captureFile(mode: .fullScreen)
        let innerURL = try XCTUnwrap(nestedCaptureURL)

        XCTAssertEqual(try Data(contentsOf: outerURL), Data("outer".utf8))
        XCTAssertEqual(try Data(contentsOf: innerURL), Data("nested".utf8))
    }

    func testFailedCaptureRemovesOnlyItsOwnPartialFile() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let existingService = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                try Data("existing".utf8).write(to: URL(fileURLWithPath: arguments.last!))
                return .init(terminationStatus: 0, standardError: "")
            }
        )
        let existingURL = try existingService.captureFile(mode: .fullScreen)
        let failingService = ScreenCaptureService(
            temporaryDirectory: fixture.directory,
            processRunner: { _, arguments in
                try Data("partial".utf8).write(to: URL(fileURLWithPath: arguments.last!))
                return .init(terminationStatus: 2, standardError: "failed")
            }
        )

        XCTAssertThrowsError(try failingService.captureFile(mode: .fullScreen))

        XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
        let remainingCaptureFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "png" }
        XCTAssertEqual(
            remainingCaptureFiles.map { $0.resolvingSymlinksInPath() },
            [existingURL.resolvingSymlinksInPath()]
        )
    }

    func testWorkspaceReclaimsOnlyDirectoriesWithoutLiveCrossProcessLock() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let root = fixture.directory.appendingPathComponent("CaptureWorkspaces", isDirectory: true)
        let stale = root.appendingPathComponent("workspace-stale", isDirectory: true)
        let live = root.appendingPathComponent("workspace-live", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data().write(to: stale.appendingPathComponent(ScreenCaptureWorkspace.liveLockFileName))
        let liveLock = live.appendingPathComponent(ScreenCaptureWorkspace.liveLockFileName)
        try Data().write(to: liveLock)

        let ready = fixture.directory.appendingPathComponent("live-lock-ready")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_RDWR)
            fcntl.lockf(descriptor, fcntl.LOCK_EX)
            open(sys.argv[2], "w").close()
            time.sleep(30)
            """,
            liveLock.path,
            ready.path
        ]
        try holder.run()
        defer { stopProcess(holder) }
        XCTAssertTrue(waitForFile(ready), "Timed out waiting for the cross-process workspace lock")

        let workspace = ScreenCaptureWorkspace(
            rootDirectory: root,
            workspaceName: "workspace-current"
        )
        let current = try workspace.prepare()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))

        workspace.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))

        stopProcess(holder)
        let nextWorkspace = ScreenCaptureWorkspace(
            rootDirectory: root,
            workspaceName: "workspace-next"
        )
        _ = try nextWorkspace.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        nextWorkspace.cleanup()
    }

    func testLifecycleShutdownTerminatesRegisteredProcessAndRemovesOwnWorkspace() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let recorder = CaptureSignalRecorder()
        let registry = ScreenCaptureProcessRegistry { pid, signal in
            recorder.record(signal)
            return Darwin.kill(pid, signal)
        }
        let workspace = ScreenCaptureWorkspace(
            rootDirectory: fixture.directory.appendingPathComponent("CaptureWorkspaces"),
            workspaceName: "workspace-current"
        )
        let lifecycle = ScreenCaptureLifecycle(
            workspace: workspace,
            processRegistry: registry,
            terminationGracePeriod: 0.05,
            terminationKillWait: 0.5
        )
        try lifecycle.prepareForLaunch()
        let partialCapture = try lifecycle.captureDirectory().appendingPathComponent("partial.png")
        try Data("partial".utf8).write(to: partialCapture)

        let childStarted = fixture.directory.appendingPathComponent("child-started")
        let resultBox = CaptureProcessResultBox()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try ScreenCaptureService.runProcess(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "trap '' TERM; touch \"$1\"; while :; do :; done",
                        "capture-child",
                        childStarted.path
                    ],
                    registry: registry
                )
            }
            resultBox.store(result)
            completion.signal()
        }
        XCTAssertTrue(waitForFile(childStarted), "Timed out waiting for the capture child")
        XCTAssertTrue(waitUntil { registry.registeredProcessCount == 1 })

        lifecycle.shutdown()

        XCTAssertEqual(completion.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.workspaceDirectory.path))
        XCTAssertEqual(registry.registeredProcessCount, 0)
        let signals = recorder.values
        let termIndex = try XCTUnwrap(signals.firstIndex(of: SIGTERM))
        let killIndex = try XCTUnwrap(signals.firstIndex(of: SIGKILL))
        XCTAssertLessThan(termIndex, killIndex)
        guard case .success(let result)? = resultBox.value else {
            return XCTFail("Expected the terminated child to produce a process result")
        }
        XCTAssertNotEqual(result.terminationStatus, 0)

        let mustNotLaunch = fixture.directory.appendingPathComponent("must-not-launch")
        XCTAssertThrowsError(try ScreenCaptureService.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "touch \"$1\"", "rejected-child", mustNotLaunch.path],
            registry: registry
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mustNotLaunch.path))
    }

    func testLaunchCompletingAfterTerminationIsRejectedAndKilled() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanup() }
        let recorder = CaptureSignalRecorder()
        let registry = ScreenCaptureProcessRegistry { pid, signal in
            recorder.record(signal)
            return Darwin.kill(pid, signal)
        }
        try registry.beginLaunch()
        registry.terminateAll(gracePeriod: 0.01, killWait: 0.01)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let childStarted = fixture.directory.appendingPathComponent("rejected-child-started")
        process.arguments = [
            "-c",
            "trap '' TERM; touch \"$1\"; while :; do :; done",
            "rejected-child",
            childStarted.path
        ]
        try process.run()
        defer { stopProcess(process) }
        XCTAssertTrue(waitForFile(childStarted), "Timed out waiting for the rejected child")

        XCTAssertFalse(registry.registerLaunchedProcess(process))
        registry.terminateRejectedLaunch(process, gracePeriod: 0.02, killWait: 0.5)
        registry.unregister(process)

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(registry.registeredProcessCount, 0)
        let signals = recorder.values
        let termIndex = try XCTUnwrap(signals.firstIndex(of: SIGTERM))
        let killIndex = try XCTUnwrap(signals.firstIndex(of: SIGKILL))
        XCTAssertLessThan(termIndex, killIndex)
    }
}

private struct CaptureFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenCaptureServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class CaptureSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var values: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ signal: Int32) {
        lock.lock()
        storage.append(signal)
        lock.unlock()
    }
}

private final class CaptureProcessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<ScreenCaptureService.ProcessResult, Error>?

    var value: Result<ScreenCaptureService.ProcessResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ result: Result<ScreenCaptureService.ProcessResult, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 2) -> Bool {
    waitUntil(timeout: timeout) {
        FileManager.default.fileExists(atPath: url.path)
    }
}

private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

private func stopProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    if waitUntil(timeout: 0.5, condition: { !process.isRunning }) {
        return
    }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    _ = waitUntil(timeout: 0.5) { !process.isRunning }
}
