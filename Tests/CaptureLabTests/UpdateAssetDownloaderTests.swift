import Foundation
import XCTest
@testable import CaptureLab

final class UpdateAssetDownloaderTests: XCTestCase {
    func testAnnouncedOversizeResponseCancelsWithoutWritingBody() async throws {
        let fixture = try DownloadStreamFixture(contentLength: "1048576")
        do {
            try await fixture.download(limit: 32_768)
            XCTFail("Expected size rejection")
        } catch UpdateCheckError.downloadTooLarge(let limit) {
            XCTAssertEqual(limit, 32_768)
        }
        await fulfillment(of: [fixture.stopped], timeout: 2)
        // Foundation may already have an in-flight chunk when the header
        // callback runs. None may reach disk, and the body must not finish.
        XCTAssertLessThan(fixture.bytesSent, fixture.totalBytes)
        XCTAssertEqual(fixture.maximumWrittenBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testActualByteLimitCancelsUnknownAndUnderstatedLengths() async throws {
        for length in [nil, "1"] as [String?] {
            let fixture = try DownloadStreamFixture(contentLength: length)
            do {
                try await fixture.download(limit: 32_768)
                XCTFail("Expected size rejection")
            } catch UpdateCheckError.downloadTooLarge(let limit) {
                XCTAssertEqual(limit, 32_768)
            }
            await fulfillment(of: [fixture.stopped], timeout: 2)
            XCTAssertGreaterThan(fixture.bytesSent, 32_768)
            XCTAssertLessThan(fixture.bytesSent, fixture.totalBytes)
            XCTAssertLessThanOrEqual(fixture.maximumWrittenBytes, 32_768)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    func testExactLimitSucceedsWithoutDroppingOrDuplicatingChunks() async throws {
        let fixture = try DownloadStreamFixture(contentLength: nil, chunkCount: 4)
        try await fixture.download(limit: Int64(fixture.totalBytes))
        let data = try Data(contentsOf: fixture.output)
        let expected = (0..<4).reduce(into: Data()) { $0.append(Data(repeating: UInt8($1), count: 8192)) }
        XCTAssertEqual(data, expected)
        XCTAssertEqual(fixture.bytesSent, fixture.totalBytes)
    }

    func testBadHTTPStatusIsCancelledWithoutDownloadingBody() async throws {
        let fixture = try DownloadStreamFixture(contentLength: nil, statusCode: 503)
        do {
            try await fixture.download(limit: 32_768)
            XCTFail("Expected HTTP rejection")
        } catch UpdateCheckError.downloadFailed { }
        await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertLessThan(fixture.bytesSent, fixture.totalBytes)
        XCTAssertEqual(fixture.maximumWrittenBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testCancellationStopsTransportAndRemovesPartialFile() async throws {
        let fixture = try DownloadStreamFixture(contentLength: nil)
        let task = Task { try await fixture.download(limit: Int64(fixture.totalBytes)) }
        await fulfillment(of: [fixture.startedBody], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertLessThan(fixture.bytesSent, fixture.totalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testAlreadyCancelledTaskDoesNotCreateAnAsset() async throws {
        let fixture = try DownloadStreamFixture(contentLength: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.download(limit: 32_768)
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(fixture.bytesSent, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testTransportFailureRemovesPartialFile() async throws {
        let fixture = try DownloadStreamFixture(contentLength: nil, chunkCount: 2, failsAtEnd: true)
        do {
            try await fixture.download(limit: 32_768)
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertGreaterThan(fixture.bytesSent, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }
}

private final class DownloadStreamFixture: @unchecked Sendable {
    let output: URL
    let url = URL(string: "https://example.invalid/\(UUID().uuidString)")!
    let contentLength: String?
    let statusCode: Int
    let chunkCount: Int
    let failsAtEnd: Bool
    let stopped = XCTestExpectation(description: "transport cancelled")
    let startedBody = XCTestExpectation(description: "body started")
    private let directory: URL
    private let lock = NSLock()
    private var cancelled = false
    private var sent = 0
    private var maximumWritten = 0
    var totalBytes: Int { chunkCount * 8192 }
    var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return sent }
    var maximumWrittenBytes: Int { lock.lock(); defer { lock.unlock() }; return maximumWritten }

    init(contentLength: String?, statusCode: Int = 200, chunkCount: Int = 128, failsAtEnd: Bool = false) throws {
        self.contentLength = contentLength
        self.statusCode = statusCode
        self.chunkCount = chunkCount
        self.failsAtEnd = failsAtEnd
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateStream-\(UUID().uuidString)")
        output = directory.appendingPathComponent("asset.dmg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StreamingUpdateProtocol.register(self)
    }

    deinit {
        StreamingUpdateProtocol.remove(url)
        try? FileManager.default.removeItem(at: directory)
    }

    func download(limit: Int64) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingUpdateProtocol.self]
        try await UpdateAssetDownloader.download(request: URLRequest(url: url), to: output, maximumSizeBytes: limit, configuration: configuration)
    }

    func shouldSendChunk(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        maximumWritten = max(maximumWritten, size)
        if index < chunkCount {
            sent += 8192
            if index == 0 { startedBody.fulfill() }
        }
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        stopped.fulfill()
    }
}

private final class StreamingUpdateProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        // Avoid keeping fixtures (and their temporary directories) alive here.
        let values = NSMapTable<NSURL, DownloadStreamFixture>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    }
    private static let registry = Registry()
    private let deliveryQueue = DispatchQueue(label: "CaptureLabTests.update-stream")

    static func register(_ fixture: DownloadStreamFixture) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.values.setObject(fixture, forKey: fixture.url as NSURL)
    }
    static func remove(_ url: URL) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.values.removeObject(forKey: url as NSURL)
    }
    private var fixture: DownloadStreamFixture? {
        guard let url = request.url else { return nil }
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        return Self.registry.values.object(forKey: url as NSURL)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let headers = fixture.contentLength.map { ["Content-Length": $0] }
        let response = HTTPURLResponse(url: fixture.url, statusCode: fixture.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        sendChunk(0)
    }

    private func sendChunk(_ index: Int) {
        deliveryQueue.asyncAfter(deadline: .now() + 0.01) { [self] in
            guard let fixture, fixture.shouldSendChunk(index) else { return }
            if index == fixture.chunkCount {
                if fixture.failsAtEnd {
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                } else {
                    client?.urlProtocolDidFinishLoading(self)
                }
                return
            }
            client?.urlProtocol(self, didLoad: Data(repeating: UInt8(index % 256), count: 8192))
            sendChunk(index + 1)
        }
    }
    override func stopLoading() { fixture?.cancel() }
}
