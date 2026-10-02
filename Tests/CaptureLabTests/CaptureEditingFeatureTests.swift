import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureEditingFeatureTests: XCTestCase {
    func testSelectedAppearanceChangeIsUndoableAndLeavesOtherAnnotationsUntouched() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        let first = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let second = CaptureAnnotation.text(normalizedRect: CGRect(x: 0.5, y: 0.1, width: 0.4, height: 0.3), text: "Label")
        model.addAnnotation(first)
        model.addAnnotation(second)
        model.selectAnnotation(second.id)
        XCTAssertEqual(model.annotationAppearance, second.appearance)
        let appearance = CaptureAnnotationAppearance(
            color: CaptureAnnotationColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            lineWidth: 8,
            fontSize: 32
        )

        model.annotationAppearance = appearance

        XCTAssertEqual(model.annotations[0], first)
        XCTAssertEqual(model.annotations[1].appearance, appearance)
        XCTAssertEqual(model.annotations[1].id, second.id)
        XCTAssertEqual(model.annotations[1].text, "Label")
        model.undoAnnotation()
        XCTAssertEqual(model.annotations, [first, second])
        XCTAssertTrue(model.canRedoAnnotation)
        model.redoAnnotation()
        XCTAssertEqual(model.annotations[0], first)
        XCTAssertEqual(model.annotations[1].appearance, appearance)
        XCTAssertFalse(model.canRedoAnnotation)
    }

    func testSelectingAnnotationDoesNotCreateHistoryAndUnselectedAppearanceDoesNotEditImage() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        let annotation = Self.rectangle
        model.addAnnotation(annotation)
        model.selectAnnotation(annotation.id)
        model.selectAnnotation(nil)
        model.annotationAppearance = CaptureAnnotationAppearance(lineWidth: 12, fontSize: 48)

        XCTAssertEqual(model.annotations, [annotation])
        model.undoAnnotation()
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
        model.redoAnnotation()
        XCTAssertEqual(model.annotations, [annotation])
    }

    func testIncreasingSelectedTextFontExpandsBoundsAndUndoRestoresOriginalGeometry() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.openHistoryItem(try fixture.record(Self.makeImage(width: 640, height: 480)))
        var original = CaptureAnnotation.text(
            normalizedRect: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.1),
            text: "Font test"
        )
        original.appearance = CaptureAnnotationAppearance(fontSize: 24)
        model.addAnnotation(original)
        model.selectAnnotation(original.id)

        model.annotationAppearance.fontSize = 96

        let enlarged = try XCTUnwrap(model.annotations.first)
        XCTAssertEqual(enlarged.id, original.id)
        XCTAssertEqual(enlarged.text, original.text)
        XCTAssertEqual(enlarged.appearance.fontSize, 96)
        XCTAssertGreaterThan(enlarged.normalizedRect.width, original.normalizedRect.width)
        XCTAssertGreaterThan(enlarged.normalizedRect.height, original.normalizedRect.height)
        XCTAssertGreaterThanOrEqual(enlarged.normalizedRect.minX, 0)
        XCTAssertGreaterThanOrEqual(enlarged.normalizedRect.minY, 0)
        XCTAssertLessThanOrEqual(enlarged.normalizedRect.maxX, 1)
        XCTAssertLessThanOrEqual(enlarged.normalizedRect.maxY, 1)
        model.undoAnnotation()
        XCTAssertEqual(model.annotations, [original])
        model.redoAnnotation()
        XCTAssertEqual(model.annotations, [enlarged])
    }

    func testIncreasingCounterFontNearImageEdgeExpandsSquareBoundsInsideImage() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let pixelSize = CGSize(width: 640, height: 480)
        model.openHistoryItem(try fixture.record(Self.makeImage(width: 640, height: 480)))
        let original = CaptureAnnotation(
            kind: .counter,
            normalizedRect: CGRect(x: 0.94, y: 0.91, width: 0.05, height: CGFloat(32) / pixelSize.height),
            text: "12",
            appearance: CaptureAnnotationAppearance(fontSize: 24)
        )
        model.addAnnotation(original)
        model.selectAnnotation(original.id)

        model.annotationAppearance.fontSize = 96

        let enlarged = try XCTUnwrap(model.annotations.first)
        let bounds = enlarged.normalizedRect
        XCTAssertEqual(enlarged.appearance.fontSize, 96)
        XCTAssertGreaterThan(bounds.width, original.normalizedRect.width)
        XCTAssertGreaterThan(bounds.height, original.normalizedRect.height)
        XCTAssertGreaterThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.minY, 0)
        XCTAssertLessThanOrEqual(bounds.maxX, 1)
        XCTAssertLessThanOrEqual(bounds.maxY, 1)
        XCTAssertEqual(bounds.width * pixelSize.width, bounds.height * pixelSize.height, accuracy: 0.001)
    }

    func testRedoRestoresClearAndNewEditDiscardsRedoBranch() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        let annotation = Self.rectangle
        model.addAnnotation(annotation)
        model.clearAnnotations()
        model.undoAnnotation()
        XCTAssertEqual(model.annotations, [annotation])
        model.redoAnnotation()
        XCTAssertTrue(model.annotations.isEmpty)
        model.undoAnnotation()
        let replacement = CaptureAnnotation.line(start: CGPoint(x: 0.1, y: 0.8), end: CGPoint(x: 0.9, y: 0.8))
        model.addAnnotation(replacement)

        XCTAssertFalse(model.canRedoAnnotation)
        model.redoAnnotation()
        XCTAssertEqual(model.annotations, [annotation, replacement])
    }

    func testLoadingAnotherDocumentAndClearingResetBothHistoryStacks() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let first = try fixture.record(Self.makeImage())
        let second = try fixture.record(Self.makeImage())
        model.openHistoryItem(first)
        model.addAnnotation(Self.rectangle)
        model.undoAnnotation()
        XCTAssertTrue(model.canRedoAnnotation)
        model.openHistoryItem(second)

        XCTAssertFalse(model.canUndoAnnotation)
        XCTAssertFalse(model.canRedoAnnotation)
        model.redoAnnotation()
        XCTAssertTrue(model.annotations.isEmpty)
        model.addAnnotation(Self.rectangle)
        model.undoAnnotation()
        model.clearDocument()
        XCTAssertFalse(model.hasImage)
        XCTAssertFalse(model.canUndoAnnotation)
        XCTAssertFalse(model.canRedoAnnotation)
    }

    func testCropPreservesEditableMosaicAndUndoRedoRestoreDocumentAndCroppedOutput() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.openHistoryItem(try fixture.record(Self.makeImage(checkerboard: true)))
        let original = try XCTUnwrap(model.document)
        let originalPixels = try Self.pixelData(original.image)
        let mosaic = CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        model.addAnnotation(mosaic)
        model.selectedTool = .crop
        model.cropSelection = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertTrue(model.canApplyCrop)

        XCTAssertTrue(model.applyCrop())

        let cropped = try XCTUnwrap(model.document)
        let croppedOutput = try XCTUnwrap(model.renderedSnapshot()?.image)
        let croppedPixels = try Self.pixelData(croppedOutput)
        XCTAssertTrue(cropped.image === original.image)
        XCTAssertNotEqual(cropped.id, original.id)
        XCTAssertEqual(cropped.pixelSize, CGSize(width: 32, height: 24))
        XCTAssertEqual(model.annotations, [mosaic])
        XCTAssertNil(model.cropSelection)
        XCTAssertEqual(model.selectedTool, .select)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(croppedOutput.captureLabCGImage()))
        let sourceBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(original.image.captureLabCGImage()))
        let sourceLeft = try XCTUnwrap(sourceBitmap.colorAt(x: 3, y: 3))
        let sourceRight = try XCTUnwrap(sourceBitmap.colorAt(x: 4, y: 3))
        let mosaicLeft = try XCTUnwrap(bitmap.colorAt(x: 3, y: 3))
        let mosaicRight = try XCTUnwrap(bitmap.colorAt(x: 4, y: 3))
        // The original two-pixel checker changes at this boundary. A mosaic
        // block must remove that detail in the ordinary cropped output.
        XCTAssertGreaterThan(abs(sourceLeft.redComponent - sourceRight.redComponent), 0.9)
        XCTAssertEqual(mosaicLeft.redComponent, mosaicRight.redComponent, accuracy: 0.001)
        XCTAssertEqual(mosaicLeft.greenComponent, mosaicRight.greenComponent, accuracy: 0.001)
        XCTAssertEqual(mosaicLeft.blueComponent, mosaicRight.blueComponent, accuracy: 0.001)
        XCTAssertEqual(mosaicLeft.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(mosaicRight.alphaComponent, 1, accuracy: 0.001)
        model.undoAnnotation()
        XCTAssertEqual(model.document?.id, original.id)
        XCTAssertEqual(model.document?.pixelSize, original.pixelSize)
        XCTAssertEqual(try Self.pixelData(XCTUnwrap(model.document?.image)), originalPixels)
        XCTAssertEqual(model.annotations, [mosaic])
        model.redoAnnotation()
        XCTAssertEqual(model.document?.id, cropped.id)
        XCTAssertEqual(model.annotations, [mosaic])
        XCTAssertEqual(try Self.pixelData(XCTUnwrap(model.renderedSnapshot()?.image)), croppedPixels)
    }

    func testCropCommitsPendingTextBeforeRenderingAndUndoRestoresThatText() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        var renderedText: String?
        let model = fixture.makeModel(imageRenderingOperation: { image, annotations in
            renderedText = annotations.first?.text
            return image.renderedWithCaptureLabAnnotations(annotations)
        })
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        model.addAnnotation(CaptureAnnotation.text(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.5), text: "Old text"))
        let owner = NSObject()
        var committed = false
        CaptureEditingSession.shared.registerPendingTextCommitter(owner: owner) {
            guard !committed else { return }
            committed = true
            var annotations = model.annotations
            annotations[0].text = "Pending text"
            model.annotations = annotations
        }
        defer { CaptureEditingSession.shared.unregisterPendingTextCommitter(owner: owner) }
        model.cropSelection = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        XCTAssertTrue(model.applyCrop())
        XCTAssertTrue(committed)
        XCTAssertEqual(renderedText, "Pending text")
        model.undoAnnotation()
        XCTAssertEqual(model.annotations.first?.text, "Pending text")
    }

    func testFailedMosaicRenderDoesNotCropUnredactedSourceOrLoseEditsAndHistory() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        var renderedAnnotations: [CaptureAnnotation] = []
        let model = fixture.makeModel(imageRenderingOperation: { _, annotations in
            renderedAnnotations = annotations
            return nil
        })
        model.openHistoryItem(try fixture.record(Self.makeImage(checkerboard: true)))
        let original = try XCTUnwrap(model.document)
        let originalPixels = try Self.pixelData(original.image)
        let mosaic = CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        model.addAnnotation(mosaic)
        model.addAnnotation(Self.rectangle)
        model.undoAnnotation()
        XCTAssertTrue(model.canRedoAnnotation)
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        model.cropSelection = selection

        XCTAssertFalse(model.applyCrop())

        XCTAssertEqual(renderedAnnotations, [mosaic])
        XCTAssertEqual(model.document?.id, original.id)
        XCTAssertEqual(try Self.pixelData(XCTUnwrap(model.document?.image)), originalPixels)
        XCTAssertEqual(model.annotations, [mosaic])
        XCTAssertEqual(model.cropSelection, selection)
        XCTAssertTrue(model.canUndoAnnotation)
        XCTAssertTrue(model.canRedoAnnotation)
        model.redoAnnotation()
        XCTAssertEqual(model.annotations, [mosaic, Self.rectangle])
    }

    func testInvalidCropSelectionLeavesDocumentAndAnnotationsUnchanged() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        var renderCalls = 0
        let model = fixture.makeModel(imageRenderingOperation: { image, annotations in
            renderCalls += 1
            return image.renderedWithCaptureLabAnnotations(annotations)
        })
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        let documentID = model.document?.id
        model.addAnnotation(Self.rectangle)
        for selection in [CGRect.zero, CGRect(x: 2, y: 0, width: 1, height: 1), CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
            model.cropSelection = selection
            XCTAssertFalse(model.canApplyCrop)
            XCTAssertFalse(model.applyCrop())
            XCTAssertEqual(model.document?.id, documentID)
            XCTAssertEqual(model.annotations, [Self.rectangle])
        }
        XCTAssertEqual(renderCalls, 0)
    }

    func testCropCancelsLateOCRAndUploadWithoutChangingClipboardToOldURL() async throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        try fixture.settingsStore.save(CloudflareR2SettingsInput(
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "test-bucket", pathPrefix: "tests", publicBaseURL: "https://example.com",
            accessKeyID: "fixture-key", secretAccessKey: "fixture-secret"
        ))
        let ocrStarted = expectation(description: "OCR started")
        let uploadStarted = expectation(description: "upload started")
        let ocrCompleted = expectation(description: "OCR operation completed")
        let uploadCompleted = expectation(description: "upload operation completed")
        var ocrContinuation: CheckedContinuation<OCRResult, Error>?
        var uploadContinuation: CheckedContinuation<CloudflareR2UploadResult, Error>?
        let model = fixture.makeModel(
            textRecognitionOperation: { _ in
                let result = try await withCheckedThrowingContinuation { pending in
                    ocrContinuation = pending
                    ocrStarted.fulfill()
                }
                ocrCompleted.fulfill()
                return result
            },
            uploadOperation: { _ in
                let result = try await withCheckedThrowingContinuation { pending in
                    uploadContinuation = pending
                    uploadStarted.fulfill()
                }
                uploadCompleted.fulfill()
                return result
            }
        )
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        fixture.pasteboard.setString("keep-current-clipboard", forType: .string)
        model.ocrText = "old OCR"
        model.recognizeText()
        model.uploadRenderedImage()
        await fulfillment(of: [ocrStarted, uploadStarted], timeout: 2)
        model.cropSelection = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        XCTAssertTrue(model.applyCrop())
        XCTAssertFalse(model.isRecognizingText)
        XCTAssertFalse(model.isUploading)
        XCTAssertTrue(model.ocrText.isEmpty)
        ocrContinuation?.resume(returning: OCRResult(text: "stale OCR", lineCount: 1, createdAt: Date()))
        uploadContinuation?.resume(returning: CloudflareR2UploadResult(url: "https://example.com/stale.png", objectKey: "stale.png", sizeBytes: 1))
        await fulfillment(of: [ocrCompleted, uploadCompleted], timeout: 2)
        await Task.yield()

        XCTAssertTrue(model.ocrText.isEmpty)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "keep-current-clipboard")
        XCTAssertEqual(model.document?.pixelSize, CGSize(width: 32, height: 24))
        XCTAssertEqual(model.statusMessage, L10n.imageCropped)
    }

    func testPinFreezesRenderedAnnotationsAndKeepsEditingDocument() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        var pinnedImage: NSImage?
        var pinnedTitle: String?
        let model = fixture.makeModel(pinOperation: { image, title in
            pinnedImage = image
            pinnedTitle = title
        })
        model.openHistoryItem(try fixture.record(Self.makeImage(checkerboard: true)))
        model.addAnnotation(CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let originalID = model.document?.id
        let annotations = model.annotations
        let expectedPixels = try Self.pixelData(XCTUnwrap(model.document?.image.renderedWithCaptureLabAnnotations(annotations)))

        model.pinCurrentCapture()

        XCTAssertEqual(pinnedTitle, model.documentTitle)
        XCTAssertEqual(try Self.pixelData(XCTUnwrap(pinnedImage)), expectedPixels)
        XCTAssertEqual(model.document?.id, originalID)
        XCTAssertEqual(model.annotations, annotations)
        model.clearAnnotations()
        model.clearDocument()
        XCTAssertEqual(try Self.pixelData(XCTUnwrap(pinnedImage)), expectedPixels)
    }

    func testPinDoesNotShowUnredactedSourceWhenAnnotationRenderFails() throws {
        let fixture = try EditingFeatureFixture()
        defer { fixture.remove() }
        var pinCalls = 0
        let model = fixture.makeModel(
            imageRenderingOperation: { _, _ in nil },
            pinOperation: { _, _ in pinCalls += 1 }
        )
        model.openHistoryItem(try fixture.record(Self.makeImage()))
        model.addAnnotation(CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)))

        model.pinCurrentCapture()

        XCTAssertEqual(pinCalls, 0)
        XCTAssertTrue(model.hasImage)
        XCTAssertEqual(model.annotations.count, 1)
    }

    func testExplicitAppearanceMetricsScaleWithPreviewAndExportUsesSelectedColorAndWidth() throws {
        let appearance = CaptureAnnotationAppearance(
            color: CaptureAnnotationColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            lineWidth: 12,
            fontSize: 36
        )
        let export = CaptureAnnotationStyle(sourcePixelSize: CGSize(width: 200, height: 100), renderedImageSize: CGSize(width: 200, height: 100), appearance: appearance)
        let preview = CaptureAnnotationStyle(sourcePixelSize: CGSize(width: 200, height: 100), renderedImageSize: CGSize(width: 100, height: 50), appearance: appearance)
        XCTAssertEqual(export.lineWidth, 12)
        XCTAssertEqual(preview.lineWidth, 6)
        XCTAssertEqual(preview.brushWidth, export.brushWidth * 0.5)
        XCTAssertEqual(preview.arrowHeadLength, export.arrowHeadLength * 0.5)
        XCTAssertEqual(export.textFontSize(for: CGRect(x: 0, y: 0, width: 100, height: 10)), 36)
        XCTAssertEqual(preview.textFontSize(for: CGRect(x: 0, y: 0, width: 50, height: 5)), 18)
        XCTAssertEqual(preview.counterFontSize(for: 40), 18)
        XCTAssertLessThan(preview.counterFontSize(for: 20), 18)
        XCTAssertEqual(preview.counterFontSize(for: 20), export.counterFontSize(for: 40) * 0.5, accuracy: 0.0001)
        XCTAssertEqual(preview.highlightColor.greenComponent, 1)
        var line = CaptureAnnotation.line(start: CGPoint(x: 0.2, y: 0.5), end: CGPoint(x: 0.8, y: 0.5))
        line.appearance = appearance
        let source = try Self.makeImage(width: 200, height: 100)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(source.captureLabPNGData(annotations: [line]))))
        let center = try XCTUnwrap(bitmap.colorAt(x: 100, y: 50))
        let innerEdge = try XCTUnwrap(bitmap.colorAt(x: 100, y: 54))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 100, y: 60))
        XCTAssertEqual(center.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(center.redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(innerEdge.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(outside.greenComponent, 0, accuracy: 0.01)
    }

    private static let rectangle = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))

    private static func makeImage(width: Int = 64, height: Int = 48, checkerboard: Bool = false) throws -> NSImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value: UInt8 = checkerboard && ((x / 2).isMultiple(of: 2) == (y / 2).isMultiple(of: 2)) ? 255 : 0
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let source = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return NSImage(cgImage: source, size: CGSize(width: width, height: height))
    }

    private static func pixelData(_ image: NSImage) throws -> Data {
        let source = try XCTUnwrap(image.captureLabCGImage())
        let context = try XCTUnwrap(CGContext(
            data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return Data(bytes: try XCTUnwrap(context.data), count: source.width * source.height * 4)
    }
}

@MainActor
private struct EditingFeatureFixture {
    let home: URL
    let historyStore: CaptureHistoryStore
    let settingsStore: CloudflareR2SettingsStore
    let pasteboard: NSPasteboard

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureEditingFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ["HOME": home.path]
        historyStore = CaptureHistoryStore(environment: environment)
        settingsStore = CloudflareR2SettingsStore(environment: environment, secretStore: EditingFeatureSecretStore())
        pasteboard = NSPasteboard(name: .init("CaptureEditingFeatureTests.\(UUID().uuidString)"))
    }

    func remove() {
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: home)
    }

    func record(_ image: NSImage) throws -> CaptureHistoryItem {
        try historyStore.record(data: XCTUnwrap(image.captureLabPNGData()), pixelSize: image.captureLabPixelSize)
    }

    func makeModel(
        textRecognitionOperation: @escaping CaptureLabViewModel.TextRecognitionOperation = { _ in throw CancellationError() },
        uploadOperation: @escaping CaptureLabViewModel.UploadOperation = { _ in throw CancellationError() },
        imageRenderingOperation: @escaping CaptureLabViewModel.ImageRenderingOperation = { image, annotations in image.renderedWithCaptureLabAnnotations(annotations) },
        pinOperation: @escaping CaptureLabViewModel.PinOperation = { _, _ in }
    ) -> CaptureLabViewModel {
        CaptureLabViewModel(
            r2SettingsStore: settingsStore,
            historyStore: historyStore,
            failurePresentationOperation: { _, _ in },
            pasteboard: pasteboard,
            captureOperation: { _ in throw CancellationError() },
            textRecognitionOperation: textRecognitionOperation,
            uploadOperation: uploadOperation,
            imageRenderingOperation: imageRenderingOperation,
            saveDestinationOperation: { _ in nil },
            pinOperation: pinOperation
        )
    }
}

private final class EditingFeatureSecretStore: CloudflareR2SecretStoring {
    private var secrets: [String: String] = [:]

    func secret(for accessKeyID: String) throws -> String? { secrets[accessKeyID] }
    func setSecret(_ secret: String, for accessKeyID: String) throws { secrets[accessKeyID] = secret }
    func deleteSecret(for accessKeyID: String) throws { secrets.removeValue(forKey: accessKeyID) }
}
