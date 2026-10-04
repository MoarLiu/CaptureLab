import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class ReviewRemediationTests: XCTestCase {
    func testOCRReceivesExportPixelsIncludingRedactionsLayersCropRotationAndPresentation() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        var recognizedImage: CGImage?
        let model = fixture.model(textRecognition: { image in
            recognizedImage = image
            return OCRResult(text: "visible text", lineCount: 1, createdAt: Date())
        })
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        XCTAssertTrue(model.addImageResources([(try fixture.imageData(), "Layer")]))
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
        model.addAnnotation(CaptureAnnotation(kind: .mosaic, normalizedRect: rect))
        model.addAnnotation(CaptureAnnotation(kind: .blur, normalizedRect: rect,
                                              appearance: .init(blurRadius: 15)))
        let source = try XCTUnwrap(model.document)
        let composition = try XCTUnwrap(CaptureLayerComposition.render(source: source.image, layers: source.imageLayers))
        let masked = try XCTUnwrap(composition.renderedWithCaptureLabAnnotations(model.annotations))
        XCTAssertNotEqual(try Self.pixels(masked), try Self.pixels(composition))
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(model.applyCrop())
        model.adjustImage(.rotateClockwise)
        var presentation = CapturePresentation()
        presentation.padding = 8
        model.applyPresentation(presentation)
        let expected = try XCTUnwrap(model.renderedSnapshot()?.image)
        model.recognizeText()
        await waitUntil { !model.isRecognizingText }
        let actual = NSImage(cgImage: try XCTUnwrap(recognizedImage), size: .zero)
        XCTAssertEqual(actual.captureLabPixelSize, expected.captureLabPixelSize)
        XCTAssertEqual(try Self.pixels(actual), try Self.pixels(expected))
    }

    func testFailedOCRRenderingDoesNotRecognizeOriginalOrLeaveOldText() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        var failures = 0
        let model = fixture.model(textRecognition: { _ in
            XCTFail("Rendering failure must not reach OCR")
            throw CancellationError()
        }, imageRenderer: { _, _ in nil }, failure: { _, _ in failures += 1 })
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        model.addAnnotation(CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        model.ocrText = "previous unmasked result"
        model.recognizeText()
        XCTAssertFalse(model.isRecognizingText)
        XCTAssertTrue(model.ocrText.isEmpty)
        XCTAssertEqual(failures, 1)
    }

    func testAddingRedactionClearsExistingRecognitionText() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        model.ocrText = "secret from earlier recognition"
        model.addAnnotation(CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        XCTAssertTrue(model.ocrText.isEmpty)
    }

    func testFilledShapeChangesAndUndoCannotLeavePreviousOCRText() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        for annotation in [
            CaptureAnnotation(kind: .filledRectangle, normalizedRect: rect),
            CaptureAnnotation(kind: .rectangle, normalizedRect: rect, appearance: .init(shapeFill: .fill)),
            CaptureAnnotation(kind: .ellipse, normalizedRect: rect, appearance: .init(shapeFill: .strokeAndFill))
        ] {
            let model = fixture.model()
            XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
            model.ocrText = "previous uncovered text"
            model.addAnnotation(annotation)
            XCTAssertTrue(model.ocrText.isEmpty)
            model.ocrText = "text from covered image"
            model.undoAnnotation()
            XCTAssertTrue(model.ocrText.isEmpty)
            model.ocrText = "text from restored image"
            model.redoAnnotation()
            XCTAssertTrue(model.ocrText.isEmpty)
        }
    }

    func testCancelledQuitNeverStartsUpdateOrReplaysItOnLaterQuit() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let model = fixture.model(pngRenderer: { _, _ in nil })
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        var installationCount = 0
        model.requestUpdateInstallation({ installationCount += 1 }, terminate: {
            XCTAssertFalse(model.prepareForTermination())
        })
        XCTAssertEqual(installationCount, 0)
        XCTAssertNotNil(model.document)
        model.clearDocument()
        XCTAssertTrue(model.prepareForTermination())
        XCTAssertEqual(installationCount, 0)
    }

    func testUpdateStartsOnlyAfterRecoverySaveAndLaunchFailureCancelsQuit() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        var installationCount = 0
        model.requestUpdateInstallation({
            installationCount += 1
            XCTAssertEqual(model.historyStore.items.count, 1)
            XCTAssertNotNil(model.historyStore.items.first?.projectFileName)
            throw UpdateInstallError.installerLaunchFailed("fixture failure")
        }, terminate: {
            XCTAssertFalse(model.prepareForTermination())
        })
        XCTAssertEqual(installationCount, 1)
        XCTAssertNotNil(model.document)
        XCTAssertTrue(model.prepareForTermination())
        XCTAssertEqual(installationCount, 1)
    }

    func testUpdateGateBlocksCaptureAndLauncherAndResumesAfterFailure() async throws {
        _ = NSApplication.shared
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailedUpdateProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = UpdateCheckService(session: session)
        var captures = 0
        var launchers = 0
        let model = fixture.model(capture: { _ in captures += 1; throw CaptureLabError.captureCancelled }, updateService: service)
        model.presentCaptureLauncher = { launchers += 1 }
        model.checkForUpdates()
        XCTAssertTrue(model.isCheckingForUpdates)
        model.performCaptureAction(.launcher)
        model.capture(.fullScreen)
        XCTAssertFalse(model.isCapturing)
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(launchers, 0)
        await waitUntil { !model.isCheckingForUpdates }
        model.performCaptureAction(.launcher)
        XCTAssertEqual(launchers, 1)
        model.capture(.fullScreen)
        await waitUntil { !model.isCapturing }
        XCTAssertEqual(captures, 1)
    }

    func testOffMainWindowDelegateIntrospectionDoesNotAssumeMainActor() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let coordinator = CaptureDocumentCloseGuard.Coordinator(model: fixture.model())
        let selector = NSSelectorFromString("reviewFixtureUnknownSelector:")
        let result = await Task.detached {
            !coordinator.responds(to: selector) && coordinator.forwardingTarget(for: selector) == nil
        }.value
        XCTAssertTrue(result)
    }

    func testFinderMultiProjectOpenPreservesPreviousEditableProjectInHistory() throws {
        _ = NSApplication.shared
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let image = try XCTUnwrap(NSImage(data: fixture.imageData()))
        let document = CaptureDocument(image: image, sourceURL: nil, createdAt: Date())
        let first = fixture.root.appendingPathComponent("first.capturelab")
        let second = fixture.root.appendingPathComponent("second.capturelab")
        let firstAnnotation = CaptureAnnotation.text(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.2), text: "First project")
        let secondAnnotation = CaptureAnnotation.text(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.2), text: "Second project")
        try CaptureProjectStore.write(CaptureProjectStore.encode(document: document, annotations: [firstAnnotation]), to: first)
        try CaptureProjectStore.write(CaptureProjectStore.encode(document: document, annotations: [secondAnnotation]), to: second)
        let model = fixture.model()
        let previousModel = CaptureLabAppDelegate.documentModel
        defer { CaptureLabAppDelegate.documentModel = previousModel }
        CaptureLabAppDelegate.documentModel = model
        var presentations = 0
        model.presentEditor = { presentations += 1 }
        CaptureLabAppDelegate().application(NSApplication.shared, open: [first, second])
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(model.annotations, [secondAnnotation])
        let item = try XCTUnwrap(model.historyStore.items.first)
        let saved = try CaptureProjectStore.decode(XCTUnwrap(model.historyStore.editableSnapshot(for: item).project))
        XCTAssertEqual(saved.annotations, [firstAnnotation])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    private static func pixels(_ image: NSImage) throws -> Data {
        let cgImage = try XCTUnwrap(image.captureLabCGImage())
        let context = try XCTUnwrap(CGContext(data: nil, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return Data(bytes: try XCTUnwrap(context.data), count: cgImage.width * cgImage.height * 4)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out")
    }
}

@MainActor
private struct ReviewFixture {
    let root: URL
    let history: CaptureHistoryStore
    let settings: CloudflareR2SettingsStore
    let pasteboard = NSPasteboard(name: .init("ReviewRemediationTests.\(UUID().uuidString)"))
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLabReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ["HOME": root.path]
        history = CaptureHistoryStore(environment: environment)
        settings = CloudflareR2SettingsStore(environment: environment, secretStore: ReviewSecretStore())
    }
    func model(
        textRecognition: @escaping CaptureLabViewModel.TextRecognitionOperation = { _ in throw CancellationError() },
        imageRenderer: @escaping CaptureLabViewModel.ImageRenderingOperation = CaptureLabViewModel.defaultImageRenderingOperation,
        pngRenderer: @escaping CaptureLabViewModel.PNGDataRenderingOperation = CaptureLabViewModel.defaultPNGDataRenderingOperation,
        failure: @escaping CaptureLabViewModel.FailurePresentationOperation = { _, _ in },
        capture: @escaping CaptureLabViewModel.CaptureOperation = { _ in throw CaptureLabError.captureCancelled },
        updateService: UpdateCheckService = UpdateCheckService()
    ) -> CaptureLabViewModel {
        CaptureLabViewModel(r2SettingsStore: settings, historyStore: history, failurePresentationOperation: failure,
            pasteboard: pasteboard, captureOperation: capture, textRecognitionOperation: textRecognition,
            imageRenderingOperation: imageRenderer, pngDataRenderingOperation: pngRenderer, updateCheckService: updateService)
    }
    func imageData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<60 {
            for x in 0..<80 {
                let value = CGFloat((x * 31 + y * 17) % 255) / 255
                context.setFillColor(CGColor(red: value, green: 1 - value, blue: value, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .zero)
        return try XCTUnwrap(image.captureLabPNGData())
    }
    func remove() {
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ReviewSecretStore: CloudflareR2SecretStoring {
    func secret(for accessKeyID: String) throws -> String? { nil }
    func setSecret(_ secret: String, for accessKeyID: String) throws {}
    func deleteSecret(for accessKeyID: String) throws {}
}

private final class FailedUpdateProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
