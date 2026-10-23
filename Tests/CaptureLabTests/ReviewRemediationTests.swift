import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class ReviewRemediationTests: XCTestCase {
    func testLinkedDataRootPreservesHistoryPresetsAndNormalTermination() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let environment = ["HOME": fixture.root.path]
        let support = CaptureLabDataRoot.supportDirectory(environment: environment)
        let relocated = fixture.root.appendingPathComponent("relocated-data")
        try FileManager.default.moveItem(at: support, to: relocated)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: relocated)
        let history = CaptureHistoryStore(environment: environment)
        XCTAssertNil(history.loadError)
        let item = try history.record(data: fixture.imageData(), pixelSize: CGSize(width: 80, height: 60))
        let model = CaptureLabViewModel(r2SettingsStore: fixture.settings, historyStore: history,
            failurePresentationOperation: { _, message in XCTFail(message) }, pasteboard: fixture.pasteboard)
        model.openHistoryItem(item)
        model.addAnnotation(.init(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        let annotations = model.annotations
        XCTAssertTrue(model.prepareForTermination())
        let reopened = CaptureHistoryStore(environment: environment)
        let saved = try reopened.editableSnapshot(for: item)
        XCTAssertEqual(try CaptureProjectStore.decode(XCTUnwrap(saved.project)).annotations, annotations)
        XCTAssertEqual(reopened.historyDirectory, relocated.appendingPathComponent("History").resolvingSymlinksInPath())
        let presets = CapturePresentationStore(environment: environment)
        let preset = try presets.save(name: "Linked root", presentation: .init())
        XCTAssertEqual(CapturePresentationStore(environment: environment).presets, [preset])
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.appendingPathComponent("presentation-presets.json").path))
    }

    func testSmallScaleMosaicPreviewsMatchExactEffectBeforeDownsampling() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        for size in [CGSize(width: 600, height: 360), CGSize(width: 120, height: 900)] {
            let model = fixture.model()
            XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData(width: Int(size.width), height: Int(size.height)))))
            XCTAssertTrue(model.addImageResources([(try fixture.imageData(), "Synthetic layer")]))
            model.addAnnotation(.init(kind: .mosaic, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)))
            model.addAnnotation(.init(kind: .blur, normalizedRect: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4)))
            model.adjustImage(.rotateClockwise)
            var presentation = CapturePresentation()
            presentation.padding = 12
            model.applyPresentation(presentation)
            let document = try XCTUnwrap(model.document)
            let exact = try XCTUnwrap(model.renderedPreviewImage())
            let exactContent = try XCTUnwrap(model.renderedContentImage())
            let renderer = CaptureCompositionPreviewRenderer()
            let maximum = max(size.width, size.height, exact.captureLabPixelSize.width, exact.captureLabPixelSize.height)
            for ratio in [CGFloat(1), 0.5, 0.25, 0.24, 0.1] {
                let limit = max(1, Int(maximum * ratio))
                let output = try XCTUnwrap(model.renderedPreviewImage(maximumDimension: limit))
                XCTAssertEqual(try Self.pixels(output), try Self.pixels(downsample(exact, to: output.captureLabPixelSize)), "Output scale \(ratio)")
                XCTAssertEqual(output.size, exact.size)
                let objects = try XCTUnwrap(renderer.render(document: document, layers: document.imageLayers,
                    annotations: model.annotations, maximumDimension: limit))
                XCTAssertEqual(try Self.pixels(objects), try Self.pixels(downsample(exactContent, to: objects.captureLabPixelSize)), "Object scale \(ratio)")
                XCTAssertLessThanOrEqual(output.captureLabPixelSize.width * output.captureLabPixelSize.height,
                                         CaptureCompositionPreviewRenderer.maximumPixels)
            }
        }
    }

    private func downsample(_ image: NSImage, to size: CGSize) throws -> NSImage {
        let source = try XCTUnwrap(image.captureLabCGImage())
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: size))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: image.size)
    }

    func testDisplayPreviewDoesNotEncodeOrCommitTextAndExactOutputMatchesIt() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        var encodings = 0
        let model = fixture.model(pngRenderer: { image, annotations in
            encodings += 1
            XCTAssertTrue(annotations.isEmpty)
            return image.captureLabPNGData()
        })
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        model.addAnnotation(.init(kind: .mosaic, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        model.adjustImage(.rotateClockwise)
        var presentation = CapturePresentation()
        presentation.padding = 8
        model.applyPresentation(presentation)
        let owner = NSObject()
        var textCommits = 0
        CaptureEditingSession.shared.registerPendingTextCommitter(owner: owner) { textCommits += 1 }
        defer { CaptureEditingSession.shared.unregisterPendingTextCommitter(owner: owner) }
        let preview = try XCTUnwrap(model.renderedPreviewImage())
        XCTAssertNotNil(model.renderedPreviewImage(maximumDimension: 1024))
        XCTAssertEqual(encodings, 0)
        XCTAssertEqual(textCommits, 0)
        let output = try XCTUnwrap(model.renderedSnapshot()?.image)
        XCTAssertEqual(encodings, 1)
        XCTAssertEqual(try Self.pixels(preview), try Self.pixels(output))
    }

    func testHistoryReadsDoNotRepublishIdenticalItemsOrInvalidateOtherThumbnails() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let item = try fixture.history.record(data: fixture.imageData(), pixelSize: CGSize(width: 80, height: 60))
        let model = fixture.model()
        var publications = 0
        let subscription = model.$historyItems.sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let identity = CaptureHistoryThumbnailIdentity(id: item.id, url: fixture.history.url(for: item), modifiedAt: item.modifiedAt)
        model.copyHistoryItem(item)
        XCTAssertNotNil(model.snapshot(for: item))
        model.refreshHistory()
        XCTAssertEqual(publications, 1)
        _ = try fixture.history.record(data: fixture.imageData(), pixelSize: item.pixelSize)
        model.refreshHistory()
        XCTAssertEqual(publications, 2)
        let unchanged = try XCTUnwrap(model.historyItems.first { $0.id == item.id })
        XCTAssertEqual(identity, CaptureHistoryThumbnailIdentity(id: unchanged.id,
            url: fixture.history.url(for: unchanged), modifiedAt: unchanged.modifiedAt))
    }

    func testBusyQuitAndReplacementPreserveEditsAndDoNotReplayUpdate() throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        XCTAssertTrue(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        model.addAnnotation(.init(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        let id = model.document?.id
        let annotations = model.annotations
        let holder = try HistoryLockHolder(directory: fixture.history.historyDirectory)
        defer { holder.release() }
        var installations = 0
        model.requestUpdateInstallation({ installations += 1 }, terminate: {
            XCTAssertFalse(model.prepareForTermination())
        })
        XCTAssertFalse(model.openSnapshot(CaptureImageSnapshot(data: try fixture.imageData())))
        XCTAssertEqual(model.document?.id, id)
        XCTAssertEqual(model.annotations, annotations)
        XCTAssertTrue(model.canUndoAnnotation)
        XCTAssertEqual(installations, 0)
        XCTAssertTrue(holder.process.isRunning)
        holder.release()
        XCTAssertTrue(model.prepareForTermination())
        XCTAssertEqual(installations, 0)
        XCTAssertFalse(fixture.history.items.isEmpty)
        model.undoAnnotation()
        XCTAssertTrue(model.annotations.isEmpty)
    }

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
    func imageData(width: Int = 80, height: Int = 60) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<height {
            for x in 0..<width {
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
