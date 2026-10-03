import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureEditorUITests: XCTestCase {
    func testFitAndFixedZoomKeepTheSameNativeCanvasAndCommitPendingText() async throws {
        _ = NSApplication.shared
        let state = ZoomFixtureState()
        let document = CaptureDocument(image: try fixtureImage(), sourceURL: nil, createdAt: Date())
        let annotation = CaptureAnnotation.text(normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.2), text: "Before zoom")
        state.annotations = [annotation]
        let root = ZoomFixtureView(document: document, state: state)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        hosting.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(nativeDescendants(of: hosting).compactMap { $0 as? CaptureAnnotationNSCanvasView }.first)
        let output = canvas.outputDisplayRect
        let point = canvas.convert(CGPoint(x: output.minX + output.width * 0.4, y: output.minY + output.height * 0.3), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        canvas.mouseDown(with: click)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        if let editor = field.currentEditor() { editor.string = "Committed at zoom" }
        else { field.stringValue = "Committed at zoom" }
        for zoom in [CaptureZoomLevel.actual, .double, .fit] {
            state.zoom = zoom
            try await Task.sleep(nanoseconds: 100_000_000)
            hosting.layoutSubtreeIfNeeded()
            let current = try XCTUnwrap(nativeDescendants(of: hosting).compactMap { $0 as? CaptureAnnotationNSCanvasView }.first)
            XCTAssertTrue(current === canvas)
            XCTAssertEqual(state.annotations.first?.text, "Committed at zoom")
            XCTAssertFalse(canvas.subviews.contains { $0 is NSTextField })
        }
    }
    func testMergedEditorAndNewPanelsFitTheirWindows() async throws {
        _ = NSApplication.shared
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMergedUI-\(UUID().uuidString)")
        let defaultsName = "CaptureMergedUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        let environment = ["HOME": fixtureRoot.path]
        let model = CaptureLabViewModel(
            r2SettingsStore: CloudflareR2SettingsStore(environment: environment, secretStore: EditorUITestSecretStore()),
            historyStore: CaptureHistoryStore(environment: environment),
            failurePresentationOperation: { _, message in XCTFail(message) },
            pasteboard: NSPasteboard(name: .init(defaultsName)), workflowSettings: CaptureWorkflowSettings(defaults: defaults))
        let source = try fixtureImage()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(source.captureLabPNGData())))
        let layer = CaptureImageLayer(name: "Sample.png", pngData: try XCTUnwrap(source.captureLabPNGData()),
            normalizedRect: CGRect(x: 0.52, y: 0.45, width: 0.32, height: 0.38), rotationDegrees: 12, zIndex: 0)
        let appearance = CaptureAnnotationAppearance(color: CaptureAnnotationColor(.white), lineWidth: 3, fontSize: 24,
            fontFamily: "Helvetica", fontWeight: .bold, textAlignment: .left,
            textBackgroundColor: CaptureAnnotationColor(.black), textBorderColor: CaptureAnnotationColor(.white))
        model.commitObjects(layers: [layer], annotations: [
            .init(kind: .text, normalizedRect: CGRect(x: 0.09, y: 0.12, width: 0.8, height: 0.2), text: "CaptureLab 0.9.0", appearance: appearance),
            .curvedArrow(start: CGPoint(x: 0.18, y: 0.67), end: CGPoint(x: 0.65, y: 0.58), control: CGPoint(x: 0.32, y: 0.35))
        ])
        model.selectedObjects = [.image(layer.id)]
        model.isEditingObjects = true
        let root = CaptureLabRootView(model: model, shortcutStore: CaptureShortcutStore(defaults: defaults), showHistory: {})
        try await renderPanel(root, size: CGSize(width: 1080, height: 620), name: "objects")
        try await renderPanel(CaptureLayersView(document: XCTUnwrap(model.document), annotations: model.annotations,
            selectedObjects: model.selectedObjects, onSelectionChanged: { model.selectedObjects = $0 },
            onCommit: { model.commitObjects(layers: $0, annotations: $1) }, addImages: {})
            .frame(width: 340, height: 480), size: CGSize(width: 340, height: 480), name: "layers")
        var presentation = CapturePresentation()
        presentation.background = .gradient
        presentation.padding = 32
        presentation.cornerRadius = 20
        presentation.shadowOpacity = 0.4
        presentation.aspect = .sixteenNine
        model.applyPresentation(presentation)
        try await renderPanel(root, size: CGSize(width: 1080, height: 620), name: "output")
        try await renderPanel(CaptureAdvancedAnnotationStyleView(appearance: .constant(appearance), tool: .text)
            .defaultAppStorage(defaults), size: CGSize(width: 372, height: 640), name: "text-style")
        try await renderPanel(CapturePresentationView(presentation: .constant(presentation), sourceSize: source.captureLabPixelSize,
            sourceImage: source, onApply: { _ in }), size: CGSize(width: 690, height: 660), name: "background")
        let rendered = try XCTUnwrap(model.renderedSnapshot()?.image)
        try await renderPanel(CaptureExportView(image: rendered), size: CGSize(width: 670, height: 460), name: "export")
    }

    private func renderPanel<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        CaptureLabAppDelegate.allowNextMainWindowPresentation()
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 600_000_000)
        hosting.layoutSubtreeIfNeeded()
        window.display()
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, size.width, name)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, size.height, name)
        if let directory = ProcessInfo.processInfo.environment["CAPTURELAB_MERGED_UI_OUTPUT"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try saveFixtureWindowSnapshot(window, to: folder.appendingPathComponent("\(name).png"))
        }
    }

    func testEditorFitsMinimumWindowWidthAndEscapeCancelsCropWithoutClosingWindow() throws {
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEditorUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let history = CaptureHistoryStore(environment: environment)
        let image = try fixtureImage()
        let item = try history.record(data: XCTUnwrap(image.captureLabPNGData()), pixelSize: image.captureLabPixelSize)
        let model = CaptureLabViewModel(
            r2SettingsStore: CloudflareR2SettingsStore(environment: environment, secretStore: EditorUITestSecretStore()),
            historyStore: history,
            failurePresentationOperation: { _, message in XCTFail(message) },
            pasteboard: NSPasteboard(name: .init("CaptureEditorUITests.\(UUID().uuidString)"))
        )
        model.openHistoryItem(item)
        let defaultsName = "CaptureEditorUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let root = CaptureLabRootView(model: model, shortcutStore: CaptureShortcutStore(defaults: defaults), showHistory: {})
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        CaptureLabAppDelegate.allowNextMainWindowPresentation()
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drainUI()
        hosting.layoutSubtreeIfNeeded()
        window.display()

        XCTAssertTrue(window.isVisible)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 1_080, "The editor's content must fit its minimum supported width.")
        XCTAssertEqual(hosting.bounds.width, 1_080, accuracy: 1)
        let optionRow = CGRect(x: 0, y: 52, width: hosting.bounds.width, height: 46)
        let nativeControls = nativeDescendants(of: hosting).filter { $0 is NSColorWell || $0 is NSStepper }
        XCTAssertEqual(nativeControls.filter { $0 is NSColorWell }.count, 1)
        XCTAssertEqual(nativeControls.filter { $0 is NSStepper }.count, 2)
        for control in nativeControls {
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(optionRow.contains(control.convert(control.bounds, to: hosting)), "Style controls must be visible inside the second toolbar row.")
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.display()
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(luminanceRange(in: optionRow, bitmap: bitmap, view: hosting), 0.15,
            "The second toolbar row must render controls and labels rather than a blank background.")
        if let outputPath = ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: outputPath))
        }
        if let outputPath = ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_WINDOW_OUTPUT"] {
            try saveFixtureWindowSnapshot(window, to: URL(fileURLWithPath: outputPath))
        }
        if ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_INSPECT"] == "1" {
            inspectFixtureView(hosting)
        }

        model.annotations = [CaptureAnnotation.text(normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.2), text: "CaptureLab 0.8.0")]
        model.adjustImage(.rotateClockwise)
        model.adjustImage(.flipHorizontal)
        XCTAssertTrue(model.resizeOutput(to: CGSize(width: 320, height: 420)))
        model.selectedTool = .crop
        model.cropPreset = .fourThree
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        model.constrainCropSelection()
        drainUI()
        hosting.layoutSubtreeIfNeeded()
        window.display()
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 1_080)
        if let outputPath = ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_CROP_OUTPUT"] {
            let croppedUI = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: croppedUI)
            try XCTUnwrap(croppedUI.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: outputPath))
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        NSApp.postEvent(escape, atStart: true)
        if let event = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        drainUI()

        XCTAssertNil(model.cropSelection)
        XCTAssertEqual(model.selectedTool, .select)
        XCTAssertTrue(window.isVisible, "Esc during cropping must preserve the editor window.")
    }

    private func drainUI() {
        for _ in 0..<4 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func nativeDescendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + nativeDescendants(of: $0) }
    }

    private func luminanceRange(in rect: CGRect, bitmap: NSBitmapImageRep, view: NSView) -> CGFloat {
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        var minimum: CGFloat = 1
        var maximum: CGFloat = 0
        for y in stride(from: Int(top * scaleY) + 4, to: Int((top + rect.height) * scaleY) - 4, by: 4) {
            for x in stride(from: Int(rect.minX * scaleX) + 8, to: Int(rect.maxX * scaleX) - 8, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = color.redComponent * 0.21 + color.greenComponent * 0.72 + color.blueComponent * 0.07
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        return maximum - minimum
    }

    private func saveFixtureWindowSnapshot(_ window: NSWindow, to url: URL) throws {
        // Resolve this legacy symbol only for an explicitly requested test
        // artifact: newer SDKs obsolete its source declaration. Including one
        // known fixture window never composites the user's other windows.
        typealias WindowImageOperation = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let operation = unsafeBitCast(symbol, to: WindowImageOperation.self)
        let image = try XCTUnwrap(operation(
            .null, CGWindowListOption.optionIncludingWindow.rawValue,
            CGWindowID(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue
        )?.takeRetainedValue(), "The fixture window snapshot could not be created.")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func inspectFixtureView(_ view: NSView, depth: Int = 0) {
        print("\(String(repeating: " ", count: depth))\(type(of: view)): \(view.frame)")
        view.subviews.forEach { inspectFixtureView($0, depth: depth + 1) }
    }

    private func fixtureImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 640, height: 360))
    }
}

@MainActor
private final class ZoomFixtureState: ObservableObject {
    @Published var zoom: CaptureZoomLevel = .fit
    @Published var annotations: [CaptureAnnotation] = []
    @Published var tool: CaptureTool = .select
}

private struct ZoomFixtureView: View {
    let document: CaptureDocument
    @ObservedObject var state: ZoomFixtureState
    var body: some View {
        CaptureCanvasView(document: document, annotations: $state.annotations, selectedTool: $state.tool,
                          zoomLevel: $state.zoom, captureAction: {}, openAction: {})
    }
}

private struct EditorUITestSecretStore: CloudflareR2SecretStoring {
    func secret(for accessKeyID: String) throws -> String? { nil }
    func setSecret(_ secret: String, for accessKeyID: String) throws {}
    func deleteSecret(for accessKeyID: String) throws {}
}
