import Foundation
import XCTest

/// A real child process holding the same fcntl record-lock protocol as history.
@MainActor
final class HistoryLockHolder {
    let process = Process()
    private let input = Pipe()
    private static var executable: URL {
        Bundle(for: HistoryLockBundleMarker.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("CaptureLabHistoryLockFixture")
    }

    init(directory: URL) throws {
        let ready = directory.appendingPathComponent(".lock-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        process.executableURL = Self.executable
        process.arguments = [directory.appendingPathComponent(".history.lock").path, ready.path]
        process.standardInput = input
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            release()
            throw CocoaError(.fileLocking)
        }
    }

    func release() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    static func canAcquire(directory: URL) throws -> Bool {
        let probe = Process()
        probe.executableURL = executable
        probe.arguments = [directory.appendingPathComponent(".history.lock").path, "--probe"]
        try probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }
}

private final class HistoryLockBundleMarker: NSObject {}
