import XCTest
@testable import CaptureLab

@MainActor
final class CloudflareR2SettingsStoreTests: XCTestCase {
    func testSaveNormalizesSettingsAndPreservesStoredSecret() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = CloudflareR2SettingsStore(environment: ["HOME": home.path])

        try store.save(CloudflareR2SettingsInput(
            endpoint: "account.r2.cloudflarestorage.com/",
            bucket: "capture-bucket",
            pathPrefix: "/captures/",
            publicBaseURL: "https://pub.example.com/base/",
            accessKeyID: "access-key",
            secretAccessKey: "secret-key"
        ))

        XCTAssertEqual(store.settings?.endpoint, "https://account.r2.cloudflarestorage.com")
        XCTAssertEqual(store.settings?.pathPrefix, "captures")
        XCTAssertEqual(store.settings?.publicBaseURL, "https://pub.example.com/base")
        XCTAssertEqual(store.settings?.secretAccessKey, "secret-key")

        try store.save(CloudflareR2SettingsInput(
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "capture-bucket",
            pathPrefix: "screenshots",
            publicBaseURL: "https://pub.example.com",
            accessKeyID: "access-key",
            secretAccessKey: ""
        ))

        XCTAssertEqual(store.settings?.pathPrefix, "screenshots")
        XCTAssertEqual(store.settings?.secretAccessKey, "secret-key")

        let reloaded = CloudflareR2SettingsStore(environment: ["HOME": home.path])
        XCTAssertEqual(reloaded.settings, store.settings)
    }

    func testCorruptSettingsFileIsReportedAsLoadFailure() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CaptureLab", isDirectory: true)
            .appendingPathComponent(CloudflareR2SettingsStore.fileName)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: settingsURL)

        let store = CloudflareR2SettingsStore(environment: ["HOME": home.path])

        XCTAssertNil(store.settings)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.requiredSettings()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cloudflare R2"))
            XCTAssertFalse(error.localizedDescription.contains(L10n.r2SettingsNotConfigured))
        }
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLabR2StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
