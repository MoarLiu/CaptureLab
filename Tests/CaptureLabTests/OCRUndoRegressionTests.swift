import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class OCRUndoRegressionTests: XCTestCase {
    func testAnnotationUndoAndRedoPreserveManuallyCorrectedOCRText() throws {
        let fixture = try OCRUndoFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.openHistoryItem(fixture.item)
        let sourceID = model.document?.id
        let annotation = Self.annotation
        model.addAnnotation(annotation)
        model.ocrText = "Manually corrected text\nSecond line"

        model.undoAnnotation()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertEqual(model.document?.id, sourceID)
        XCTAssertEqual(model.ocrText, "Manually corrected text\nSecond line")
        model.ocrText = "Additional correction after undo"

        model.redoAnnotation()

        XCTAssertEqual(model.annotations, [annotation])
        XCTAssertEqual(model.document?.id, sourceID)
        XCTAssertEqual(model.ocrText, "Additional correction after undo")
    }

    func testAnnotationUndoAndRedoRejectPendingRenderedRecognitionAndAllowNewRequest() async throws {
        let fixture = try OCRUndoFixture()
        defer { fixture.remove() }
        let recognition = OCRUndoPendingOperation<OCRResult>()
        let model = fixture.makeModel(textRecognitionOperation: { _ in try await recognition.call() })
        model.openHistoryItem(fixture.item)
        model.addAnnotation(Self.annotation)
        model.recognizeText()
        await waitUntil { recognition.pendingCount == 1 }

        model.undoAnnotation()
        XCTAssertFalse(model.isRecognizingText)
        model.redoAnnotation()
        XCTAssertFalse(model.isRecognizingText)
        model.recognizeText()
        await waitUntil { recognition.pendingCount == 2 }
        recognition.completeNext(with: Self.ocrResult("Stale rendered text"))
        await waitUntil { recognition.completedCount == 1 }
        XCTAssertTrue(model.ocrText.isEmpty)
        XCTAssertTrue(model.isRecognizingText)
        recognition.completeNext(with: Self.ocrResult("Current rendered text"))
        await waitUntil { !model.isRecognizingText }

        XCTAssertEqual(model.ocrText, "Current rendered text")
    }

    func testAnnotationUndoAndRedoKeepFrozenUploadValid() async throws {
        let fixture = try OCRUndoFixture()
        defer { fixture.remove() }
        let upload = OCRUndoPendingOperation<CloudflareR2UploadResult>()
        var uploadedData: Data?
        var callbackURL: String?
        let model = fixture.makeModel(uploadOperation: { request in
            uploadedData = request.data
            return try await upload.call()
        })
        model.openHistoryItem(fixture.item)
        model.addAnnotation(Self.annotation)
        let renderedAtUpload = try XCTUnwrap(model.document?.image.captureLabPNGData(annotations: model.annotations))
        model.uploadRenderedImage { callbackURL = $0 }
        await waitUntil { upload.pendingCount == 1 }

        model.undoAnnotation()
        XCTAssertTrue(model.isUploading)
        model.redoAnnotation()
        XCTAssertTrue(model.isUploading)
        // The pending upload shares its original rendered bytes even if the
        // editor moves to another annotation state before it completes.
        model.undoAnnotation()
        XCTAssertTrue(model.isUploading)
        let url = "https://example.com/frozen-annotation.png"
        upload.completeNext(with: Self.uploadResult(url))
        await waitUntil { !model.isUploading }

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertEqual(uploadedData, renderedAtUpload)
        XCTAssertEqual(callbackURL, url)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), url)
    }

    func testCropUndoAndRedoClearOCRAndRejectLateResultsWithoutCancellingNewRequests() async throws {
        let fixture = try OCRUndoFixture()
        defer { fixture.remove() }
        let recognition = OCRUndoPendingOperation<OCRResult>()
        let upload = OCRUndoPendingOperation<CloudflareR2UploadResult>()
        var uploadedURLs: [String] = []
        let model = fixture.makeModel(
            textRecognitionOperation: { _ in try await recognition.call() },
            uploadOperation: { _ in try await upload.call() }
        )
        model.openHistoryItem(fixture.item)
        let originalID = try XCTUnwrap(model.document?.id)
        model.cropSelection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertTrue(model.applyCrop())
        let croppedID = try XCTUnwrap(model.document?.id)
        XCTAssertNotEqual(originalID, croppedID)

        for isUndo in [true, false] {
            model.ocrText = "Corrections belonging to the outgoing source"
            model.recognizeText()
            model.uploadRenderedImage { uploadedURLs.append($0) }
            await waitUntil { recognition.pendingCount == 1 && upload.pendingCount == 1 }
            fixture.pasteboard.clearContents()
            fixture.pasteboard.setString("Keep this clipboard", forType: .string)

            if isUndo { model.undoAnnotation() } else { model.redoAnnotation() }

            XCTAssertEqual(model.document?.id, isUndo ? originalID : croppedID)
            XCTAssertEqual(model.document?.pixelSize, isUndo ? CGSize(width: 64, height: 48) : CGSize(width: 32, height: 24))
            XCTAssertTrue(model.ocrText.isEmpty)
            XCTAssertFalse(model.isRecognizingText)
            XCTAssertFalse(model.isUploading)

            // New requests for the restored source must also survive the late
            // completion of requests cancelled by the crop history transition.
            model.recognizeText()
            model.uploadRenderedImage { uploadedURLs.append($0) }
            await waitUntil { recognition.pendingCount == 2 && upload.pendingCount == 2 }
            let oldRecognitionCount = recognition.completedCount
            let oldUploadCount = upload.completedCount
            recognition.completeNext(with: Self.ocrResult("Stale text"))
            upload.completeNext(with: Self.uploadResult("https://example.com/stale.png"))
            await waitUntil {
                recognition.completedCount == oldRecognitionCount + 1 && upload.completedCount == oldUploadCount + 1
            }
            await Task.yield()
            await Task.yield()

            XCTAssertTrue(model.ocrText.isEmpty)
            XCTAssertTrue(model.isRecognizingText)
            XCTAssertTrue(model.isUploading)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Keep this clipboard")
            XCTAssertEqual(uploadedURLs.count, isUndo ? 0 : 1)

            let newText = isUndo ? "Original source text" : "Cropped source text"
            let newURL = isUndo ? "https://example.com/original.png" : "https://example.com/cropped.png"
            recognition.completeNext(with: Self.ocrResult(newText))
            upload.completeNext(with: Self.uploadResult(newURL))
            await waitUntil { !model.isRecognizingText && !model.isUploading }

            XCTAssertEqual(model.ocrText, newText)
            XCTAssertEqual(uploadedURLs.last, newURL)
            XCTAssertEqual(uploadedURLs.count, isUndo ? 1 : 2)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), newURL)
        }
    }

    private static var annotation: CaptureAnnotation {
        CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
    }

    private static func ocrResult(_ text: String) -> OCRResult {
        OCRResult(text: text, lineCount: 1, createdAt: Date())
    }

    private static func uploadResult(_ url: String) -> CloudflareR2UploadResult {
        CloudflareR2UploadResult(url: url, objectKey: "result.png", sizeBytes: 1)
    }

    private func waitUntil(condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the controlled operation")
    }
}

