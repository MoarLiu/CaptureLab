import AppKit
import Carbon
import Darwin
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureUX0120Tests: XCTestCase {
    func testUploadDraftSurvivesNavigationAndFailureAndSavesUsingExistingSecret() throws {
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        try fixture.store.save(.init(endpoint: "https://account.r2.cloudflarestorage.com", bucket: "test-bucket",
                                     pathPrefix: "captures", publicBaseURL: "https://example.invalid", accessKeyID: "fixture-key", secretAccessKey: "fixture-secret"))
        let session = CaptureSettingsSession(store: fixture.store, retention: .default)
        XCTAssertTrue(session.upload.isConfigured)
        XCTAssertEqual(session.upload.secretAccessKey, "")
        XCTAssertFalse(session.upload.isDirty)
        session.upload.pathPrefix = "edited"
        session.recordingAction = .window
        session.retention.maximumCount = 100
        session.navigate(to: .upload)
        session.navigate(to: .general)
        XCTAssertNil(session.recordingAction)
        XCTAssertEqual(session.retention.maximumCount, 100)
        XCTAssertEqual(session.upload.pathPrefix, "edited")
        XCTAssertEqual(fixture.store.settings?.pathPrefix, "captures")
        session.upload.endpoint = "http://example.invalid"
        XCTAssertFalse(session.upload.save())
        XCTAssertTrue(session.upload.isDirty)
        XCTAssertTrue(session.upload.failed)
        XCTAssertEqual(session.upload.pathPrefix, "edited")
        XCTAssertEqual(fixture.store.settings?.pathPrefix, "captures")
        session.upload.endpoint = "https://account.r2.cloudflarestorage.com/"
        XCTAssertTrue(session.upload.save())
        XCTAssertFalse(session.upload.isDirty)
        XCTAssertEqual(session.upload.endpoint, "https://account.r2.cloudflarestorage.com")
        XCTAssertEqual(fixture.store.settings?.pathPrefix, "edited")
        XCTAssertEqual(fixture.store.settings?.secretAccessKey, "fixture-secret")
        XCTAssertFalse(try String(contentsOf: fixture.store.url).contains("fixture-secret"))
    }

    func testChangingAccessKeyCannotReuseOldSecretAndDiscardRestoresStoredValues() throws {
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        try fixture.store.save(.init(endpoint: "https://account.r2.cloudflarestorage.com", bucket: "test-bucket",
                                     pathPrefix: "captures", publicBaseURL: "https://example.invalid", accessKeyID: "fixture-key", secretAccessKey: "fixture-secret"))
        let draft = CaptureR2SettingsDraft(store: fixture.store)
        XCTAssertTrue(draft.canReuseStoredSecret)
        draft.accessKeyID = "another-key"
        XCTAssertFalse(draft.canReuseStoredSecret)
        XCTAssertFalse(draft.canSave)
        draft.secretAccessKey = "another-secret"
        XCTAssertTrue(draft.canSave)
        draft.reload()
        XCTAssertEqual(draft.accessKeyID, "fixture-key")
        XCTAssertEqual(draft.secretAccessKey, "")
        XCTAssertTrue(draft.canReuseStoredSecret)
        XCTAssertFalse(draft.isDirty)
    }

    func testExternalRetentionRefreshUpdatesCleanStateAndPreservesUnappliedDraft() throws {
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        let session = CaptureSettingsSession(store: fixture.store, retention: .default)
        session.synchronizeRetention(.init(maximumCount: 100, maximumAgeDays: nil))
        XCTAssertEqual(session.retention.maximumCount, 100)
        session.retention.maximumAgeDays = 7
        session.synchronizeRetention(.init(maximumCount: 300, maximumAgeDays: nil))
        XCTAssertEqual(session.retention.maximumCount, 100)
        XCTAssertEqual(session.retention.maximumAgeDays, 7)
    }

    func testNewExportPreservesFormatAndQualityWithoutInheritingAnotherImagesDimensions() throws {
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        let store = CaptureExportSettingsStore(defaults: fixture.defaults)
        var prior = CaptureExportSettings()
        prior.format = .jpeg; prior.quality = 0.7; prior.width = 64; prior.height = 80
        store.save(prior)
        let next = store.loadForNewExport()
        XCTAssertEqual(next.format, .jpeg)
        XCTAssertEqual(next.quality, 0.7)
        XCTAssertNil(next.width); XCTAssertNil(next.height)
        let image = try fixture.image()
        let bytes = try next.encode(image)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        XCTAssertEqual(bitmap.pixelsWide, 640); XCTAssertEqual(bitmap.pixelsHigh, 360)
        XCTAssertEqual(store.load(), prior, "Reading the new-export defaults must not destroy older stored settings.")
    }

    func testUnconfiguredUploadOpensSettingsWithoutReplacingTheDocument() throws {
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(fixture.image().captureLabPNGData())))
        let id = model.document?.id
        let annotations = [CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))]
        model.annotations = annotations
        var opened = 0
        model.presentUploadSettings = { opened += 1 }
        model.uploadRenderedImage()
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(model.isUploading)
        XCTAssertEqual(model.document?.id, id)
        XCTAssertEqual(model.annotations, annotations)
    }

    func testRegisteredShortcutIsRecordedWithoutStartingCaptureAndResumesAfterCancel() {
        let controller = GlobalHotKeyController(registerOperation: { _, _, _, ref in ref = OpaquePointer(bitPattern: 901); return noErr },
                                                unregisterOperation: { _ in noErr }, installEventHandlerOverride: { noErr })
        var captures = 0
        XCTAssertTrue(controller.configure(shortcut: .defaultCapture) { captures += 1 })
        var recorded: [CaptureKeyboardShortcut] = []
        controller.recordShortcut = { recorded.append($0) }
        controller.handleHotKey(id: 1)
        XCTAssertEqual(recorded, [.defaultCapture])
        XCTAssertEqual(captures, 0)
        controller.recordShortcut = nil
        controller.handleHotKey(id: 1)
        XCTAssertEqual(captures, 1)
    }

    func testPreciseSelectionWaitsForConfirmationAndANewOrdinarySelectionStartsFree() throws {
        _ = NSApplication.shared
        let display = CaptureDisplay(id: "fixture", frame: CGRect(x: 0, y: 0, width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        let state = CaptureRegionSelection()
        state.requiresConfirmation = true; state.displays = [display]; state.showsMagnifier = false
        let view = RegionSelectionView(state: state, display: display, snapshot: nil, frozen: false)
        let window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        var captures = 0
        state.finish = { captures += 1 }
        for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 20, y: 30)), (.leftMouseUp, CGPoint(x: 120, y: 80))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(state.rect.size, CGSize(width: 100, height: 50))
        view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        XCTAssertEqual(captures, 1)
        let ordinary = CaptureRegionSelection()
        XCTAssertFalse(ordinary.requiresConfirmation)
        XCTAssertNil(ordinary.aspect)
    }

    func testNativeMenuReflectsBusyStateAndKeepsPinRecoveryReachable() async throws {
        _ = NSApplication.shared
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        var release: CheckedContinuation<URL, Error>?
        let model = fixture.model(capture: { _ in try await withCheckedThrowingContinuation { release = $0 } })
        let shortcuts = CaptureShortcutStore(defaults: fixture.defaults)
        var rejectsReplacement = false
        let controller = GlobalHotKeyController(registerOperation: { _, _, _, ref in
            if rejectsReplacement { return OSStatus(eventHotKeyExistsErr) }
            ref = OpaquePointer(bitPattern: 902); return noErr
        },
                                                unregisterOperation: { _ in noErr }, installEventHandlerOverride: { noErr })
        XCTAssertTrue(controller.configure(shortcut: shortcuts.captureShortcut, action: {}))
        let status = CaptureStatusBarController()
        status.install(model: model, shortcuts: shortcuts, hotKeys: controller, showEditor: {}, showHistory: {}, showSettings: { _, _ in })
        let menu = NSMenu()
        status.populate(menu)
        let region = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "region" })
        XCTAssertEqual(region.keyEquivalent, shortcuts.captureShortcut.key)
        XCTAssertFalse(region.title.contains(shortcuts.captureShortcut.displayTitle))
        XCTAssertNotNil(region.image)
        if #available(macOS 27.0, *) { XCTAssertEqual(region.preferredImageVisibility, .visible) }
        XCTAssertTrue(region.isEnabled)
        XCTAssertFalse(menu.items.contains { $0.identifier?.rawValue == "windows" })
        rejectsReplacement = true
        XCTAssertFalse(controller.configure(action: .region, shortcut: .init(key: "s", modifiers: [.command, .option]), perform: {}))
        status.populate(menu)
        XCTAssertEqual(try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "region" }).keyEquivalent, shortcuts.captureShortcut.key)
        XCTAssertFalse(menu.items.contains { $0.identifier?.rawValue == "shortcutError" }, "A failed replacement must not report the still-working original shortcut as unavailable.")
        try renderNativeMenuIfRequested(menu)
        CapturePinController.shared.pin(image: try fixture.image(), title: "Synthetic fixture")
        defer { CapturePinController.shared.closeAll() }
        status.populate(menu)
        let windows = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "windows" }?.submenu)
        XCTAssertTrue(windows.items.contains { $0.identifier?.rawValue == "unlockPins" && $0.isEnabled })
        XCTAssertTrue(windows.items.contains { $0.identifier?.rawValue == "closePins" && $0.isEnabled })
        model.captureRegion()
        status.populate(menu)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "region" }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "settings" }).isEnabled)
        for _ in 0..<100 where release == nil { await Task.yield() }
        try XCTUnwrap(release).resume(throwing: CaptureLabError.captureCancelled)
        for _ in 0..<100 where model.isCapturing { await Task.yield() }
    }

    func testSettingsPagesFitMinimumAndDefaultWindowsAndRenderTheirStates() async throws {
        _ = NSApplication.shared
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let session = CaptureSettingsSession(store: fixture.store, retention: model.historyStore.retention)
        let hotKeys = GlobalHotKeyController()
        let view = CaptureSettingsView(session: session, model: model, shortcuts: CaptureShortcutStore(defaults: fixture.defaults),
            hotKeys: hotKeys, recognition: RecognitionSettings(defaults: fixture.defaults), registerShortcut: { _, _ in nil })
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 900, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { session.upload.reload(); window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for size in [CGSize(width: 900, height: 640), CGSize(width: 760, height: 540)] {
            window.setContentSize(size)
            for category in CaptureSettingsSection.allCases {
                session.navigate(to: category)
                try await Task.sleep(nanoseconds: 120_000_000)
                hosting.layoutSubtreeIfNeeded(); window.display()
                XCTAssertLessThanOrEqual(hosting.fittingSize.width, size.width, category.title)
                XCTAssertLessThanOrEqual(hosting.fittingSize.height, size.height, category.title)
                if let directory = ProcessInfo.processInfo.environment["CAPTURELAB_0120_UI_OUTPUT"] {
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let theme: String
                    switch appearance {
                    case .aqua: theme = "light"
                    case .darkAqua: theme = "dark"
                    case .accessibilityHighContrastAqua: theme = "contrast-light"
                    default: theme = "contrast-dark"
                    }
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("settings-\(category.rawValue)-\(Int(size.width))-\(theme).png"))
                }
            }
        }
        }
    }

    func testOrdinarySelectorHasNoParameterPanelWhilePreciseSelectionKeepsItsControls() async throws {
        _ = NSApplication.shared
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        for precise in [false, true] {
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            let selector = CaptureRegionSelector()
            let display = CaptureDisplay(id: "synthetic", frame: CGRect(x: 80, y: 80, width: 640, height: 360), pixelWidth: 640, pixelHeight: 360)
            let pixels = try XCTUnwrap(fixture.image().captureLabCGImage())
            let task = Task { @MainActor in try await selector.select(displays: [display], frames: [display.id: pixels], frozen: true, precise: precise) }
            defer { task.cancel() }
            for _ in 0..<100 where !NSApp.windows.contains(where: { !existing.contains(ObjectIdentifier($0)) && $0.contentView is RegionSelectionView }) { await Task.yield() }
            let created = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            XCTAssertEqual(created.count, precise ? 2 : 1)
            let region = try XCTUnwrap(created.first { $0.contentView is RegionSelectionView })
            let state = try XCTUnwrap((region.contentView as? RegionSelectionView)?.state)
            state.pointer = CGPoint(x: 200, y: 200)
            state.didChange?(); region.display()
            if let directory = ProcessInfo.processInfo.environment["CAPTURELAB_0120_UI_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let view = try XCTUnwrap(region.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(precise ? "precise-selection.png" : "ordinary-selection.png"))
            }
            state.cancel?()
            switch await task.result {
            case .success: XCTFail("Cancelling the selection must not capture")
            case .failure(let error): XCTAssertTrue(error is CaptureLabError)
            }
            XCTAssertFalse(created.contains(where: \.isVisible))
        }
    }

    func testRepeatedSuccessfulCopiesProduceIndependentFeedbackEvents() throws {
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(fixture.image().captureLabPNGData())))
        XCTAssertTrue(model.copyRenderedImage())
        let first = try XCTUnwrap(model.successFeedback)
        XCTAssertTrue(model.copyRenderedImage())
        let second = try XCTUnwrap(model.successFeedback)
        XCTAssertEqual(first.message, second.message)
        XCTAssertNotEqual(first.id, second.id, "Repeated actions must each display confirmation.")
    }

    func testRecognitionWindowRendersEmptyRunningFailureAndResultsWithoutOverwritingClipboard() async throws {
        _ = NSApplication.shared
        let fixture = try UXFixture()
        defer { fixture.cleanUp() }
        let pasteboard = NSPasteboard(name: .init(fixture.suite))
        pasteboard.setString("unchanged", forType: .string)
        var pending: CheckedContinuation<OCRResult, Error>?
        let controller = DirectRecognitionController(pasteboard: pasteboard,
            text: { _ in try await withCheckedThrowingContinuation { pending = $0 } },
            qr: { _ in ["https://example.invalid/qr"] })
        let hosting = NSHostingView(rootView: DirectRecognitionView(controller: controller, startSelection: { _ in }))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 560, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { controller.cancel(); window.close() }
        func render(_ state: String) async throws {
            try await Task.sleep(nanoseconds: 100_000_000)
            hosting.layoutSubtreeIfNeeded(); window.display()
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, 560)
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, 400)
            if let directory = ProcessInfo.processInfo.environment["CAPTURELAB_0120_UI_OUTPUT"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("recognition-\(state).png"))
            }
        }
        try await render("empty")
        let image = try XCTUnwrap(fixture.image().captureLabCGImage())
        controller.start(image: image, kind: .text)
        try await render("running")
        XCTAssertTrue(controller.isRunning)
        try XCTUnwrap(pending).resume(throwing: NSError(domain: "SyntheticRecognition", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to recognize this area. Select another area to try again."]))
        try await render("failed")
        XCTAssertNotNil(controller.failure)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged")
        controller.start(image: image, kind: .text)
        for _ in 0..<100 where !controller.isRunning { await Task.yield() }
        await Task.yield()
        try XCTUnwrap(pending).resume(returning: OCRResult(text: "", lineCount: 0, createdAt: Date()))
        try await render("no-results")
        XCTAssertNil(controller.failure)
        XCTAssertTrue(controller.results.isEmpty)
        controller.start(image: image, kind: .qrCode)
        try await render("results")
        XCTAssertEqual(controller.results, ["https://example.invalid/qr"])
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged", "QR results require an explicit copy action.")
    }

    private func renderNativeMenuIfRequested(_ menu: NSMenu) throws {
        guard let directory = ProcessInfo.processInfo.environment["CAPTURELAB_0120_UI_OUTPUT"] else { return }
        let host = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.contentView = view; host.orderFront(nil)
        defer { host.close() }
        let request = UXMenuSnapshot(menu: menu, directory: directory)
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
            // This timer is installed only on the main event-tracking run loop.
            MainActor.assumeIsolated { request.capture() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        menu.popUp(positioning: nil, at: CGPoint(x: 20, y: 480), in: view)
        try XCTUnwrap(request.result).get()
    }

}

@MainActor
private final class UXFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureUX0120-\(UUID().uuidString)")
    let suite = "CaptureUX0120.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: CloudflareR2SettingsStore
    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = CloudflareR2SettingsStore(environment: ["HOME": root.path], secretStore: UXSecretStore())
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func model(capture: CaptureLabViewModel.CaptureOperation? = nil) -> CaptureLabViewModel {
        CaptureLabViewModel(r2SettingsStore: store, historyStore: CaptureHistoryStore(environment: ["HOME": root.path]),
                            failurePresentationOperation: { _, message in XCTFail(message) },
                            pasteboard: NSPasteboard(name: .init(suite)),
                            windowVisibilityCoordinator: UXWindowVisibility(),
                            captureOperation: capture ?? { _ in throw CaptureLabError.captureCancelled },
                            workflowSettings: CaptureWorkflowSettings(defaults: defaults))
    }
    func image() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 640, height: 360))
    }
}

