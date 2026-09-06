import Foundation

/// Streams an asset to disk without buffering the whole response. All mutable
/// state, including cancellation and continuation completion, lives on queue.
final class UpdateAssetDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destinationURL: URL
    private let maximumSizeBytes: Int64
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var ownsDestination = false
    private var receivedResponse = false
    private var receivedBytes: Int64 = 0
    private var isCancelled = false

    private init(
        request: URLRequest,
        destinationURL: URL,
        maximumSizeBytes: Int64,
        configuration: URLSessionConfiguration,
        fileManager: FileManager
    ) {
        self.request = request
        self.destinationURL = destinationURL
        self.maximumSizeBytes = maximumSizeBytes
        self.configuration = configuration
        self.fileManager = fileManager
    }

    static func download(
        request: URLRequest,
        to destinationURL: URL,
        maximumSizeBytes: Int64,
        configuration: URLSessionConfiguration,
        fileManager: FileManager = .default
    ) async throws {
        try Task.checkCancellation()
        let downloader = UpdateAssetDownloader(
            request: request,
            destinationURL: destinationURL,
            maximumSizeBytes: maximumSizeBytes,
            configuration: configuration,
            fileManager: fileManager
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.queue.addOperation {
                    downloader.start(continuation)
                }
            }
        } onCancel: {
            downloader.queue.addOperation {
                downloader.isCancelled = true
                downloader.finish(error: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        guard !isCancelled else {
            finish(error: CancellationError())
            return
        }
        do {
            try Data().write(to: destinationURL, options: .withoutOverwriting)
            ownsDestination = true
            file = try FileHandle(forWritingTo: destinationURL)
            // Preserve the caller's transport configuration (including test
            // protocols), but never accumulate an asset in URLCache.
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        } catch {
            finish(error: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard continuation != nil else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(error: UpdateCheckError.downloadFailed)
            return
        }
        guard response.expectedContentLength <= maximumSizeBytes else {
            completionHandler(.cancel)
            finish(error: UpdateCheckError.downloadTooLarge(maximumSizeBytes))
            return
        }
        receivedResponse = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        // Count actual delivered bytes as well: Content-Length may be absent,
        // misleading, or describe a compressed response rather than its output.
        guard Int64(data.count) <= maximumSizeBytes - receivedBytes else {
            finish(error: UpdateCheckError.downloadTooLarge(maximumSizeBytes))
            return
        }
        do {
            try file?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
        } catch {
            finish(error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error ?? (receivedResponse ? nil : UpdateCheckError.downloadFailed))
    }

    private func finish(error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        var failure = error
        do {
            try file?.close()
        } catch {
            failure = failure ?? error
        }
        file = nil
        if let failure {
            task?.cancel()
            session?.invalidateAndCancel()
            if ownsDestination {
                try? fileManager.removeItem(at: destinationURL)
            }
            continuation.resume(throwing: failure)
        } else {
            session?.finishTasksAndInvalidate()
            continuation.resume()
        }
        task = nil
        session = nil
    }
}
