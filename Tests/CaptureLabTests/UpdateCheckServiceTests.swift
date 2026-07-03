import Foundation
import XCTest
@testable import CaptureLab

final class UpdateCheckServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.response = nil
        MockURLProtocol.data = nil
        MockURLProtocol.error = nil
        super.tearDown()
    }

    func testReportsUpdateAvailableForNewerGitHubRelease() async throws {
        let service = makeService(
            statusCode: 200,
            body: #"{"tag_name":"v0.2.0","html_url":"https://github.com/MoarLiu/CaptureLab/releases/tag/v0.2.0"}"#
        )

        let result = try await service.checkForUpdates(currentVersion: "0.1.0")

        XCTAssertEqual(
            result,
            .updateAvailable(
                currentVersion: "0.1.0",
                latestVersion: "0.2.0",
                releaseURL: URL(string: "https://github.com/MoarLiu/CaptureLab/releases/tag/v0.2.0")!
            )
        )
    }

    func testReportsUpToDateForSameGitHubRelease() async throws {
        let service = makeService(
            statusCode: 200,
            body: #"{"tag_name":"v0.1.0","html_url":"https://github.com/MoarLiu/CaptureLab/releases/tag/v0.1.0"}"#
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

    private func makeService(statusCode: Int, body: String) -> UpdateCheckService {
        let latestReleaseURL = URL(string: "https://example.com/latest")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockURLProtocol.response = HTTPURLResponse(
            url: latestReleaseURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )
        MockURLProtocol.data = Data(body.utf8)

        return UpdateCheckService(
            latestReleaseURL: latestReleaseURL,
            releasesURL: URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!,
            session: session
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    static var response: URLResponse?
    static var data: Data?
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

        if let response = Self.response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        if let data = Self.data {
            client?.urlProtocol(self, didLoad: data)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
