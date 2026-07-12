import XCTest
@testable import CaptureLab

@MainActor
final class CloudflareR2SettingsStoreTests: XCTestCase {
    func testSaveNormalizesSettingsAndPreservesStoredSecret() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let secretStore = InMemoryR2SecretStore()
        let store = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore
        )

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
        let persistedText = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(persistedText.contains("secret-key"))
        XCTAssertFalse(persistedText.contains("secretAccessKey"))
        XCTAssertEqual(try secretStore.secret(for: "access-key"), "secret-key")
        XCTAssertEqual(try posixPermissions(at: store.url), 0o600)
        let lockURL = store.url.deletingLastPathComponent()
            .appendingPathComponent(".cloudflare-r2-settings.lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertEqual(try posixPermissions(at: lockURL), 0o600)

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

        let reloaded = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore
        )
        XCTAssertEqual(reloaded.settings, store.settings)
    }

    func testLongLivedStoreWithBlankSecretKeepsLatestKeychainSecret() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let secretStore = InMemoryR2SecretStore()
        let seed = CloudflareR2SettingsStore(environment: environment, secretStore: secretStore)
        try seed.save(makeInput(pathPrefix: "original", secretAccessKey: "original-secret"))
        let first = CloudflareR2SettingsStore(environment: environment, secretStore: secretStore)
        let staleSecond = CloudflareR2SettingsStore(environment: environment, secretStore: secretStore)

        try first.save(makeInput(pathPrefix: "first", secretAccessKey: "latest-secret"))
        try staleSecond.save(makeInput(pathPrefix: "second", secretAccessKey: ""))

        XCTAssertEqual(try secretStore.secret(for: "access-key"), "latest-secret")
        let reloaded = CloudflareR2SettingsStore(environment: environment, secretStore: secretStore)
        XCTAssertEqual(reloaded.settings?.pathPrefix, "second")
        XCTAssertEqual(reloaded.settings?.secretAccessKey, "latest-secret")
    }

    func testLongLivedRequiredSettingsRefreshesLatestDiskAndKeychainValues() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let secretStore = InMemoryR2SecretStore()
        let seed = CloudflareR2SettingsStore(environment: environment, secretStore: secretStore)
        try seed.save(makeInput(pathPrefix: "original", secretAccessKey: "original-secret"))
        let staleStore = CloudflareR2SettingsStore(
            environment: environment,
            secretStore: secretStore
        )
        let updatingStore = CloudflareR2SettingsStore(
            environment: environment,
            secretStore: secretStore
        )

        try updatingStore.save(
            makeInput(pathPrefix: "latest", secretAccessKey: "latest-secret")
        )
        let refreshed = try staleStore.requiredSettings()

        XCTAssertEqual(refreshed.pathPrefix, "latest")
        XCTAssertEqual(refreshed.secretAccessKey, "latest-secret")
        XCTAssertEqual(staleStore.settings, refreshed)
        XCTAssertNil(staleStore.loadError)
    }

    func testRequiredSettingsReloadRunsInsideTransactionLock() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lock = TrackingR2TransactionLock()
        let secretStore = InMemoryR2SecretStore()
        secretStore.onOperation = { XCTAssertTrue(lock.isHeld) }
        let store = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore,
            transactionLock: lock
        )
        try store.save(makeInput(pathPrefix: "captures", secretAccessKey: "secret"))
        XCTAssertEqual(lock.entryCount, 2)

        let settings = try store.requiredSettings()

        XCTAssertEqual(settings.pathPrefix, "captures")
        XCTAssertEqual(settings.secretAccessKey, "secret")
        XCTAssertEqual(lock.entryCount, 3)
        XCTAssertFalse(lock.isHeld)
    }

    func testSaveKeychainAndFileOperationsRunInsideTransactionLock() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lock = TrackingR2TransactionLock()
        let secretStore = InMemoryR2SecretStore()
        secretStore.onOperation = { XCTAssertTrue(lock.isHeld) }
        let store = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore,
            settingsWriter: { data, url in
                XCTAssertTrue(lock.isHeld)
                try data.write(to: url, options: .atomic)
            },
            settingsPermissionsSetter: { fileManager, url in
                XCTAssertTrue(lock.isHeld)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            },
            transactionLock: lock
        )
        XCTAssertEqual(lock.entryCount, 1)

        try store.save(makeInput(pathPrefix: "captures", secretAccessKey: "secret"))

        XCTAssertEqual(lock.entryCount, 2)
        XCTAssertFalse(lock.isHeld)
    }

    func testLegacyMigrationKeychainAndFileOperationsRunInsideTransactionLock() throws {
        let fixture = try makeLegacySettingsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let lock = TrackingR2TransactionLock()
        let secretStore = InMemoryR2SecretStore()
        secretStore.onOperation = { XCTAssertTrue(lock.isHeld) }

        let store = CloudflareR2SettingsStore(
            environment: ["HOME": fixture.home.path],
            secretStore: secretStore,
            settingsWriter: { data, url in
                XCTAssertTrue(lock.isHeld)
                try data.write(to: url, options: .atomic)
            },
            settingsPermissionsSetter: { fileManager, url in
                XCTAssertTrue(lock.isHeld)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            },
            transactionLock: lock
        )

        XCTAssertEqual(lock.entryCount, 1)
        XCTAssertFalse(lock.isHeld)
        XCTAssertEqual(store.settings?.secretAccessKey, "legacy-secret")
        secretStore.onOperation = nil
        XCTAssertEqual(try secretStore.secret(for: "legacy-access"), "legacy-secret")
        let sanitized = try String(contentsOf: fixture.settingsURL, encoding: .utf8)
        XCTAssertFalse(sanitized.contains("secretAccessKey"))
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

        let store = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: InMemoryR2SecretStore()
        )

        XCTAssertNil(store.settings)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.requiredSettings()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cloudflare R2"))
            XCTAssertFalse(error.localizedDescription.contains(L10n.r2SettingsNotConfigured))
        }
    }

    func testLegacyPlaintextSecretMigratesToSecretStoreAndSanitizesJSON() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsURL = home
            .appendingPathComponent("Library/Application Support/CaptureLab", isDirectory: true)
            .appendingPathComponent(CloudflareR2SettingsStore.fileName)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyJSON = #"{"schemaVersion":1,"settings":{"endpoint":"https://account.r2.cloudflarestorage.com","bucket":"bucket","pathPrefix":"captures","publicBaseURL":"https://pub.example.com","accessKeyID":"legacy-access","secretAccessKey":"legacy-secret"}}"#
        try Data(legacyJSON.utf8).write(to: settingsURL)
        let secretStore = InMemoryR2SecretStore()

        let store = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore
        )

        XCTAssertEqual(store.settings?.secretAccessKey, "legacy-secret")
        XCTAssertEqual(try secretStore.secret(for: "legacy-access"), "legacy-secret")
        let sanitized = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertFalse(sanitized.contains("legacy-secret"))
        XCTAssertFalse(sanitized.contains("secretAccessKey"))
        XCTAssertTrue(sanitized.contains(#""schemaVersion" : 2"#))
    }

    func testLegacyMigrationKeepsPlaintextWhenSecretStoreWriteFails() throws {
        let fixture = try makeLegacySettingsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let store = CloudflareR2SettingsStore(
            environment: ["HOME": fixture.home.path],
            secretStore: FailingR2SecretStore()
        )

        XCTAssertNil(store.settings)
        XCTAssertNotNil(store.loadError)
        let unchanged = try String(contentsOf: fixture.settingsURL, encoding: .utf8)
        XCTAssertTrue(unchanged.contains("legacy-secret"))
    }

    func testLegacyMigrationKeepsPlaintextWhenSanitizedWriteFails() throws {
        enum FixtureError: Error { case writeFailed }
        let fixture = try makeLegacySettingsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let originalJSON = try Data(contentsOf: fixture.settingsURL)
        let secretStore = InMemoryR2SecretStore()

        let store = CloudflareR2SettingsStore(
            environment: ["HOME": fixture.home.path],
            secretStore: secretStore,
            settingsWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw FixtureError.writeFailed
            }
        )

        XCTAssertNil(store.settings)
        XCTAssertNotNil(store.loadError)
        XCTAssertNil(try secretStore.secret(for: "legacy-access"))
        XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), originalJSON)
    }

    func testSaveRollsBackFileSecretAndMemoryWhenWriterThrowsAfterReplacingFile() throws {
        enum FixtureError: Error { case writeFailed }
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let secretStore = InMemoryR2SecretStore()
        let originalStore = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore
        )
        try originalStore.save(makeInput(pathPrefix: "original", secretAccessKey: "original-secret"))
        let originalSettings = try XCTUnwrap(originalStore.settings)
        let originalJSON = try Data(contentsOf: originalStore.url)
        let failingStore = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore,
            settingsWriter: { data, url in
                try data.write(to: url, options: .atomic)
                throw FixtureError.writeFailed
            }
        )

        XCTAssertThrowsError(try failingStore.save(
            makeInput(pathPrefix: "replacement", secretAccessKey: "replacement-secret")
        ))

        XCTAssertEqual(failingStore.settings, originalSettings)
        XCTAssertEqual(try secretStore.secret(for: "access-key"), "original-secret")
        XCTAssertEqual(try Data(contentsOf: failingStore.url), originalJSON)
        let reloaded = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore
        )
        XCTAssertEqual(reloaded.settings, originalSettings)
    }

    func testSaveRollsBackNewFileSecretAndMemoryWhenPermissionsFail() throws {
        enum FixtureError: Error { case permissionsFailed }
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let secretStore = InMemoryR2SecretStore()
        let store = CloudflareR2SettingsStore(
            environment: ["HOME": home.path],
            secretStore: secretStore,
            settingsPermissionsSetter: { _, _ in throw FixtureError.permissionsFailed }
        )

        XCTAssertThrowsError(try store.save(
            makeInput(pathPrefix: "captures", secretAccessKey: "new-secret")
        ))

        XCTAssertNil(store.settings)
        XCTAssertNil(try secretStore.secret(for: "access-key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testAccessKeyChangeRollsBackWhenDeletingPreviousSecretFails() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let secretStore = InMemoryR2SecretStore()
        let store = CloudflareR2SettingsStore(
            environment: environment,
            secretStore: secretStore
        )
        try store.save(makeInput(pathPrefix: "original", secretAccessKey: "original-secret"))
        let originalSettings = try XCTUnwrap(store.settings)
        let originalFile = try Data(contentsOf: store.url)
        secretStore.deleteFailureAccessKeyID = "access-key"

        XCTAssertThrowsError(try store.save(makeInput(
            pathPrefix: "replacement",
            secretAccessKey: "replacement-secret",
            accessKeyID: "replacement-access-key"
        )))

        XCTAssertEqual(store.settings, originalSettings)
        XCTAssertEqual(try Data(contentsOf: store.url), originalFile)
        XCTAssertEqual(try secretStore.secret(for: "access-key"), "original-secret")
        XCTAssertNil(try secretStore.secret(for: "replacement-access-key"))
        let reloaded = CloudflareR2SettingsStore(
            environment: environment,
            secretStore: secretStore
        )
        XCTAssertEqual(reloaded.settings, originalSettings)
    }

    func testLegacyMigrationRestoresPlaintextSecretAndPermissionsWhenPermissionsFail() throws {
        enum FixtureError: Error { case permissionsFailed }
        let fixture = try makeLegacySettingsFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: fixture.settingsURL.path
        )
        let originalJSON = try Data(contentsOf: fixture.settingsURL)
        let secretStore = InMemoryR2SecretStore()
        try secretStore.setSecret("previous-secret", for: "legacy-access")

        let store = CloudflareR2SettingsStore(
            environment: ["HOME": fixture.home.path],
            secretStore: secretStore,
            settingsPermissionsSetter: { _, _ in throw FixtureError.permissionsFailed }
        )

        XCTAssertNil(store.settings)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(try secretStore.secret(for: "legacy-access"), "previous-secret")
        XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), originalJSON)
        XCTAssertEqual(try posixPermissions(at: fixture.settingsURL), 0o640)
    }

    func testHTTPSettingsAreRejected() throws {
        XCTAssertThrowsError(try CloudflareR2Settings(
            endpoint: "http://account.r2.cloudflarestorage.com",
            bucket: "bucket",
            pathPrefix: "captures",
            publicBaseURL: "https://pub.example.com",
            accessKeyID: "access",
            secretAccessKey: "secret"
        ).normalized())
        XCTAssertThrowsError(try CloudflareR2Settings(
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "bucket",
            pathPrefix: "captures",
            publicBaseURL: "http://pub.example.com",
            accessKeyID: "access",
            secretAccessKey: "secret"
        ).normalized())
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLabR2StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLegacySettingsFixture() throws -> (home: URL, settingsURL: URL) {
        let home = try makeTemporaryHome()
        let settingsURL = home
            .appendingPathComponent("Library/Application Support/CaptureLab", isDirectory: true)
            .appendingPathComponent(CloudflareR2SettingsStore.fileName)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyJSON = #"{"schemaVersion":1,"settings":{"endpoint":"https://account.r2.cloudflarestorage.com","bucket":"bucket","pathPrefix":"captures","publicBaseURL":"https://pub.example.com","accessKeyID":"legacy-access","secretAccessKey":"legacy-secret"}}"#
        try Data(legacyJSON.utf8).write(to: settingsURL)
        return (home, settingsURL)
    }

    private func makeInput(
        pathPrefix: String,
        secretAccessKey: String,
        accessKeyID: String = "access-key"
    ) -> CloudflareR2SettingsInput {
        CloudflareR2SettingsInput(
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "capture-bucket",
            pathPrefix: pathPrefix,
            publicBaseURL: "https://pub.example.com",
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
    }

    private func posixPermissions(at url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
}

private final class InMemoryR2SecretStore: CloudflareR2SecretStoring {
    struct DeleteFailure: Error {}

    private var secrets: [String: String] = [:]
    var onOperation: (() -> Void)?
    var deleteFailureAccessKeyID: String?

    func secret(for accessKeyID: String) throws -> String? {
        onOperation?()
        return secrets[accessKeyID]
    }

    func setSecret(_ secret: String, for accessKeyID: String) throws {
        onOperation?()
        secrets[accessKeyID] = secret
    }

    func deleteSecret(for accessKeyID: String) throws {
        onOperation?()
        secrets.removeValue(forKey: accessKeyID)
        if deleteFailureAccessKeyID == accessKeyID {
            deleteFailureAccessKeyID = nil
            throw DeleteFailure()
        }
    }
}

private final class TrackingR2TransactionLock: CloudflareR2TransactionLocking {
    private(set) var entryCount = 0
    private(set) var isHeld = false

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        entryCount += 1
        isHeld = true
        defer { isHeld = false }
        return try operation()
    }
}

private struct FailingR2SecretStore: CloudflareR2SecretStoring {
    struct Failure: Error {}

    func secret(for accessKeyID: String) throws -> String? { nil }
    func setSecret(_ secret: String, for accessKeyID: String) throws { throw Failure() }
    func deleteSecret(for accessKeyID: String) throws {}
}
