import XCTest
@testable import CaptureLab

@MainActor
final class CaptureHistoryStoreTests: XCTestCase {
    func testRecordPersistsAndReloadsHistoryItem() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)

        let item = try store.record(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            pixelSize: CGSize(width: 400, height: 300),
            createdAt: Date(timeIntervalSince1970: 1_783_036_800)
        )

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))

        let reloaded = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertEqual(reloaded.items, [item])
        XCTAssertEqual(try reloaded.data(for: item), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testReloadFiltersMissingImageFiles() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let item = try store.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try FileManager.default.removeItem(at: store.url(for: item))

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertTrue(reloaded.items.isEmpty)
    }

    func testCorruptMetadataRecoversExistingPNGFiles() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let item = try store.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try Data("not-json".utf8).write(to: store.metadataURL, options: .atomic)

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNotNil(reloaded.loadError)
        XCTAssertEqual(reloaded.items.map(\.fileName), [item.fileName])
        XCTAssertEqual(try reloaded.data(for: reloaded.items[0]), Data([1, 2, 3]))
    }

    func testMissingMetadataRecoversExistingPNGFilesAndRebuildsMetadata() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let item = try store.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try FileManager.default.removeItem(at: store.metadataURL)

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.items.map(\.fileName), [item.fileName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.metadataURL.path))
    }

    func testValidMetadataReclaimsPNGLeftOrphanedByInterruptedRecord() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let retained = try store.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let orphanURL = store.historyDirectory
            .appendingPathComponent("capture-orphan-\(UUID().uuidString).png")
        try Data([4, 5, 6]).write(to: orphanURL, options: .atomic)

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.items, [retained])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertEqual(try pngURLs(in: reloaded.historyDirectory).count, 1)
    }

    func testMissingMetadataRecoveryRemovesPNGsBeyondRetentionLimit() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let totalCount = CaptureHistoryStore.maxItemCount + 3
        for index in 0..<totalCount {
            let url = store.historyDirectory.appendingPathComponent(
                "capture-recovery-\(index)-\(UUID().uuidString).png"
            )
            try Data([UInt8(index)]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.metadataURL.path))

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.items.count, CaptureHistoryStore.maxItemCount)
        XCTAssertEqual(try pngURLs(in: reloaded.historyDirectory).count, CaptureHistoryStore.maxItemCount)
        XCTAssertTrue(reloaded.items.allSatisfy {
            FileManager.default.fileExists(atPath: reloaded.url(for: $0).path)
        })
    }

    func testRecordRollsBackNewPNGAndMemoryWhenMetadataWriteFails() throws {
        enum FixtureError: Error { case metadataWriteFailed }
        let fixture = try HistoryFixture()
        let originalStore = CaptureHistoryStore(environment: fixture.environment)
        let originalItem = try originalStore.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let originalMetadata = try Data(contentsOf: originalStore.metadataURL)
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { _, _ in throw FixtureError.metadataWriteFailed }
        )

        XCTAssertThrowsError(try failingStore.record(
            data: Data([4, 5, 6]),
            pixelSize: CGSize(width: 20, height: 20),
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(failingStore.items, [originalItem])
        XCTAssertEqual(try Data(contentsOf: failingStore.metadataURL), originalMetadata)
        let pngs = try FileManager.default.contentsOfDirectory(
            at: failingStore.historyDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        XCTAssertEqual(pngs.map(\.lastPathComponent), [originalItem.fileName])
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).items, [originalItem])
    }

    func testRecordKeepsCommittedPNGWhenWriterThrowsAfterReplacingMetadata() throws {
        enum FixtureError: Error { case reportedAfterCommit }
        let fixture = try HistoryFixture()
        let originalStore = CaptureHistoryStore(environment: fixture.environment)
        let originalItem = try originalStore.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw FixtureError.reportedAfterCommit
            }
        )

        XCTAssertThrowsError(try failingStore.record(
            data: Data([4, 5, 6]),
            pixelSize: CGSize(width: 20, height: 20),
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        let reloaded = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertEqual(reloaded.items.last, originalItem)
        XCTAssertTrue(reloaded.items.allSatisfy {
            FileManager.default.fileExists(atPath: reloaded.url(for: $0).path)
        })
        XCTAssertEqual(failingStore.items, reloaded.items)
    }

    func testLongLivedStoresMergeRecordsInsteadOfOverwritingEachOther() throws {
        let fixture = try HistoryFixture()
        let firstStore = CaptureHistoryStore(environment: fixture.environment)
        let secondStore = CaptureHistoryStore(environment: fixture.environment)

        let first = try firstStore.record(
            data: Data([1, 2, 3]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = try secondStore.record(
            data: Data([4, 5, 6]),
            pixelSize: CGSize(width: 20, height: 20),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(secondStore.items, [second, first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStore.url(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStore.url(for: second).path))
        XCTAssertEqual(
            CaptureHistoryStore(environment: fixture.environment).items,
            [second, first]
        )
    }

    func testMetadataTraversalCannotDeleteFileOutsideHistoryDirectory() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)

        for index in 0..<(CaptureHistoryStore.maxItemCount - 1) {
            _ = try store.record(
                data: Data([UInt8(index)]),
                pixelSize: CGSize(width: 10, height: 10),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let outsideURL = store.historyDirectory
            .appendingPathComponent("../../outside.png")
            .standardizedFileURL
        let outsideData = Data("must-not-delete".utf8)
        try outsideData.write(to: outsideURL, options: .atomic)
        let traversalItem = CaptureHistoryItem(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: -1),
            fileName: "../../outside.png",
            pixelWidth: 1,
            pixelHeight: 1
        )
        try writeMetadata(store.items + [traversalItem], to: store.metadataURL)

        _ = try store.record(
            data: Data([255]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideData)
        XCTAssertFalse(store.items.contains(where: { $0.id == traversalItem.id }))
    }

    func testOverflowCleanupNeverDeletesAFileStillReferencedByRetainedMetadata() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let sharedURL = store.historyDirectory.appendingPathComponent("shared.png")
        try Data([1, 2, 3]).write(to: sharedURL, options: .atomic)
        let duplicateItems = (0..<CaptureHistoryStore.maxItemCount).map { index in
            CaptureHistoryItem(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                fileName: "shared.png",
                pixelWidth: 1,
                pixelHeight: 1
            )
        }
        try writeMetadata(duplicateItems, to: store.metadataURL)

        _ = try store.record(
            data: Data([4, 5, 6]),
            pixelSize: CGSize(width: 10, height: 10),
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path))
        let reloaded = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertTrue(reloaded.items.allSatisfy {
            FileManager.default.fileExists(atPath: reloaded.url(for: $0).path)
        })
    }

    func testRecordWaitsForCrossProcessFcntlLock() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let lockURL = store.historyDirectory.appendingPathComponent(".history.lock")
        let readyURL = fixture.home.appendingPathComponent("lock-holder-ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            lockURL.path,
            "/bin/sh",
            "-c",
            "touch \"$1\"; sleep 0.5",
            "lock-holder",
            readyURL.path
        ]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

        let startedAt = Date()
        _ = try store.record(
            data: Data([1]),
            pixelSize: CGSize(width: 1, height: 1),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testRecordTrimsHistoryToMaximumItemCount() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)

        for index in 0..<(CaptureHistoryStore.maxItemCount + 2) {
            _ = try store.record(
                data: Data([UInt8(index % 255)]),
                pixelSize: CGSize(width: 10, height: 10),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(store.items.count, CaptureHistoryStore.maxItemCount)
        XCTAssertEqual(store.items.first?.createdAt, Date(timeIntervalSince1970: 31))
        XCTAssertEqual(store.items.last?.createdAt, Date(timeIntervalSince1970: 2))
        let pngs = try FileManager.default.contentsOfDirectory(
            at: store.historyDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        XCTAssertEqual(pngs.count, CaptureHistoryStore.maxItemCount)
        XCTAssertTrue(store.items.allSatisfy {
            FileManager.default.fileExists(atPath: store.url(for: $0).path)
        })
    }

    private func writeMetadata(_ items: [CaptureHistoryItem], to url: URL) throws {
        struct MetadataDocument: Encodable {
            var schemaVersion: Int
            var items: [CaptureHistoryItem]
        }

        let data = try JSONEncoder().encode(MetadataDocument(schemaVersion: 1, items: items))
        try data.write(to: url, options: .atomic)
    }

    private func pngURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "png" }
    }
}

private final class HistoryFixture {
    let home: URL
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }
}