private final class UXSecretStore: CloudflareR2SecretStoring {
    var secrets: [String: String] = [:]
    func secret(for accessKeyID: String) throws -> String? { secrets[accessKeyID] }
    func setSecret(_ secret: String, for accessKeyID: String) throws { secrets[accessKeyID] = secret }
    func deleteSecret(for accessKeyID: String) throws { secrets[accessKeyID] = nil }
}

@MainActor
private final class UXWindowVisibility: CaptureWindowVisibilityCoordinating, CaptureWindowRestoring {
    func hideVisibleWindowsForCapture() -> any CaptureWindowRestoring { self }
    func waitUntilWindowsAreHidden() async {}
    func restore() {}
}

@MainActor
private final class UXMenuSnapshot {
    let menu: NSMenu
    let directory: String
    var result: Result<Void, Error>?
    init(menu: NSMenu, directory: String) { self.menu = menu; self.directory = directory }
    func capture() {
        defer { menu.cancelTracking() }
        do {
            let owned = ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier }
            let candidate = try XCTUnwrap(owned.max { ($0[kCGWindowLayer as String] as? Int ?? 0) < ($1[kCGWindowLayer as String] as? Int ?? 0) })
            let number = try XCTUnwrap(candidate[kCGWindowNumber as String] as? NSNumber)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try UXWindowSnapshot.write(CGWindowID(number.uint32Value), to: URL(fileURLWithPath: directory).appendingPathComponent("native-menu.png"))
            result = .success(())
        } catch { result = .failure(error) }
    }
}

@MainActor
private enum UXWindowSnapshot {
    static func write(_ number: CGWindowID, to url: URL) throws {
        typealias Operation = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let operation = unsafeBitCast(symbol, to: Operation.self)
        let image = try XCTUnwrap(operation(.null, CGWindowListOption.optionIncludingWindow.rawValue, number, CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let bitmap = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
