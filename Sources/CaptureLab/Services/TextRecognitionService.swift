import CoreGraphics
import Foundation
import Vision

struct TextRecognitionService {
    static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    static func resolvedLanguages(_ preferred: [String], supported: [String]) -> [String] {
        let requested = preferred.isEmpty ? ["zh-Hans", "zh-Hant", "en-US"] : preferred
        return Array(NSOrderedSet(array: requested.filter { supported.contains($0) })) as? [String] ?? []
    }

    func recognizeText(in image: CGImage, languages: [String] = []) throws -> OCRResult {
        let request = try textRequest(languages: languages)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return Self.result(request)
    }

    private func textRequest(languages: [String]) throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = Self.resolvedLanguages(languages, supported: try request.supportedRecognitionLanguages())
        request.automaticallyDetectsLanguage = true
        return request
    }

    func recognizeTextAsync(in image: CGImage, languages: [String]) async throws -> OCRResult {
        let request = try textRequest(languages: languages)
        try await perform(request, image: image)
        return Self.result(request)
    }

    func recognizeQRCodes(in image: CGImage) async throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try await perform(request, image: image)
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var seen = Set<String>()
        return observations.compactMap(\.payloadStringValue).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func result(_ request: VNRecognizeTextRequest) -> OCRResult {
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return OCRResult(text: lines.joined(separator: "\n"), lineCount: lines.count, createdAt: Date())
    }

    private func perform(_ request: VNRequest, image: CGImage) async throws {
        let operation = VisionOperation(request: request, image: image)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
            try Task.checkCancellation()
        } onCancel: { operation.cancel() }
    }
}

private final class VisionOperation: @unchecked Sendable {
    private let request: VNRequest
    private let image: CGImage
    private let lock = NSLock()
    private var cancelled = false
    init(request: VNRequest, image: CGImage) { self.request = request; self.image = image }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        request.cancel()
    }
    func run() throws {
        lock.lock(); let shouldCancel = cancelled; lock.unlock()
        guard !shouldCancel else { throw CancellationError() }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }
}
