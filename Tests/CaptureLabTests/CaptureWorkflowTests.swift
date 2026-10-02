import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureWorkflowTests: XCTestCase {
    func testCopyOnlyCapturePreservesEditorAnnotationsAndOCR() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let model = try XCTUnwrap(fixture.model)
        XCTAssertTrue(model.importImageData(fixture.red))
        let documentID = model.document?.id
        model.annotations = [CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))]
        let annotations = model.annotations
        model.ocrText = "corrected text"
        model.workflowSettings.options.afterCapture = .copyOnly
        model.capture(.region) { XCTFail("Copy-only must not open the editor") }
        await waitForCapture(model)
        XCTAssertEqual(model.document?.id, documentID)
        XCTAssertEqual(model.annotations, annotations)
        XCTAssertEqual(model.ocrText, "corrected text")
        XCTAssertNotNil(model.latestCapture)
        XCTAssertEqual(model.historyItems.count, 1)
        XCTAssertEqual(NSImage(pasteboard: fixture.pasteboard)?.captureLabPixelSize, CGSize(width: 96, height: 64))
        XCTAssertTrue(model.overlayController.entries.isEmpty)
    }

    func testOverlayActionsKeepCapturedPixelsAfterEditingAndHistoryDeletion() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let model = try XCTUnwrap(fixture.model)
        model.workflowSettings.options.afterCapture = .overlay
        model.workflowSettings.options.autoCloseSeconds = 0
        var opened = 0
        model.capture(.region) { opened += 1 }
        await waitForCapture(model)
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(model.hasImage)
        let entry = try XCTUnwrap(model.overlayController.selected)
        let capturedPixels = try XCTUnwrap(entry.snapshot.image?.captureLabPNGData())
        model.deleteHistoryItem(try XCTUnwrap(model.historyItems.first))
        XCTAssertTrue(model.importImageData(fixture.red))
        entry.copy()
        XCTAssertEqual(try XCTUnwrap(NSImage(pasteboard: fixture.pasteboard)?.captureLabPNGData()), capturedPixels)
        entry.save()
        XCTAssertEqual(try Data(contentsOf: fixture.exportURL), entry.snapshot.data)
        XCTAssertTrue(entry.edit())
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(model.document?.image.captureLabPNGData(), capturedPixels)
        XCTAssertEqual(model.historyItems.count, 1, "The outgoing imported image must have a recovery history entry")
    }

    func testOverlayUploadUsesItsSnapshotAfterDocumentReplacement() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        fixture.model.workflowSettings.options.afterCapture = .overlay
        fixture.model.capture(.region)
        await waitForCapture(fixture.model)
        let snapshot = try XCTUnwrap(fixture.model.latestCapture)
        XCTAssertTrue(fixture.model.importImageData(fixture.red))
        fixture.model.uploadSnapshot(snapshot)
        for _ in 0..<50 where fixture.model.isUploading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fixture.uploads.first?.data, snapshot.data)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "https://example.test/capture.png")
    }

    func testImportPreservesRenderedOldDocumentAndInvalidImportKeepsUndo() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let model = try XCTUnwrap(fixture.model)
        XCTAssertTrue(model.importImageData(fixture.red))
        model.annotations = [CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        let before = try XCTUnwrap(model.renderedSnapshot())
        let id = model.document?.id
        XCTAssertFalse(model.importImageData(Data("invalid".utf8)))
        XCTAssertEqual(model.document?.id, id)
        XCTAssertTrue(model.canUndoAnnotation)
        XCTAssertTrue(model.importImageData(fixture.blue))
        let recovered = try XCTUnwrap(model.historyItems.first)
        XCTAssertEqual(try model.historyStore.data(for: recovered), before.data)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testReplacementFailureRetainsCurrentImageAndUndoStack() throws {
        let fixture = try WorkflowFixture(failHistory: true)
        defer { fixture.cleanUp() }
        let model = try XCTUnwrap(fixture.model)
        XCTAssertTrue(model.importImageData(fixture.red))
        model.annotations = [CaptureAnnotation(kind: .text, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        let id = model.document?.id
        XCTAssertFalse(model.importImageData(fixture.blue))
        XCTAssertEqual(model.document?.id, id)
        XCTAssertTrue(model.canUndoAnnotation)
        XCTAssertEqual(model.annotations.count, 1)
    }

    func testLateDropCannotReplaceNewerDocument() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let completion = DeferredImageProvider()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            completion.set(callback)
            return nil
        }
        XCTAssertTrue(fixture.model.importDroppedImage([provider]))
        for _ in 0..<50 where !completion.isReady { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(completion.isReady)
        XCTAssertTrue(fixture.model.importImageData(fixture.red))
        let id = fixture.model.document?.id
        completion.finish(fixture.blue)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fixture.model.document?.id, id)
    }

    func testPNGDropAndFileDropImportPixels() async throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let provider = NSItemProvider(item: fixture.blue as NSData, typeIdentifier: UTType.png.identifier)
        XCTAssertTrue(fixture.model.importDroppedImage([provider]))
        for _ in 0..<50 where !fixture.model.hasImage { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fixture.model.document?.pixelSize, CGSize(width: 96, height: 64))
        let file = fixture.home.appendingPathComponent("drop.png")
        try fixture.red.write(to: file)
        let fileProvider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let id = fixture.model.document?.id
        XCTAssertTrue(fixture.model.importDroppedImage([fileProvider]))
        for _ in 0..<50 where fixture.model.document?.id == id { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(fixture.model.document?.id, id)
        XCTAssertEqual(fixture.model.document?.pixelSize, CGSize(width: 80, height: 50))
    }

    func testPNGPromiseRetainsPayloadAndReportsDestinationFailure() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        var snapshot: CaptureImageSnapshot? = .init(data: fixture.blue, fileName: "image.png")
        let provider = CapturePNGPromiseProvider(snapshot: try XCTUnwrap(snapshot))
        snapshot = nil
        let delegate = try XCTUnwrap(provider.delegate)
        let pasteboard = fixture.pasteboard
        XCTAssertTrue(provider.writableTypes(for: pasteboard).contains(.png))
        XCTAssertEqual(provider.pasteboardPropertyList(forType: .png) as? Data, fixture.blue)
        delegate.filePromiseProvider(provider, writePromiseTo: fixture.exportURL) { error in XCTAssertNil(error) }
        XCTAssertEqual(try Data(contentsOf: fixture.exportURL), fixture.blue)
        delegate.filePromiseProvider(provider, writePromiseTo: fixture.home.appendingPathComponent("missing/output.png")) { error in
            XCTAssertNotNil(error)
        }
    }

    func testOverlayNavigationHideRestoreAndNegativeScreenCoordinates() throws {
        _ = NSApplication.shared
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.model.overlayController
        var options = CaptureWorkflowOptions()
        options.autoCloseSeconds = 0
        let first = makeEntry(fixture.red)
        let second = makeEntry(fixture.blue)
        controller.show(first, options: options)
        controller.show(second, options: options)
        controller.select(first.id)
        XCTAssertEqual(controller.selected?.snapshot.data, fixture.red)
        controller.toggleHidden()
        XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.toggleHidden()
        XCTAssertTrue(controller.window?.isVisible ?? false)
        controller.dismissSelected()
        XCTAssertEqual(controller.selected?.id, second.id)
        controller.restoreLast()
        XCTAssertEqual(controller.selected?.id, first.id)
        for corner in CaptureOverlayCorner.allCases {
            let visible = CGRect(x: -1600, y: -400, width: 1600, height: 900)
            let frame = CaptureQuickAccessController.frame(size: CGSize(width: 400, height: 330), visibleFrame: visible, corner: corner)
            XCTAssertTrue(visible.contains(frame))
        }
    }

    func testPinLockKeyboardMovementAndMenuRecovery() throws {
        _ = NSApplication.shared
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let pins = CapturePinController()
        pins.pin(image: try XCTUnwrap(NSImage(data: fixture.blue)), title: "Fixture")
        defer { pins.closeAll() }
        let window = try XCTUnwrap(pins.windows.first as? CapturePinWindow)
        let origin = window.frame.origin
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124))
        XCTAssertTrue(window.performKeyEquivalent(with: right))
        XCTAssertEqual(window.frame.minX, origin.x + 10)
        window.setLocked(true)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isMovable)
        _ = window.performKeyEquivalent(with: right)
        XCTAssertEqual(window.frame.minX, origin.x + 10)
        pins.unlockAll()
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(window.isMovable)
        pins.closeAll()
        XCTAssertTrue(pins.windows.isEmpty)
    }

    func testOverlayTimeoutPausesDuringCaptureAndResumesAfterward() async throws {
        _ = NSApplication.shared
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.model.overlayController
        var options = CaptureWorkflowOptions()
        options.autoCloseSeconds = 5
        controller.isCapturing = true
        controller.show(makeEntry(fixture.blue), options: options)
        controller.isHovering = false
        try await Task.sleep(nanoseconds: 5_100_000_000)
        XCTAssertEqual(controller.entries.count, 1)
        controller.isCapturing = false
        try await Task.sleep(nanoseconds: 5_100_000_000)
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertNotNil(controller.lastClosed)
    }

    func testReopeningCurrentHistoryKeepsJustPreservedEdits() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let model = try XCTUnwrap(fixture.model)
        let item = try model.historyStore.record(data: fixture.blue, pixelSize: CGSize(width: 96, height: 64))
        model.openHistoryItem(item)
        model.annotations = [CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))]
        let edited = try XCTUnwrap(model.renderedSnapshot())
        model.openHistoryItem(item)
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertEqual(model.document?.image.captureLabPNGData(), NSImage(data: edited.data)?.captureLabPNGData())
        XCTAssertEqual(try model.historyStore.data(for: item), edited.data)
    }

    func testSettingsPreserveUpgradeBehaviorAndRoundTrip() throws {
        let name = "CaptureWorkflowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureWorkflowSettings(defaults: defaults)
        XCTAssertEqual(settings.options.afterCapture, .editor)
        settings.options.afterCapture = .overlay
        settings.options.autoCloseSeconds = 0
        settings.options.corner = .topLeft
        XCTAssertEqual(CaptureWorkflowSettings(defaults: defaults).options, settings.options)
    }

    func testWorkflowViewsRenderAndTextPastingRemainsNative() throws {
        _ = NSApplication.shared
        let fixture = try WorkflowFixture()
        defer { fixture.cleanUp() }
        let settingsView = NSHostingView(rootView: CaptureWorkflowSettingsView(model: fixture.model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = settingsView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drainUI()
        XCTAssertLessThanOrEqual(settingsView.fittingSize.width, 500)
        try saveFixture(settingsView, name: "settings")
        let controller = fixture.model.overlayController
        var options = CaptureWorkflowOptions()
        options.autoCloseSeconds = 0
        controller.show(makeEntry(fixture.blue), options: options)
        drainUI()
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertLessThanOrEqual(content.fittingSize.width, 320)
        try saveFixture(content, name: "overlay")

        let installer = CaptureImagePasteInstaller.Coordinator()
        var pastedImage = false
        let textContainer = NSView(frame: settingsView.frame)
        window.contentView = textContainer
        installer.attach(textContainer, paste: { pastedImage = true })
        defer { installer.detach() }
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        textContainer.addSubview(text)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9))
        // Sending through NSApplication exercises its local monitor and responder chain.
        NSApp.postEvent(event, atStart: true)
        if let queued = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        XCTAssertFalse(pastedImage)
    }

    private func makeEntry(_ data: Data) -> CaptureQuickAccessController.Entry {
        .init(snapshot: .init(data: data), screenNumber: nil, edit: { true }, copy: {}, save: {}, pin: {}, upload: {})
    }
    private func waitForCapture(_ model: CaptureLabViewModel) async {
        for _ in 0..<100 where model.isCapturing { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isCapturing)
    }
    private func drainUI() {
        for _ in 0..<5 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
    }
    private func saveFixture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CAPTURELAB_WORKFLOW_UI_OUTPUT"] else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class WorkflowFixture {
    let home: URL
    let red: Data
    let blue: Data
    let pasteboard = NSPasteboard(name: .init("CaptureWorkflowTests.\(UUID().uuidString)"))
    let exportURL: URL
    var model: CaptureLabViewModel!
    var uploads: [CloudflareR2UploadRequest] = []
    init(failHistory: Bool = false) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureWorkflowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        exportURL = home.appendingPathComponent("export.png")
        red = try Self.image(.systemRed, width: 80, height: 50)
        blue = try Self.image(.systemBlue, width: 96, height: 64)
        let environment = ["HOME": home.path]
        let settings = CloudflareR2SettingsStore(environment: environment, secretStore: WorkflowSecretStore())
        try settings.save(CloudflareR2SettingsInput(endpoint: "https://example.test", bucket: "test", pathPrefix: "captures",
            publicBaseURL: "https://example.test", accessKeyID: "fixture", secretAccessKey: "fixture-secret"))
        let captureURL = home.appendingPathComponent("capture.png")
        let blue = blue
        model = CaptureLabViewModel(r2SettingsStore: settings,
            historyStore: CaptureHistoryStore(environment: environment, metadataWriter: { data, url in
                if failHistory { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }), failurePresentationOperation: { _, _ in }, pasteboard: pasteboard,
            windowVisibilityCoordinator: WorkflowVisibility(),
            captureOperation: { _ in try blue.write(to: captureURL); return captureURL },
            uploadOperation: { [weak self] request in
                self?.uploads.append(request)
                return CloudflareR2UploadResult(url: "https://example.test/capture.png", objectKey: "capture.png", sizeBytes: request.data.count)
            },
            saveDestinationOperation: { [exportURL] _ in exportURL }, workflowSettings: CaptureWorkflowSettings(defaults: nil))
    }
    func cleanUp() {
        model.overlayController.tearDown()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: home)
    }
    private static func image(_ color: NSColor, width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
        return try XCTUnwrap(image.captureLabPNGData())
    }
}

private final class WorkflowSecretStore: CloudflareR2SecretStoring {
    private var values: [String: String] = [:]
    func secret(for accessKeyID: String) throws -> String? { values[accessKeyID] }
    func setSecret(_ secret: String, for accessKeyID: String) throws { values[accessKeyID] = secret }
    func deleteSecret(for accessKeyID: String) throws { values.removeValue(forKey: accessKeyID) }
}

@MainActor
private final class WorkflowVisibility: CaptureWindowVisibilityCoordinating, CaptureWindowRestoring {
    func hideVisibleWindowsForCapture() -> any CaptureWindowRestoring { self }
    func waitUntilWindowsAreHidden() async {}
    func restore() {}
}

private final class DeferredImageProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func set(_ callback: @escaping (Data?, Error?) -> Void) { lock.lock(); defer { lock.unlock() }; completion = callback }
    func finish(_ data: Data) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(data, nil)
    }
}