@MainActor
private final class OCRUndoPendingOperation<Value: Sendable> {
    private var pending: [CheckedContinuation<Value, Error>] = []
    private(set) var completedCount = 0
    var pendingCount: Int { pending.count }

    func call() async throws -> Value {
        let value: Value = try await withCheckedThrowingContinuation { pending.append($0) }
        completedCount += 1
        return value
    }

    func completeNext(with value: Value) {
        guard !pending.isEmpty else {
            XCTFail("No controlled operation is waiting")
            return
        }
        pending.removeFirst().resume(returning: value)
    }
}

@MainActor
private struct OCRUndoFixture {
    let home: URL
    let settings: CloudflareR2SettingsStore
    let history: CaptureHistoryStore
    let pasteboard: NSPasteboard
    let item: CaptureHistoryItem

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("OCRUndoRegressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ["HOME": home.path]
        settings = CloudflareR2SettingsStore(environment: environment, secretStore: OCRUndoInMemorySecretStore())
        try settings.save(CloudflareR2SettingsInput(
            endpoint: "https://account.r2.cloudflarestorage.com", bucket: "test-bucket", pathPrefix: "captures",
            publicBaseURL: "https://example.com", accessKeyID: "test-access", secretAccessKey: "test-secret"
        ))
        history = CaptureHistoryStore(environment: environment)
        pasteboard = NSPasteboard(name: .init("OCRUndoRegressionTests.\(UUID().uuidString)"))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 64, height: 48))
        item = try history.record(data: XCTUnwrap(image.captureLabPNGData()), pixelSize: CGSize(width: 64, height: 48))
    }

    func makeModel(
        textRecognitionOperation: @escaping CaptureLabViewModel.TextRecognitionOperation = { _ in XCTFail("Unexpected OCR"); throw CancellationError() },
        uploadOperation: @escaping CaptureLabViewModel.UploadOperation = { _ in XCTFail("Unexpected upload"); throw CancellationError() }
    ) -> CaptureLabViewModel {
        CaptureLabViewModel(
            r2SettingsStore: settings, historyStore: history,
            failurePresentationOperation: { title, message in XCTFail("Unexpected failure: \(title): \(message)") },
            pasteboard: pasteboard,
            textRecognitionOperation: textRecognitionOperation,
            uploadOperation: uploadOperation
        )
    }

    func remove() {
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: home)
    }
}

private final class OCRUndoInMemorySecretStore: CloudflareR2SecretStoring {
    private var secrets: [String: String] = [:]
    func secret(for accessKeyID: String) throws -> String? { secrets[accessKeyID] }
    func setSecret(_ secret: String, for accessKeyID: String) throws { secrets[accessKeyID] = secret }
    func deleteSecret(for accessKeyID: String) throws { secrets.removeValue(forKey: accessKeyID) }
}
