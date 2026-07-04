import CryptoKit
import Foundation
import XCTest
@testable import CaptureLab

final class UpdateCheckServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responses = [:]
        MockURLProtocol.error = nil
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
                    )
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
        let dmgData = Data("fixture-dmg".utf8)
        let digest = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        MockURLProtocol.responses[dmgURL] = MockResponse(statusCode: 200, data: dmgData)
        MockURLProtocol.responses[checksumURL] = MockResponse(
            statusCode: 200,
            data: Data("\(digest)  CaptureLab-0.2.0-macos-arm64.dmg\n".utf8)
        )

        let service = makeService(statusCode: 200, body: #"{}"#)
        let outputURL = try await service.downloadUpdate(
            UpdatePackage(
                dmg: UpdateAsset(name: "CaptureLab-0.2.0-macos-arm64.dmg", downloadURL: dmgURL),
                checksum: UpdateAsset(name: "CaptureLab-0.2.0-macos-arm64.dmg.sha256", downloadURL: checksumURL)
            ),
            latestVersion: "0.2.0"
        )

        XCTAssertEqual(try Data(contentsOf: outputURL), dmgData)
    }

    private func makeService(
        statusCode: Int,
        body: String,
        architecture: String = "arm64"
    ) -> UpdateCheckService {
        let latestReleaseURL = URL(string: "https://example.com/latest")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockURLProtocol.responses[latestReleaseURL] = MockResponse(statusCode: statusCode, data: Data(body.utf8))

        return UpdateCheckService(
            latestReleaseURL: latestReleaseURL,
            releasesURL: URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!,
            session: session,
            architecture: architecture
        )
    }
}

private struct MockResponse {
    var statusCode: Int
    var data: Data
}

private final class MockURLProtocol: URLProtocol {
    static var responses: [URL: MockResponse] = [:]
    static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let mock = Self.responses[url]
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
