import CryptoKit
import Foundation
import XCTest
@testable import CaptureLab

final class UpdateCheckServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        MockURLProtocol.reset()
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testReportsUpdateAvailableWithMatchingArchitecturePackage() async throws {
        let service = makeService(
            statusCode: 200,
            body: """
            {
              "tag_name": "v0.2.0",
              "assets": [
                {
                  "name": "CaptureLab-0.2.0-macos-arm64.dmg",
                  "browser_download_url": "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg"
                },
                {
                  "name": "CaptureLab-0.2.0-macos-arm64.dmg.sha256",
                  "browser_download_url": "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg.sha256"
                },
                {
                  "name": "CaptureLab-0.2.0-macos-arm64.dmg.sig",
                  "browser_download_url": "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg.sig"
                },
                {
                  "name": "CaptureLab-0.2.0-macos-x86_64.dmg",
                  "browser_download_url": "https://example.com/CaptureLab-0.2.0-macos-x86_64.dmg"
                }
              ]
            }
            """,
            architecture: "arm64"
        )

        let result = try await service.checkForUpdates(currentVersion: "0.1.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                currentVersion: "0.1.0",
                latestVersion: "0.2.0",
                package: UpdatePackage(
                    dmg: UpdateAsset(
                        name: "CaptureLab-0.2.0-macos-arm64.dmg",
                        downloadURL: URL(string: "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg")!
                    ),
                    checksum: UpdateAsset(
                        name: "CaptureLab-0.2.0-macos-arm64.dmg.sha256",
                        downloadURL: URL(string: "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg.sha256")!
                    ),
                    signature: UpdateAsset(
                        name: "CaptureLab-0.2.0-macos-arm64.dmg.sig",
                        downloadURL: URL(string: "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg.sig")!
                    ),
                    architecture: "arm64"
                )
            )
        )
    }

    func testReportsUpToDateForSameGitHubRelease() async throws {
        let service = makeService(
            statusCode: 200,
            body: #"{"tag_name":"v0.1.0"}"#
        )

        let result = try await service.checkForUpdates(currentVersion: "0.1.0")

        XCTAssertEqual(
            result,
            .upToDate(
                currentVersion: "0.1.0",
                releasesURL: URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!
            )
        )
    }

    func testMapsGitHubNotFoundToRepositoryUnavailable() async {
        let service = makeService(statusCode: 404, body: #"{}"#)

        do {
            _ = try await service.checkForUpdates(currentVersion: "0.1.0")
            XCTFail("Expected repositoryUnavailable")
        } catch UpdateCheckError.repositoryUnavailable {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingMatchingArchitectureAssetFailsDirectUpdate() async throws {
        let service = makeService(
            statusCode: 200,
            body: """
            {
              "tag_name": "v0.2.0",
              "assets": [
                {
                  "name": "CaptureLab-0.2.0-macos-x86_64.dmg",
                  "browser_download_url": "https://example.com/CaptureLab-0.2.0-macos-x86_64.dmg"
                }
              ]
            }
            """,
            architecture: "arm64"
        )

        do {
            _ = try await service.checkForUpdates(currentVersion: "0.1.0")
            XCTFail("Expected updateAssetUnavailable")
        } catch UpdateCheckError.updateAssetUnavailable(let architecture) {
            XCTAssertEqual(architecture, "arm64")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadUpdateWritesDMGAndVerifiesChecksum() async throws {
        let dmgURL = URL(string: "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg")!
        let checksumURL = URL(string: "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg.sha256")!
        let signatureURL = URL(string: "https://example.com/CaptureLab-0.2.0-macos-arm64.dmg.sig")!
        let dmgData = Data("fixture-dmg".utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        let digestData = Data(SHA256.hash(data: dmgData))
        let digest = digestData.map { String(format: "%02x", $0) }.joined()
        MockURLProtocol.register(MockResponse(statusCode: 200, data: dmgData), for: dmgURL)
        MockURLProtocol.register(MockResponse(
            statusCode: 200,
            data: Data("\(digest)  CaptureLab-0.2.0-macos-arm64.dmg\n".utf8)
        ), for: checksumURL)
        MockURLProtocol.register(MockResponse(
            statusCode: 200,
            data: try privateKey.signature(for: digestData)
        ), for: signatureURL)

        let service = makeService(
            statusCode: 200,
            body: #"{}"#,
            signaturePublicKey: privateKey.publicKey.rawRepresentation
        )
        let outputURL = try await service.downloadUpdate(
            UpdatePackage(
                dmg: UpdateAsset(name: "CaptureLab-0.2.0-macos-arm64.dmg", downloadURL: dmgURL),
                checksum: UpdateAsset(name: "CaptureLab-0.2.0-macos-arm64.dmg.sha256", downloadURL: checksumURL),
                signature: UpdateAsset(name: "CaptureLab-0.2.0-macos-arm64.dmg.sig", downloadURL: signatureURL),
                architecture: "arm64"
            ),
            latestVersion: "0.2.0"
        )

        XCTAssertEqual(try Data(contentsOf: outputURL), dmgData)
    }

    func testDownloadRejectsSignatureFromDifferentKey() async throws {
        let dmgURL = URL(string: "https://example.com/update.dmg")!
        let checksumURL = URL(string: "https://example.com/update.dmg.sha256")!
        let signatureURL = URL(string: "https://example.com/update.dmg.sig")!
        let dmgData = Data("fixture-dmg".utf8)
        let trustedKey = Curve25519.Signing.PrivateKey()
        let untrustedKey = Curve25519.Signing.PrivateKey()
        let digestData = Data(SHA256.hash(data: dmgData))
        let digest = digestData.map { String(format: "%02x", $0) }.joined()
        MockURLProtocol.register(MockResponse(statusCode: 200, data: dmgData), for: dmgURL)
        MockURLProtocol.register(
            MockResponse(statusCode: 200, data: Data(digest.utf8)),
            for: checksumURL
        )
        MockURLProtocol.register(MockResponse(
            statusCode: 200,
            data: try untrustedKey.signature(for: digestData)
        ), for: signatureURL)
        let service = makeService(
            statusCode: 200,
            body: #"{}"#,
            signaturePublicKey: trustedKey.publicKey.rawRepresentation
        )

        do {
            _ = try await service.downloadUpdate(
                UpdatePackage(
                    dmg: UpdateAsset(name: "update.dmg", downloadURL: dmgURL),
                    checksum: UpdateAsset(name: "update.dmg.sha256", downloadURL: checksumURL),
                    signature: UpdateAsset(name: "update.dmg.sig", downloadURL: signatureURL),
                    architecture: "arm64"
                ),
                latestVersion: "0.2.0"
            )
            XCTFail("Expected signatureMismatch")
        } catch UpdateCheckError.signatureMismatch {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadRejectsAssetAboveConfiguredSizeLimit() async throws {
        let dmgURL = URL(string: "https://example.com/too-large.dmg")!
        MockURLProtocol.register(
            MockResponse(statusCode: 200, data: Data(repeating: 0x41, count: 33)),
            for: dmgURL
        )
        let service = makeService(statusCode: 200, body: #"{}"#, maximumDMGSizeBytes: 32)

        do {
            _ = try await service.downloadUpdate(
                UpdatePackage(
                    dmg: UpdateAsset(name: "too-large.dmg", downloadURL: dmgURL),
                    checksum: UpdateAsset(
                        name: "too-large.dmg.sha256",
                        downloadURL: URL(string: "https://example.com/too-large.dmg.sha256")!
                    ),
                    signature: UpdateAsset(
                        name: "too-large.dmg.sig",
                        downloadURL: URL(string: "https://example.com/too-large.dmg.sig")!
                    ),
                    architecture: "arm64"
                ),
                latestVersion: "0.2.0"
            )
            XCTFail("Expected downloadTooLarge")
        } catch UpdateCheckError.downloadTooLarge(let limit) {
            XCTAssertEqual(limit, 32)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPackagingScriptUsesEmbeddedUpdatePublicKey() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/package_dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("UPDATE_SIGNING_PUBLIC_KEY=\"\(UpdateSigningIdentity.publicKeyBase64)\""))
    }

    private func makeService(
        statusCode: Int,
        body: String,
        architecture: String = "arm64",
        signaturePublicKey: Data = UpdateSigningIdentity.publicKeyRawRepresentation,
        maximumDMGSizeBytes: Int64 = UpdateCheckService.maximumDMGSizeBytes
    ) -> UpdateCheckService {
        let latestReleaseURL = URL(string: "https://example.com/latest")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockURLProtocol.register(
            MockResponse(statusCode: statusCode, data: Data(body.utf8)),
            for: latestReleaseURL
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoots.append(temporaryRoot)

        return UpdateCheckService(
            latestReleaseURL: latestReleaseURL,
            releasesURL: URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!,
            session: session,
            temporaryDirectory: temporaryRoot,
            architecture: architecture,
            signaturePublicKey: signaturePublicKey,
            maximumDMGSizeBytes: maximumDMGSizeBytes
        )
    }
}

private struct MockResponse {
    var statusCode: Int
    var data: Data
}

private final class MockURLProtocol: URLProtocol {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [URL: MockResponse] = [:]

        func reset() {
            lock.lock()
            responses.removeAll()
            lock.unlock()
        }

        func register(_ response: MockResponse, for url: URL) {
            lock.lock()
            responses[url] = response
            lock.unlock()
        }

        func response(for url: URL) -> MockResponse? {
            lock.lock()
            defer { lock.unlock() }
            return responses[url]
        }
    }

    private static let state = State()

    static func reset() {
        state.reset()
    }

    static func register(_ response: MockResponse, for url: URL) {
        state.register(response, for: url)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let mock = Self.state.response(for: url)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if let response = HTTPURLResponse(
            url: url,
            statusCode: mock.statusCode,
            httpVersion: nil,
            headerFields: nil
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: mock.data)

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
