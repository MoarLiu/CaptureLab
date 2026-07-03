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
    }
}

private struct HistoryFixture {
    let home: URL
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path]
    }
}
