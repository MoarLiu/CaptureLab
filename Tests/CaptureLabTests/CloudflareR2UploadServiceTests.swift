import Foundation
import XCTest
@testable import CaptureLab

final class CloudflareR2UploadServiceTests: XCTestCase {
    func testObjectKeyUsesPrefixDateUUIDAndSafeFileName() throws {
        let service = CloudflareR2UploadService()
        let key = service.objectKey(
            fileName: "截图 edited.png",
            settings: settings,
            date: Date(timeIntervalSince1970: 0),
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        XCTAssertEqual(key, "captures/1970/01/01/00000000-0000-0000-0000-000000000001-edited.png")
    }

    func testSignedPUTRequestUsesR2PathStyleEndpoint() throws {
        let service = CloudflareR2UploadService()
        let request = try service.signedPUTRequest(
            settings: settings,
            objectKey: "captures/2026/07/03/test.png",
            data: Data("png".utf8),
            contentType: "image/png",
            requestDate: Date(timeIntervalSince1970: 1_783_036_800)
        )

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://account.r2.cloudflarestorage.com/capture-bucket/captures/2026/07/03/test.png"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "account.r2.cloudflarestorage.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("/auto/s3/aws4_request") == true)
    }

    func testUploadReturnsPublicURLWithoutRealNetwork() async throws {
        var capturedRequest: URLRequest?
        let service = CloudflareR2UploadService(
            now: { Date(timeIntervalSince1970: 0) },
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! },
            transport: { request, _ in
                capturedRequest = request
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), response)
            }
        )

        let result = try await service.upload(CloudflareR2UploadRequest(
            settings: settings,
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            fileName: "capture.png",
            contentType: "image/png"
        ))

        XCTAssertEqual(
            result.url,
            "https://pub.example.com/captures/1970/01/01/00000000-0000-0000-0000-000000000002-capture.png"
        )
        XCTAssertEqual(capturedRequest?.httpMethod, "PUT")
    }

    private var settings: CloudflareR2Settings {
        CloudflareR2Settings(
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "capture-bucket",
            pathPrefix: "captures",
            publicBaseURL: "https://pub.example.com",
            accessKeyID: "access-key",
            secretAccessKey: "secret-key"
        )
    }
}
