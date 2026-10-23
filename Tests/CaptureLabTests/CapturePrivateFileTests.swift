import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CapturePrivateFileTests: XCTestCase {
    func testManualRefreshRetriesPreviouslySkippedPermissionMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePermissionRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path]
        let original = CaptureHistoryStore(environment: environment)
        let item = try original.record(data: Data([1]), pixelSize: CGSize(width: 1, height: 1))
        let image = original.url(for: item)
        let alias = root.appendingPathComponent("outside-hardlink")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path)
        try FileManager.default.linkItem(at: image, to: alias)
        let reopened = CaptureHistoryStore(environment: environment)
        XCTAssertEqual(reopened.permissionMigrationFailures, 1)
        XCTAssertEqual(try mode(image), 0o644)
        try FileManager.default.removeItem(at: alias)
        try reopened.refresh()
        XCTAssertEqual(reopened.permissionMigrationFailures, 0)
        XCTAssertEqual(try mode(image), 0o600)
        XCTAssertEqual(try reopened.imageSnapshot(for: item).data, Data([1]))
    }

    func testPrivateAtomicWriterUnderDifferentUmasksInIsolatedProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePrivateWriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let implementation = try String(contentsOf: repository.appendingPathComponent("Sources/CaptureLab/Support/CapturePrivateFile.swift"), encoding: .utf8)
        let script = root.appendingPathComponent("probe.swift")
        try (implementation + #"""

        umask(mode_t(Int(CommandLine.arguments[2], radix: 8)!))
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try CapturePrivateFile.ensureDirectory(directory)
        let file = directory.appendingPathComponent("synthetic.png")
        try CapturePrivateFile.writeAtomically(Data([1, 2]), to: file)
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
        }
        guard try mode(directory) == 0o700, try mode(file) == 0o600 else { exit(1) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try CapturePrivateFile.writeAtomically(Data([3]), to: file)
        guard try mode(file) == 0o600, try Data(contentsOf: file) == Data([3]) else { exit(2) }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["synthetic.png"] else { exit(3) }
        """#).write(to: script, atomically: true, encoding: .utf8)
        for mask in ["022", "000", "077"] {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swift", script.path, root.path, mask]
            process.standardError = errors
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        }
    }

    func testHistoryMigratesOnlyOwnRegularFilesAndPresetsUseInjectedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePrivateHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path]
        let support = CaptureLabDataRoot.supportDirectory(environment: environment)
        let history = support.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let id = UUID()
        let item = CaptureHistoryItem(id: id, createdAt: Date(), fileName: "capture-\(id.uuidString).png",
            pixelWidth: 1, pixelHeight: 1, projectFileName: "capture-\(id.uuidString).capturelab")
        struct Archive: Encodable { var schemaVersion = 3; var items: [CaptureHistoryItem] }
        let files = [history.appendingPathComponent(item.fileName), history.appendingPathComponent(item.projectFileName!),
                     history.appendingPathComponent("history.json")]
        for file in files { try Data([1]).write(to: file) }
        try JSONEncoder().encode(Archive(items: [item])).write(to: files[2])
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        for directory in [support, history] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let outside = root.appendingPathComponent("outside.png")
        try Data([9]).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: history.appendingPathComponent("linked.png"), withDestinationURL: outside)
        let release = support.appendingPathComponent("Release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let untouched = release.appendingPathComponent("synthetic-private-key")
        try Data([8]).write(to: untouched)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: untouched.path)
        let store = CaptureHistoryStore(environment: environment)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.items, [item])
        XCTAssertEqual(store.permissionMigrationFailures, 0)
        for file in files { XCTAssertEqual(try mode(file), 0o600) }
        for directory in [support, history] { XCTAssertEqual(try mode(directory), 0o700) }
        XCTAssertEqual(try mode(outside), 0o644)
        XCTAssertEqual(try mode(untouched), 0o640)
        let preset = try CapturePresentationStore(environment: environment).save(name: "Synthetic", presentation: .init())
        XCTAssertEqual(CapturePresentationStore(environment: environment).presets, [preset])
        XCTAssertEqual(try mode(support.appendingPathComponent("presentation-presets.json")), 0o600)
        _ = try store.saveEditable(preview: Data([2]), project: Data([3]), for: item,
            pixelSize: item.pixelSize, createdAt: item.createdAt)
        for name in try FileManager.default.contentsOfDirectory(atPath: history.path) where name != "linked.png" {
            XCTAssertEqual(try mode(history.appendingPathComponent(name)), 0o600)
        }
    }

    func testSymlinkLockIsRejectedWithoutFollowingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePrivateSymlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path]
        let support = CaptureLabDataRoot.supportDirectory(environment: environment)
        let history = support.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try Data([9]).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: history.appendingPathComponent(".history.lock"), withDestinationURL: outside)
        XCTAssertNotNil(CaptureHistoryStore(environment: environment).loadError)
        XCTAssertEqual(try mode(outside), 0o644)
        XCTAssertEqual(try Data(contentsOf: outside), Data([9]))
    }

    func testSymlinkHistoryDirectoryCanRecordAndReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLinkedHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path]
        let support = CaptureLabDataRoot.supportDirectory(environment: environment)
        let history = support.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let otherDirectory = root.appendingPathComponent("other-history")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: otherDirectory)
        let store = CaptureHistoryStore(environment: environment)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.historyDirectory, otherDirectory.resolvingSymlinksInPath())
        let item = try store.record(data: Data([1]), pixelSize: CGSize(width: 1, height: 1))
        XCTAssertEqual(CaptureHistoryStore(environment: environment).items, [item])
        XCTAssertEqual(try store.imageSnapshot(for: item).data, Data([1]))
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
