import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureHistoryRetentionTests: XCTestCase {
    func testCorruptItemRecoveryPreservesEveryPairAcrossExpiryRestartAndStaleWriter() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        var now = Date()
        let original = CaptureHistoryStore(environment: fixture.environment, now: { now })
        let policy = CaptureHistoryRetention(maximumCount: 100, maximumAgeDays: 1)
        XCTAssertNil(try original.applyRetention(original.previewRetention(policy)))
        let image = try recoveryImage()
        let png = try XCTUnwrap(image.captureLabPNGData())
        let project = try CaptureProjectStore.encode(document: CaptureDocument(image: image, sourceURL: nil, createdAt: now), annotations: [])
        for _ in 0..<40 {
            _ = try original.saveEditable(preview: png, project: project, for: nil, pixelSize: image.captureLabPixelSize, createdAt: now)
        }
        let recoveredIDs = Set(original.items.map(\.id))
        let resources = original.items.flatMap { [$0.fileName, $0.projectFileName!] }
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: original.metadataURL)) as? [String: Any])
        var entries = try XCTUnwrap(metadata["items"] as? [[String: Any]])
        entries[0]["pixelWidth"] = "damaged field"
        metadata["items"] = entries
        try JSONSerialization.data(withJSONObject: metadata).write(to: original.metadataURL)

        let recovered = CaptureHistoryStore(environment: fixture.environment, now: { now })
        XCTAssertNotNil(recovered.loadError)
        XCTAssertEqual(recovered.retention, policy)
        XCTAssertEqual(Set(recovered.items.map(\.id)), recoveredIDs)
        XCTAssertEqual(recovered.recoveryProtectedIDs, recoveredIDs)
        now = now.addingTimeInterval(2 * 86_400)
        try recovered.refresh()
        let restarted = CaptureHistoryStore(environment: fixture.environment, now: { now })
        XCTAssertEqual(Set(restarted.items.map(\.id)), recoveredIDs)

        _ = try original.record(data: png, pixelSize: image.captureLabPixelSize, createdAt: now)
        try restarted.refresh()
        XCTAssertEqual(restarted.items.count, 41)
        for name in resources {
            XCTAssertTrue(FileManager.default.fileExists(atPath: restarted.historyDirectory.appendingPathComponent(name).path))
        }
        // The existing explicit preview/confirmation is what removes protection.
        let preview = try restarted.previewRetention(.default)
        XCTAssertEqual(preview.removingIDs.count, 11)
        XCTAssertNil(try restarted.applyRetention(preview))
        XCTAssertEqual(restarted.items.count, 30)
        XCTAssertTrue(restarted.recoveryProtectedIDs.isEmpty)
        XCTAssertTrue(CaptureHistoryStore(environment: fixture.environment).recoveryProtectedIDs.isEmpty)
    }

    func testMissingOrUnreadablePolicyCannotDeleteRecoveredCapturesOnNextStartup() throws {
        for missing in [false, true] {
            let fixture = try RetentionFixture()
            defer { fixture.remove() }
            let store = CaptureHistoryStore(environment: fixture.environment)
            XCTAssertNil(try store.applyRetention(store.previewRetention(.init(maximumCount: 300))))
            let image = try recoveryImage()
            let png = try XCTUnwrap(image.captureLabPNGData())
            for _ in 0..<105 { _ = try store.record(data: png, pixelSize: image.captureLabPixelSize) }
            let ids = Set(store.items.map(\.id))
            if missing { try FileManager.default.removeItem(at: store.metadataURL) }
            else { try Data("truncated index".utf8).write(to: store.metadataURL) }
            let recovered = CaptureHistoryStore(environment: fixture.environment)
            XCTAssertEqual(Set(recovered.items.map(\.id)), ids)
            try recovered.refresh()
            let restarted = CaptureHistoryStore(environment: fixture.environment)
            XCTAssertEqual(Set(restarted.items.map(\.id)), ids)
            XCTAssertEqual(restarted.recoveryProtectedIDs, ids)
            for item in restarted.items { XCTAssertEqual(try restarted.data(for: item), png) }
        }
    }

    private func recoveryImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 4, height: 4))
    }

    func testRecoveryWriteFailuresKeepAllResourcesBeforeAndAfterMetadataCommit() throws {
        for commitsBeforeFailure in [false, true] {
            let fixture = try RetentionFixture()
            defer { fixture.remove() }
            let store = CaptureHistoryStore(environment: fixture.environment)
            XCTAssertNil(try store.applyRetention(store.previewRetention(.init(maximumCount: 100))))
            let image = try recoveryImage()
            let png = try XCTUnwrap(image.captureLabPNGData())
            for _ in 0..<40 { _ = try store.record(data: png, pixelSize: image.captureLabPixelSize) }
            let urls = store.items.map { store.url(for: $0) }
            try FileManager.default.removeItem(at: store.metadataURL)
            let failing = CaptureHistoryStore(environment: fixture.environment, metadataWriter: { data, url in
                if commitsBeforeFailure { try data.write(to: url, options: .atomic) }
                throw CocoaError(.fileWriteUnknown)
            })
            XCTAssertNotNil(failing.loadError)
            XCTAssertEqual(failing.items.count, 40)
            XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            let restarted = CaptureHistoryStore(environment: fixture.environment)
            XCTAssertEqual(restarted.items.count, 40)
            XCTAssertEqual(restarted.recoveryProtectedIDs.count, 40)
        }
    }

    func testRaisedLimitSurvivesRestartAndStaleWriter() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let first = CaptureHistoryStore(environment: fixture.environment)
        let stale = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertNil(try first.applyRetention(first.previewRetention(.init(maximumCount: 100))))
        for value in 0..<42 {
            _ = try stale.record(data: Data([UInt8(value)]), pixelSize: CGSize(width: 1, height: 1))
        }
        XCTAssertEqual(stale.items.count, 42)
        let restarted = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertEqual(restarted.retention.maximumCount, 100)
        XCTAssertEqual(restarted.items.count, 42)
        try first.refresh()
        XCTAssertEqual(first.items.count, 42)
    }

    func testLowerLimitPreviewsAndCommitsExactDeletionSet() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let store = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertNil(try store.applyRetention(store.previewRetention(.init(maximumCount: 100))))
        for value in 0..<35 { _ = try store.record(data: Data([UInt8(value)]), pixelSize: CGSize(width: 1, height: 1)) }
        let preview = try store.previewRetention(.default)
        XCTAssertEqual(preview.removingIDs.count, 5)
        XCTAssertEqual(store.items.count, 35, "Preview must not delete anything")
        let removed = store.items.filter { preview.removingIDs.contains($0.id) }
        XCTAssertNil(try store.applyRetention(preview))
        XCTAssertEqual(store.items.count, 30)
        XCTAssertTrue(removed.allSatisfy { !FileManager.default.fileExists(atPath: store.url(for: $0).path) })
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).retention, .default)
    }

    func testConcurrentCaptureRequiresUpdatedDeletionConfirmation() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let first = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertNil(try first.applyRetention(first.previewRetention(.init(maximumCount: 100))))
        for value in 0..<31 { _ = try first.record(data: Data([UInt8(value)]), pixelSize: CGSize(width: 1, height: 1)) }
        let preview = try first.previewRetention(.default)
        let writer = CaptureHistoryStore(environment: fixture.environment)
        _ = try writer.record(data: Data([99]), pixelSize: CGSize(width: 1, height: 1))
        let changed = try XCTUnwrap(first.applyRetention(preview))
        XCTAssertEqual(changed.removingIDs.count, 2)
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).items.count, 32)
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).retention.maximumCount, 100)
        XCTAssertNil(try first.applyRetention(changed))
        XCTAssertEqual(first.items.count, 30)
    }

    func testPolicyAndImagesStayIntactWhenMetadataWriteFails() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let original = CaptureHistoryStore(environment: fixture.environment)
        let item = try original.record(data: Data([1]), pixelSize: CGSize(width: 1, height: 1), createdAt: .distantPast)
        let before = try Data(contentsOf: original.metadataURL)
        let failing = CaptureHistoryStore(environment: fixture.environment, metadataWriter: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let preview = try failing.previewRetention(.init(maximumCount: 100, maximumAgeDays: 1))
        XCTAssertEqual(preview.removingIDs, [item.id])
        XCTAssertThrowsError(try failing.applyRetention(preview))
        XCTAssertEqual(failing.items, [item])
        XCTAssertEqual(failing.retention, .default)
        XCTAssertEqual(try Data(contentsOf: original.metadataURL), before)
        XCTAssertEqual(try original.data(for: item), Data([1]))
    }

    func testWriterReportingFailureAfterCommitSynchronizesPolicyAndDeletion() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let original = CaptureHistoryStore(environment: fixture.environment)
        _ = try original.record(data: Data([1]), pixelSize: CGSize(width: 1, height: 1), createdAt: .distantPast)
        let failing = CaptureHistoryStore(environment: fixture.environment, metadataWriter: { data, url in
            try data.write(to: url, options: .atomic)
            throw CocoaError(.fileWriteUnknown)
        })
        let policy = CaptureHistoryRetention(maximumCount: 100, maximumAgeDays: 1)
        XCTAssertThrowsError(try failing.applyRetention(failing.previewRetention(policy)))
        XCTAssertEqual(failing.retention, policy)
        XCTAssertTrue(failing.items.isEmpty)
        let restarted = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertEqual(restarted.retention, policy)
        XCTAssertTrue(restarted.items.isEmpty)
    }

    func testAgeLimitExpiresOnRefreshAndStartupOnlyAfterDurableCommit() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        let store = CaptureHistoryStore(environment: fixture.environment, now: { now })
        XCTAssertNil(try store.applyRetention(store.previewRetention(.init(maximumCount: 100, maximumAgeDays: 1))))
        let item = try store.record(data: Data([1]), pixelSize: CGSize(width: 1, height: 1), createdAt: start)
        now = start.addingTimeInterval(86_401)
        let failed = CaptureHistoryStore(environment: fixture.environment, metadataWriter: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }, now: { now })
        XCTAssertEqual(failed.items, [item])
        XCTAssertNotNil(failed.loadError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
        try store.refresh()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: item).path))
        let restarted = CaptureHistoryStore(environment: fixture.environment, now: { now })
        XCTAssertTrue(restarted.items.isEmpty)
        XCTAssertEqual(restarted.retention.maximumAgeDays, 1)
    }

    func testAgeAndCountBothApplyAndInvalidSettingsUseDefaults() {
        let now = Date()
        let items = (0..<40).map {
            CaptureHistoryItem(id: UUID(), createdAt: now.addingTimeInterval(-Double($0) * 3_600),
                fileName: "\($0).png", pixelWidth: 1, pixelHeight: 1)
        }
        XCTAssertEqual(CaptureHistoryRetention(maximumCount: 30, maximumAgeDays: 1).retaining(items, now: now).count, 25)
        XCTAssertEqual(CaptureHistoryRetention(maximumCount: 30, maximumAgeDays: 7).retaining(items, now: now).count, 30)
        XCTAssertEqual(CaptureHistoryRetention(maximumCount: -1, maximumAgeDays: -2).validated, .default)
    }
}

private struct RetentionFixture {
    let root: URL
    var environment: [String: String] { ["HOME": root.path] }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureRetentionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
