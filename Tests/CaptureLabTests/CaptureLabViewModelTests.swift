import AppKit
import CoreGraphics
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureLabViewModelTests: XCTestCase {
    func testCaptureHidesWindowsWaitsForWindowServerRestoresAndDeletesTemporaryFile() async throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let pasteboard = NSPasteboard(name: .init("CaptureLabViewModelTests.capture.\(UUID().uuidString)"))
        let coordinator = TestCaptureWindowVisibilityCoordinator()
        let captureURL = fixture.home.appendingPathComponent("capture.png")
        try XCTUnwrap(Self.fixtureImage().captureLabPNGData()).write(to: captureURL)
        let captureCompleted = expectation(description: "capture completed")
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pasteboard: pasteboard,
            windowVisibilityCoordinator: coordinator,
            captureOperation: { mode in
                XCTAssertEqual(mode, .fullScreen)
                coordinator.events.append("capture")
                return captureURL
            }
        )

        model.capture(.fullScreen) {
            captureCompleted.fulfill()
        }
        await fulfillment(of: [captureCompleted], timeout: 2)
        await Task.yield()

        XCTAssertEqual(coordinator.events, ["hide", "wait", "capture", "restore"])
        XCTAssertTrue(model.hasImage)
        XCTAssertFalse(model.isCapturing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testCompletedCaptureDeletesTemporaryFileAfterViewModelIsReleased() async throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let captureURL = fixture.home.appendingPathComponent("orphaned-capture.png")
        try Data("temporary capture".utf8).write(to: captureURL)
        let captureStarted = expectation(description: "capture started")
        var captureContinuation: CheckedContinuation<URL, Never>?
        var model: CaptureLabViewModel? = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: CaptureHistoryStore(environment: fixture.environment),
            windowVisibilityCoordinator: TestCaptureWindowVisibilityCoordinator(),
            captureOperation: { _ in
                await withCheckedContinuation { continuation in
                    captureContinuation = continuation
                    captureStarted.fulfill()
                }
            }
        )
        let weakModel = WeakReference(model)

        model?.capture(.fullScreen)
        await fulfillment(of: [captureStarted], timeout: 2)
        model = nil
        XCTAssertNil(weakModel.value)

        captureContinuation?.resume(returning: captureURL)
        captureContinuation = nil
        await waitUntil {
            !FileManager.default.fileExists(atPath: captureURL.path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testCaptureFailureRestoresHiddenWindows() async throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let coordinator = TestCaptureWindowVisibilityCoordinator()
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: CaptureHistoryStore(environment: fixture.environment),
            windowVisibilityCoordinator: coordinator,
            captureOperation: { _ in
                coordinator.events.append("capture")
                throw CaptureLabError.captureCancelled
            }
        )

        model.capture(.region)
        await waitUntil { !model.isCapturing }

        XCTAssertEqual(coordinator.events, ["hide", "wait", "capture", "restore"])
        XCTAssertFalse(model.hasImage)
        XCTAssertEqual(model.statusMessage, CaptureLabError.captureCancelled.localizedDescription)
    }

    func testUndoRestoresPreviousAnnotationSnapshot() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let model = Self.model(for: fixture)
        let first = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        )
        let second = CaptureAnnotation.arrow(
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 0.6, y: 0.6)
        )

        model.addAnnotation(first)
        model.addAnnotation(second)

        XCTAssertEqual(model.annotations.count, 2)
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertEqual(model.annotations, [first])
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testUndoCommitsPendingTextBeforeRestoringAnnotationSnapshot() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let model = Self.model(for: fixture)
        let annotation = CaptureAnnotation.text(
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
            text: "Before edit"
        )
        model.addAnnotation(annotation)
        let editorOwner = NSObject()
        var didCommitPendingText = false
        CaptureEditingSession.shared.registerPendingTextCommitter(owner: editorOwner) {
            didCommitPendingText = true
            var edited = model.annotations
            edited[0].text = "Pending edit"
            model.annotations = edited
        }
        defer { CaptureEditingSession.shared.unregisterPendingTextCommitter(owner: editorOwner) }

        model.undoAnnotation()

        XCTAssertTrue(didCommitPendingText)
        XCTAssertEqual(model.annotations, [annotation])
    }

    func testClearAnnotationsCanBeUndone() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let model = Self.model(for: fixture)
        let annotation = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        model.addAnnotation(annotation)
        model.clearAnnotations()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertEqual(model.annotations, [annotation])
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testClearCommitsPendingTextBeforeRemovingAnnotations() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let model = Self.model(for: fixture)
        let annotation = CaptureAnnotation.text(
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
            text: "Before edit"
        )
        model.addAnnotation(annotation)
        let editorOwner = NSObject()
        CaptureEditingSession.shared.registerPendingTextCommitter(owner: editorOwner) {
            var edited = model.annotations
            guard !edited.isEmpty else { return }
            edited[0].text = "Pending edit"
            model.annotations = edited
        }
        defer { CaptureEditingSession.shared.unregisterPendingTextCommitter(owner: editorOwner) }

        model.clearAnnotations()
        model.undoAnnotation()

        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations[0].text, "Pending edit")
    }

    func testResettingDocumentClearsUndoHistory() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let model = Self.model(for: fixture)
        let annotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        model.addAnnotation(annotation)
        model.clearDocument()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testFinishEditingCopiesAndClearsCurrentDocument() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let imageData = try XCTUnwrap(Self.fixtureImage().captureLabPNGData())
        let item = try historyStore.record(
            data: imageData,
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let pasteboard = NSPasteboard(
            name: .init("CaptureLabViewModelTests.finish.\(UUID().uuidString)")
        )
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pasteboard: pasteboard
        )
        let annotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        model.openHistoryItem(item)
        model.addAnnotation(annotation)
        model.ocrText = "recognized text"

        XCTAssertTrue(model.finishEditing())

        XCTAssertFalse(model.hasImage)
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
        XCTAssertTrue(model.ocrText.isEmpty)
    }

    func testCopyCommitsPendingTextEditingBeforeRendering() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let item = try historyStore.record(
            data: XCTUnwrap(Self.fixtureImage().captureLabPNGData()),
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let pasteboard = NSPasteboard(name: .init("CaptureLabViewModelTests.commit.\(UUID().uuidString)"))
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pasteboard: pasteboard
        )
        model.openHistoryItem(item)
        let owner = NSObject()
        var didCommit = false
        CaptureEditingSession.shared.registerPendingTextCommitter(owner: owner) {
            didCommit = true
        }
        defer { CaptureEditingSession.shared.unregisterPendingTextCommitter(owner: owner) }

        XCTAssertTrue(model.copyRenderedImage())

        XCTAssertTrue(didCommit)
    }

    func testCopyWithMosaicDoesNotOverwritePasteboardWhenRenderingFails() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let item = try historyStore.record(
            data: XCTUnwrap(Self.fixtureImage().captureLabPNGData()),
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let pasteboard = NSPasteboard(
            name: .init("CaptureLabViewModelTests.render-failure.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("keep-existing-value", forType: .string)
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pasteboard: pasteboard,
            imageRenderingOperation: { _, annotations in
                XCTAssertEqual(annotations.map(\.kind), [.mosaic])
                return nil
            }
        )
        model.openHistoryItem(item)
        model.addAnnotation(CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        ))

        XCTAssertFalse(model.copyRenderedImage())

        XCTAssertEqual(pasteboard.string(forType: .string), "keep-existing-value")
        XCTAssertNil(pasteboard.availableType(from: [.tiff]))
        XCTAssertTrue(model.hasImage)
        XCTAssertEqual(model.statusMessage, L10n.imageCopyFailed)

        XCTAssertFalse(model.finishEditing())
        XCTAssertTrue(model.hasImage)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep-existing-value")
    }

    func testCopyWithoutAnnotationsStillWritesImageToPasteboard() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let item = try historyStore.record(
            data: XCTUnwrap(Self.fixtureImage().captureLabPNGData()),
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let pasteboard = NSPasteboard(
            name: .init("CaptureLabViewModelTests.unannotated-copy.\(UUID().uuidString)")
        )
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pasteboard: pasteboard
        )
        model.openHistoryItem(item)

        XCTAssertTrue(model.copyRenderedImage())

        XCTAssertNotNil(pasteboard.availableType(from: [.tiff]))
        XCTAssertTrue(model.hasImage)
    }

    func testSaveFreezesRenderedPNGDataBeforeDestinationCanReplaceDocument() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let imageData = try XCTUnwrap(Self.fixtureImage().captureLabPNGData())
        let first = try historyStore.record(
            data: imageData,
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let second = try historyStore.record(
            data: imageData,
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let firstAnnotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        )
        let secondAnnotation = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3)
        )
        let destinationURL = fixture.home.appendingPathComponent("frozen export.png")
        let frozenPNGData = Data("first-document-render".utf8)
        var model: CaptureLabViewModel!
        var firstImage: NSImage?
        var events: [String] = []
        var renderCount = 0
        model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pngDataRenderingOperation: { image, annotations in
                events.append("render")
                renderCount += 1
                XCTAssertTrue(image === firstImage)
                XCTAssertEqual(annotations, [firstAnnotation])
                return frozenPNGData
            },
            saveDestinationOperation: { _ in
                events.append("destination")
                model.openHistoryItem(second)
                model.addAnnotation(secondAnnotation)
                return destinationURL
            }
        )
        model.openHistoryItem(first)
        firstImage = try XCTUnwrap(model.document?.image)
        model.addAnnotation(firstAnnotation)
        let textEditorOwner = NSObject()
        var didCommitPendingText = false
        CaptureEditingSession.shared.registerPendingTextCommitter(owner: textEditorOwner) {
            didCommitPendingText = true
            events.append("commit")
        }
        defer { CaptureEditingSession.shared.unregisterPendingTextCommitter(owner: textEditorOwner) }

        model.saveRenderedImage()

        XCTAssertTrue(didCommitPendingText)
        XCTAssertEqual(Array(events.prefix(3)), ["commit", "render", "destination"])
        XCTAssertEqual(renderCount, 1)
        XCTAssertEqual(try Data(contentsOf: destinationURL), frozenPNGData)
        XCTAssertEqual(model.document?.sourceURL, historyStore.url(for: second))
        XCTAssertEqual(model.annotations, [secondAnnotation])
    }

    func testSaveRenderingFailureDoesNotRequestDestinationOrWriteFile() throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let item = try historyStore.record(
            data: XCTUnwrap(Self.fixtureImage().captureLabPNGData()),
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let destinationURL = fixture.home.appendingPathComponent("must-not-exist.png")
        var destinationRequestCount = 0
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            pngDataRenderingOperation: { _, _ in nil },
            saveDestinationOperation: { _ in
                destinationRequestCount += 1
                return destinationURL
            }
        )
        model.openHistoryItem(item)

        model.saveRenderedImage()

        XCTAssertEqual(destinationRequestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(model.statusMessage, CaptureLabError.imageExportFailed.localizedDescription)
        XCTAssertTrue(model.hasImage)
    }

    func testLateOCRResultCannotOverwriteAReplacementDocument() async throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let imageData = try XCTUnwrap(Self.fixtureImage().captureLabPNGData())
        let first = try historyStore.record(
            data: imageData,
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let second = try historyStore.record(
            data: imageData,
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let recognitionStarted = expectation(description: "recognition started")
        var continuation: CheckedContinuation<OCRResult, Error>?
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            textRecognitionOperation: { _ in
                try await withCheckedThrowingContinuation { pending in
                    continuation = pending
                    recognitionStarted.fulfill()
                }
            }
        )
        model.openHistoryItem(first)

        model.recognizeText()
        await fulfillment(of: [recognitionStarted], timeout: 2)
        model.openHistoryItem(second)
        continuation?.resume(returning: OCRResult(
            text: "stale result",
            lineCount: 1,
            createdAt: Date()
        ))
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(model.ocrText.isEmpty)
        XCTAssertFalse(model.isRecognizingText)
        XCTAssertEqual(model.document?.sourceURL, historyStore.url(for: second))
    }

    func testLateOCRResultCannotWriteAfterDocumentIsCleared() async throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let item = try historyStore.record(
            data: XCTUnwrap(Self.fixtureImage().captureLabPNGData()),
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let recognitionStarted = expectation(description: "recognition started")
        var continuation: CheckedContinuation<OCRResult, Error>?
        let model = CaptureLabViewModel(
            r2SettingsStore: Self.settingsStore(for: fixture),
            historyStore: historyStore,
            textRecognitionOperation: { _ in
                try await withCheckedThrowingContinuation { pending in
                    continuation = pending
                    recognitionStarted.fulfill()
                }
            }
        )
        model.openHistoryItem(item)

        model.recognizeText()
        await fulfillment(of: [recognitionStarted], timeout: 2)
        model.clearDocument()
        continuation?.resume(returning: OCRResult(
            text: "stale result",
            lineCount: 1,
            createdAt: Date()
        ))
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(model.hasImage)
        XCTAssertTrue(model.ocrText.isEmpty)
        XCTAssertFalse(model.isRecognizingText)
    }

    func testDoneKeepsImageOnClipboardWhenAnUploadFinishesLate() async throws {
        let fixture = try HistoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let settingsStore = Self.settingsStore(for: fixture)
        try settingsStore.save(Self.fixtureR2SettingsInput)
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let item = try historyStore.record(
            data: XCTUnwrap(Self.fixtureImage().captureLabPNGData()),
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let pasteboard = NSPasteboard(name: .init("CaptureLabViewModelTests.upload.\(UUID().uuidString)"))
        let uploadStarted = expectation(description: "upload started")
        var continuation: CheckedContinuation<CloudflareR2UploadResult, Error>?
        let model = CaptureLabViewModel(
            r2SettingsStore: settingsStore,
            historyStore: historyStore,
            pasteboard: pasteboard,
            uploadOperation: { _ in
                try await withCheckedThrowingContinuation { pending in
                    continuation = pending
                    uploadStarted.fulfill()
                }
            }
        )
        model.openHistoryItem(item)
        model.uploadRenderedImage()
        await fulfillment(of: [uploadStarted], timeout: 2)

        XCTAssertTrue(model.finishEditing())
        XCTAssertFalse(model.isUploading)
        XCTAssertNotNil(pasteboard.availableType(from: [.tiff]))
        XCTAssertNil(pasteboard.string(forType: .string))

        continuation?.resume(returning: CloudflareR2UploadResult(
            url: "https://example.com/late.png",
            objectKey: "late.png",
            sizeBytes: 1
        ))
        await Task.yield()
        await Task.yield()

        XCTAssertNotNil(pasteboard.availableType(from: [.tiff]))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    private static func fixtureImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 48))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 48).fill()
        image.unlockFocus()
        return image
    }

    private static var fixtureR2SettingsInput: CloudflareR2SettingsInput {
        CloudflareR2SettingsInput(
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "capture-bucket",
            pathPrefix: "captures",
            publicBaseURL: "https://pub.example.com",
            accessKeyID: "access-key",
            secretAccessKey: "secret-key"
        )
    }

    private static func settingsStore(for fixture: HistoryFixture) -> CloudflareR2SettingsStore {
        CloudflareR2SettingsStore(
            environment: fixture.environment,
            secretStore: ViewModelInMemoryR2SecretStore()
        )
    }

    private static func model(for fixture: HistoryFixture) -> CaptureLabViewModel {
        CaptureLabViewModel(
            r2SettingsStore: settingsStore(for: fixture),
            historyStore: CaptureHistoryStore(environment: fixture.environment),
            pasteboard: NSPasteboard(
                name: .init("CaptureLabViewModelTests.model.\(UUID().uuidString)")
            )
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor
private final class TestCaptureWindowVisibilityCoordinator: CaptureWindowVisibilityCoordinating {
    var events: [String] = []

    func hideVisibleWindowsForCapture() -> any CaptureWindowRestoring {
        events.append("hide")
        return TestCaptureWindowRestoration(coordinator: self)
    }

    func waitUntilWindowsAreHidden() async {
        events.append("wait")
    }
}

@MainActor
private final class TestCaptureWindowRestoration: CaptureWindowRestoring {
    private weak var coordinator: TestCaptureWindowVisibilityCoordinator?

    init(coordinator: TestCaptureWindowVisibilityCoordinator) {
        self.coordinator = coordinator
    }

    func restore() {
        coordinator?.events.append("restore")
    }
}

private final class ViewModelInMemoryR2SecretStore: CloudflareR2SecretStoring {
    private var secrets: [String: String] = [:]

    func secret(for accessKeyID: String) throws -> String? {
        secrets[accessKeyID]
    }

    func setSecret(_ secret: String, for accessKeyID: String) throws {
        secrets[accessKeyID] = secret
    }

    func deleteSecret(for accessKeyID: String) throws {
        secrets.removeValue(forKey: accessKeyID)
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private struct HistoryFixture {
    let home: URL
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLabViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path]
    }
}
