import AppKit
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

    func testUpdateImagePreservesIdentityAndConcurrentHistoryRecords() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let item = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 10, height: 10))
        let otherStore = CaptureHistoryStore(environment: fixture.environment)
        let newer = try otherStore.record(data: Data([3, 4]), pixelSize: CGSize(width: 20, height: 20))
        let metadata = try Data(contentsOf: store.metadataURL)

        XCTAssertEqual(try store.updateImage(data: Data([5, 6]), for: item), item)

        XCTAssertEqual(store.items, [newer, item])
        XCTAssertEqual(try Data(contentsOf: store.metadataURL), metadata)
        XCTAssertEqual(try store.data(for: item), Data([5, 6]))
        XCTAssertEqual(try store.data(for: newer), Data([3, 4]))
        let reloaded = CaptureHistoryStore(environment: fixture.environment)
        XCTAssertEqual(reloaded.items, [newer, item])
        XCTAssertEqual(try reloaded.data(for: item), Data([5, 6]))
        XCTAssertEqual(try pngURLs(in: store.historyDirectory).count, 2)
    }

    func testUpdateImageFailurePreservesPreviousImageAndMetadata() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let item = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 10, height: 10))
        let metadata = try Data(contentsOf: store.metadataURL)
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            imageWriter: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )

        XCTAssertThrowsError(try failingStore.updateImage(data: Data([3, 4]), for: item))

        XCTAssertEqual(failingStore.items, [item])
        XCTAssertEqual(try store.data(for: item), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: store.metadataURL), metadata)
    }

    func testUpdateImageWriterFailureAfterTemporaryWritePreservesOriginal() throws {
        enum FixtureError: Error { case reportedAfterWrite }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 10, height: 10))
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            imageWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw FixtureError.reportedAfterWrite
            }
        )

        XCTAssertThrowsError(try failingStore.updateImage(data: Data([3, 4]), for: original))

        XCTAssertEqual(try failingStore.data(for: original), Data([1, 2]))
        XCTAssertEqual(failingStore.items, [original])
        XCTAssertEqual(try pngURLs(in: store.historyDirectory).count, 1)
    }

    func testCropCommitsNewDimensionsAndImageWithConcurrentRecords() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 100, height: 80))
        let otherStore = CaptureHistoryStore(environment: fixture.environment)
        let newer = try otherStore.record(data: Data([3, 4]), pixelSize: CGSize(width: 20, height: 20))

        let cropped = try XCTUnwrap(store.updateImage(
            data: Data([5, 6]),
            for: original,
            pixelSize: CGSize(width: 40, height: 30)
        ))

        XCTAssertEqual(cropped.id, original.id)
        XCTAssertEqual(cropped.createdAt, original.createdAt)
        XCTAssertEqual(cropped.pixelSize, CGSize(width: 40, height: 30))
        XCTAssertNotEqual(cropped.fileName, original.fileName)
        XCTAssertEqual(store.items, [newer, cropped])
        XCTAssertEqual(try store.data(for: cropped), Data([5, 6]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: original).path))
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).items, [newer, cropped])
        XCTAssertEqual(try pngURLs(in: store.historyDirectory).count, 2)
    }

    func testCropMetadataFailurePreservesOriginalImageAndDimensions() throws {
        enum FixtureError: Error { case metadataWriteFailed }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 100, height: 80))
        let metadata = try Data(contentsOf: store.metadataURL)
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { _, _ in throw FixtureError.metadataWriteFailed }
        )

        XCTAssertThrowsError(try failingStore.updateImage(
            data: Data([3, 4]),
            for: original,
            pixelSize: CGSize(width: 40, height: 30)
        ))

        XCTAssertEqual(failingStore.items, [original])
        XCTAssertEqual(try failingStore.data(for: original), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: store.metadataURL), metadata)
        XCTAssertEqual(try pngURLs(in: store.historyDirectory).count, 1)
    }

    func testCropSynchronizesCommitWhenMetadataWriterReportsFailureAfterCommit() throws {
        enum FixtureError: Error { case reportedAfterCommit }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 100, height: 80))
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw FixtureError.reportedAfterCommit
            }
        )

        XCTAssertThrowsError(try failingStore.updateImage(
            data: Data([3, 4]),
            for: original,
            pixelSize: CGSize(width: 40, height: 30)
        ))

        let committed = try XCTUnwrap(failingStore.items.first)
        XCTAssertEqual(committed.id, original.id)
        XCTAssertEqual(committed.pixelSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(try failingStore.data(for: committed), Data([3, 4]))
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).items, [committed])
        XCTAssertEqual(try pngURLs(in: store.historyDirectory).count, 1)
    }

    func testCropUnreadableMetadataFailurePreservesAllImagesForRecovery() throws {
        enum FixtureError: Error { case unreadableCommit }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1, 2]), pixelSize: CGSize(width: 100, height: 80))
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { _, url in
                try Data("not-json".utf8).write(to: url, options: .atomic)
                throw FixtureError.unreadableCommit
            }
        )

        XCTAssertThrowsError(try failingStore.updateImage(
            data: Data([3, 4]),
            for: original,
            pixelSize: CGSize(width: 40, height: 30)
        ))

        XCTAssertEqual(failingStore.items, [original])
        XCTAssertEqual(try failingStore.data(for: original), Data([1, 2]))
        let pngs = try pngURLs(in: store.historyDirectory)
        XCTAssertEqual(pngs.count, 2)
        let newImage = try XCTUnwrap(pngs.first { $0.lastPathComponent != original.fileName })
        XCTAssertEqual(try Data(contentsOf: newImage), Data([3, 4]))
    }

    func testRemoveMergesConcurrentRecordsAndRefreshesOtherStore() throws {
        let fixture = try HistoryFixture()
        let firstStore = CaptureHistoryStore(environment: fixture.environment)
        let original = try firstStore.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let secondStore = CaptureHistoryStore(environment: fixture.environment)
        let concurrent = try secondStore.record(data: Data([2]), pixelSize: CGSize(width: 20, height: 20))

        try firstStore.remove(original)

        XCTAssertEqual(firstStore.items, [concurrent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstStore.url(for: original).path))
        XCTAssertEqual(try firstStore.data(for: concurrent), Data([2]))
        try secondStore.refresh()
        XCTAssertEqual(secondStore.items, [concurrent])
        XCTAssertEqual(try pngURLs(in: firstStore.historyDirectory).count, 1)
    }

    func testRemoveMetadataFailureKeepsImageAndSynchronizesConcurrentRecords() throws {
        enum FixtureError: Error { case metadataWriteFailed }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { _, _ in throw FixtureError.metadataWriteFailed }
        )
        let concurrent = try store.record(data: Data([2]), pixelSize: CGSize(width: 20, height: 20))

        XCTAssertThrowsError(try failingStore.remove(original))

        XCTAssertEqual(failingStore.items, [concurrent, original])
        XCTAssertEqual(try failingStore.data(for: original), Data([1]))
        XCTAssertEqual(try failingStore.data(for: concurrent), Data([2]))
        XCTAssertEqual(try pngURLs(in: store.historyDirectory).count, 2)
    }

    func testRemoveSynchronizesCommitWhenMetadataWriterReportsFailureAfterCommit() throws {
        enum FixtureError: Error { case reportedAfterCommit }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let retained = try store.record(data: Data([2]), pixelSize: CGSize(width: 20, height: 20))
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw FixtureError.reportedAfterCommit
            }
        )

        XCTAssertThrowsError(try failingStore.remove(original))

        XCTAssertEqual(failingStore.items, [retained])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: original).path))
        XCTAssertEqual(try failingStore.data(for: retained), Data([2]))
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).items, [retained])
    }

    func testRemoveReportsImageCleanupFailureAfterCommittingMetadata() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let fileManager = FailingPNGRemovalFileManager()
        let failingStore = CaptureHistoryStore(environment: fixture.environment, fileManager: fileManager)
        fileManager.rejectPNGRemoval = true

        XCTAssertThrowsError(try failingStore.remove(original))

        XCTAssertTrue(failingStore.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: original).path))
        // Refreshing with a functioning file manager reclaims the orphan while
        // preserving the already committed empty history snapshot.
        try store.refresh()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: original).path))
    }

    func testFailedRemovalPreservesRawMetadataReferencesFilteredFromVisibleItems() throws {
        enum FixtureError: Error { case metadataWriteFailed }
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let failingStore = CaptureHistoryStore(
            environment: fixture.environment,
            metadataWriter: { _, _ in throw FixtureError.metadataWriteFailed }
        )
        var duplicate = original
        duplicate.fileName = "duplicate.png"
        let duplicateURL = store.url(for: duplicate)
        try Data([2]).write(to: duplicateURL, options: .atomic)
        try writeMetadata([original, duplicate], to: store.metadataURL)

        XCTAssertThrowsError(try failingStore.remove(original))

        XCTAssertEqual(failingStore.items, [original])
        XCTAssertEqual(try failingStore.data(for: original), Data([1]))
        XCTAssertEqual(try Data(contentsOf: duplicateURL), Data([2]))
    }

    func testCorruptMetadataRefreshPreservesCurrentSnapshotAndAllImages() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let orphan = store.historyDirectory.appendingPathComponent("orphan.png")
        try Data([2]).write(to: orphan, options: .atomic)
        try Data("not-json".utf8).write(to: store.metadataURL, options: .atomic)

        XCTAssertThrowsError(try store.refresh())

        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.items, [original])
        XCTAssertEqual(try store.data(for: original), Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: store.metadataURL), Data("not-json".utf8))
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

    func testMissingMetadataRecoveryDeduplicatesImageRevisionsByCaptureID() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let revisionURL = store.historyDirectory.appendingPathComponent(
            "capture-revision-\(UUID().uuidString)-\(original.id.uuidString).png"
        )
        try Data([2]).write(to: revisionURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: store.url(for: original).path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: revisionURL.path
        )
        try FileManager.default.removeItem(at: store.metadataURL)

        let recovered = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNil(recovered.loadError)
        XCTAssertEqual(recovered.items.count, 1)
        XCTAssertEqual(recovered.items.first?.id, original.id)
        XCTAssertEqual(recovered.items.first?.fileName, revisionURL.lastPathComponent)
        XCTAssertEqual(try recovered.data(for: XCTUnwrap(recovered.items.first)), Data([2]))
        XCTAssertEqual(try pngURLs(in: recovered.historyDirectory).count, 1)
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

    func testStartupReclaimsInterruptedImageUpdateWithoutChangingOriginalOrMetadata() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let originalData = try makePNGData(color: .red)
        let original = try store.record(data: originalData, pixelSize: CGSize(width: 4, height: 3))
        let metadata = try Data(contentsOf: store.metadataURL)
        let pending = try writeInterruptedImageUpdate(
            data: makePNGData(color: .green),
            in: store.historyDirectory
        )
        XCTAssertNotNil(NSImage(contentsOf: pending))

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.items, [original])
        XCTAssertEqual(try reloaded.data(for: original), originalData)
        XCTAssertEqual(try Data(contentsOf: reloaded.metadataURL), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testRefreshReclaimsInterruptedImageUpdateAndKeepsOtherStoreRecords() throws {
        let fixture = try HistoryFixture()
        let firstStore = CaptureHistoryStore(environment: fixture.environment)
        let originalData = try makePNGData(color: .red)
        let original = try firstStore.record(data: originalData, pixelSize: CGSize(width: 4, height: 3))
        let secondStore = CaptureHistoryStore(environment: fixture.environment)
        let newerData = try makePNGData(color: .blue)
        let newer = try secondStore.record(data: newerData, pixelSize: CGSize(width: 4, height: 3))
        let pending = try writeInterruptedImageUpdate(
            data: makePNGData(color: .green),
            in: firstStore.historyDirectory
        )

        try firstStore.refresh()

        XCTAssertEqual(firstStore.items, [newer, original])
        XCTAssertEqual(try firstStore.data(for: original), originalData)
        XCTAssertEqual(try firstStore.data(for: newer), newerData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        try secondStore.refresh()
        XCTAssertEqual(secondStore.items, firstStore.items)
    }

    func testRemoveReclaimsInterruptedImageUpdateWhileKeepingRemainingImage() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: makePNGData(color: .red), pixelSize: CGSize(width: 4, height: 3))
        let retainedData = try makePNGData(color: .blue)
        let retained = try store.record(data: retainedData, pixelSize: CGSize(width: 4, height: 3))
        let pending = try writeInterruptedImageUpdate(
            data: makePNGData(color: .green),
            in: store.historyDirectory
        )

        try store.remove(original)

        XCTAssertEqual(store.items, [retained])
        XCTAssertEqual(try store.data(for: retained), retainedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: original).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(CaptureHistoryStore(environment: fixture.environment).items, [retained])
    }

    func testCorruptMetadataStartupReclaimsInterruptedUpdateAndRecoversOriginal() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let originalData = try makePNGData(color: .red)
        let original = try store.record(data: originalData, pixelSize: CGSize(width: 4, height: 3))
        let pending = try writeInterruptedImageUpdate(
            data: makePNGData(color: .green),
            in: store.historyDirectory
        )
        try Data("not-json".utf8).write(to: store.metadataURL, options: .atomic)

        let recovered = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertNotNil(recovered.loadError)
        let recoveredItem = try XCTUnwrap(recovered.items.first)
        XCTAssertEqual(recoveredItem.id, original.id)
        XCTAssertEqual(recoveredItem.pixelSize, CGSize(width: 4, height: 3))
        XCTAssertEqual(try recovered.data(for: recoveredItem), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testPendingCleanupPreservesUnknownFilesDirectoriesAndSymbolicLinks() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let data = try makePNGData(color: .red)
        let retained = try store.record(data: data, pixelSize: CGSize(width: 4, height: 3))
        let canonicalID = "00112233-4455-4677-8899-AABBCCDDEEFF"
        let unknownNames = [
            ".image-update-not-a-uuid.pending",
            ".image-update-\(canonicalID.lowercased()).pending",
            ".image-update-\(canonicalID).extra.pending",
            ".image-update-\(canonicalID).pending.backup",
            ".image-update-\(canonicalID).PENDING",
            "image-update-\(canonicalID).pending",
            ".other-\(canonicalID).pending"
        ]
        let unknownURLs = unknownNames.map { store.historyDirectory.appendingPathComponent($0) }
        for url in unknownURLs { try data.write(to: url, options: .atomic) }
        let directory = store.historyDirectory.appendingPathComponent(".image-update-\(UUID().uuidString).pending")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nestedImage = directory.appendingPathComponent("private.png")
        try data.write(to: nestedImage, options: .atomic)
        let outsideImage = fixture.home.appendingPathComponent("outside.png")
        try data.write(to: outsideImage, options: .atomic)
        let symlink = store.historyDirectory.appendingPathComponent(".image-update-\(UUID().uuidString).pending")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideImage)
        let brokenSymlink = store.historyDirectory.appendingPathComponent(".image-update-\(UUID().uuidString).pending")
        let missingTarget = fixture.home.appendingPathComponent("missing.png")
        try FileManager.default.createSymbolicLink(at: brokenSymlink, withDestinationURL: missingTarget)
        let abandoned = try writeInterruptedImageUpdate(data: data, in: store.historyDirectory)

        try store.refresh()

        XCTAssertEqual(store.items, [retained])
        XCTAssertEqual(try store.data(for: retained), data)
        for url in unknownURLs { XCTAssertEqual(try Data(contentsOf: url), data) }
        XCTAssertEqual(try Data(contentsOf: nestedImage), data)
        XCTAssertEqual(try Data(contentsOf: outsideImage), data)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), outsideImage.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: brokenSymlink.path), missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testPendingCleanupFailureReportsErrorPreservesOriginalAndRetries() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let originalData = try makePNGData(color: .red)
        let original = try store.record(data: originalData, pixelSize: CGSize(width: 4, height: 3))
        let fileManager = FailingPendingRemovalFileManager()
        let failingStore = CaptureHistoryStore(environment: fixture.environment, fileManager: fileManager)
        let metadata = try Data(contentsOf: store.metadataURL)
        let pending = try writeInterruptedImageUpdate(
            data: makePNGData(color: .green),
            in: store.historyDirectory
        )
        fileManager.rejectPendingRemoval = true

        let failedStartup = CaptureHistoryStore(environment: fixture.environment, fileManager: fileManager)
        XCTAssertNotNil(failedStartup.loadError)
        XCTAssertEqual(failedStartup.items.map(\.id), [original.id])
        XCTAssertEqual(try failedStartup.data(for: XCTUnwrap(failedStartup.items.first)), originalData)
        XCTAssertThrowsError(try failingStore.refresh())
        XCTAssertNotNil(failingStore.loadError)
        XCTAssertThrowsError(try failingStore.remove(original))
        XCTAssertEqual(failingStore.items, [original])
        XCTAssertEqual(try failingStore.data(for: original), originalData)
        XCTAssertEqual(try Data(contentsOf: store.metadataURL), metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))

        fileManager.rejectPendingRemoval = false
        try failingStore.refresh()
        XCTAssertNil(failingStore.loadError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(failingStore.items, [original])
    }

    func testRefreshWaitsForActiveCrossProcessImageUpdateBeforeCleanup() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: makePNGData(color: .red), pixelSize: CGSize(width: 4, height: 3))
        let updatedData = try makePNGData(color: .green)
        let source = fixture.home.appendingPathComponent("updated.png")
        try updatedData.write(to: source, options: .atomic)
        let pending = store.historyDirectory.appendingPathComponent(".image-update-\(UUID().uuidString).pending")
        let ready = fixture.home.appendingPathComponent("image-writer-ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            "-k",
            store.historyDirectory.appendingPathComponent(".history.lock").path,
            "/bin/sh", "-c",
            """
            cp "$1" "$2" || exit 1
            touch "$3" || exit 2
            sleep 0.5
            test -f "$2" || exit 3
            mv "$2" "$4" || exit 4
            """,
            "image-writer", source.path, pending.path, ready.path, store.url(for: original).path
        ]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        try store.refresh()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "Cleanup must not remove a live writer's pending PNG")
        XCTAssertEqual(store.items, [original])
        XCTAssertEqual(try store.data(for: original), updatedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testValidMetadataKeepsReferencedRevisionOverNewerOrphanWithSameID() throws {
        let fixture = try HistoryFixture()
        let store = CaptureHistoryStore(environment: fixture.environment)
        let original = try store.record(data: Data([1]), pixelSize: CGSize(width: 10, height: 10))
        let orphanURL = store.historyDirectory.appendingPathComponent(
            "capture-revision-\(UUID().uuidString)-\(original.id.uuidString).png"
        )
        try Data([2]).write(to: orphanURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: orphanURL.path
        )

        let reloaded = CaptureHistoryStore(environment: fixture.environment)

        XCTAssertEqual(reloaded.items, [original])
        XCTAssertEqual(try reloaded.data(for: original), Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
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

    private func makePNGData(color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
        ))
        for y in 0..<3 {
            for x in 0..<4 { bitmap.setColor(color, atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func writeInterruptedImageUpdate(data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(".image-update-\(UUID().uuidString).pending")
        try data.write(to: url, options: .atomic)
        return url
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

private final class FailingPNGRemovalFileManager: FileManager, @unchecked Sendable {
    var rejectPNGRemoval = false

    override func removeItem(at url: URL) throws {
        if rejectPNGRemoval, url.pathExtension.lowercased() == "png" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private final class FailingPendingRemovalFileManager: FileManager, @unchecked Sendable {
    var rejectPendingRemoval = false

    override func removeItem(at url: URL) throws {
        if rejectPendingRemoval, url.pathExtension == "pending" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
