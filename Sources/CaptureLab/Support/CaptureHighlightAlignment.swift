import CoreGraphics
import Vision

/// Text rectangles use the same top-left normalized coordinates as annotations.
enum CaptureHighlightAlignment {
    static func recognizeRegions(in image: CGImage, languages: [String] = []) async throws -> [CGRect] {
        let operation = HighlightRecognitionOperation(image: image, languages: languages)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let regions = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
            try Task.checkCancellation()
            return regions
        } onCancel: { operation.cancel() }
    }

    static func alignedRect(_ proposed: CGRect, textRegions: [CGRect]) -> CGRect {
        // Snap only a nearby intersecting line. Crossing multiple lines keeps the
        // manual rectangle instead of producing a misleading single-line match.
        let matches = textRegions.filter {
            let overlap = proposed.intersection($0)
            return !overlap.isNull && overlap.width > 0 && overlap.height >= min(proposed.height, $0.height) * 0.25
        }
        guard matches.count == 1, let match = matches.first else { return proposed }
        return CGRect(x: proposed.minX, y: match.minY - match.height * 0.08,
                      width: proposed.width, height: match.height * 1.16).clampedToUnit()
    }
}

private final class HighlightRecognitionOperation: @unchecked Sendable {
    private let image: CGImage
    private let languages: [String]
    private let request = VNRecognizeTextRequest()
    private let lock = NSLock()
    private var cancelled = false
    init(image: CGImage, languages: [String]) { self.image = image; self.languages = languages }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); request.cancel() }
    func run() throws -> [CGRect] {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw CancellationError() }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = TextRecognitionService.resolvedLanguages(languages, supported: try request.supportedRecognitionLanguages())
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).filter { $0.topCandidates(1).first != nil }.map {
            CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height).clampedToUnit()
        }
    }
}
